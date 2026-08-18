// SDL3 + OpenGL 4.4 渲染层:窗口 / GL 上下文 / 图元批。
// 渲染是数据管线终端:只读消费 canvas/font,绝不写回模型数据。
// 屏幕坐标 = 像素,左上原点,Y 向下。每帧:BeginFrame → 绘制 → EndFrame。
package render

import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import fnt "../font"
import mem "../memory"
import "core:c"
import "core:fmt"

INIT_WINDOW_WIDTH :: 1920
INIT_WINDOW_HEIGHT :: 1080
INIT_WINDOW_TITLE :: "dterm demo"

window : ^s3.Window
gl_context : s3.GLContext
screen_w, screen_h : f32

// ---------------------------------------------------------------------------
// 着色器
// ---------------------------------------------------------------------------

VERT_SRC :: `
#version 440 core
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec4 aColor;
uniform vec2 uScreenSize;
out vec2 vUv;
out vec4 vColor;
void main() {
    vUv = aUv;
    vColor = aColor;
    vec2 ndc = vec2(aPos.x / uScreenSize.x * 2.0 - 1.0, 1.0 - aPos.y / uScreenSize.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
`

FRAG_SRC :: `
#version 440 core
in vec2 vUv;
in vec4 vColor;
uniform sampler2D uTex;
out vec4 fragColor;
void main() {
    // 图集为 R8 灰度:灰度值作 alpha,颜色纯由顶点色给出
    fragColor = vec4(vColor.rgb, vColor.a * texture(uTex, vUv).r);
}
`

program : u32
u_screen_size : i32

// ---------------------------------------------------------------------------
// 四边形批量:同纹理的四边形攒一批,一次 draw call
// ---------------------------------------------------------------------------

Vertex :: struct {
	x, y : f32, // 屏幕像素
	u, v : f32, // UV
	r, g, b, a : f32,
}

MAX_QUADS :: 4096
quad_verts : [MAX_QUADS * 6]Vertex
quad_count : int
current_tex : u32
white_tex : u32
vao, vbo : u32

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

Init :: proc() -> bool {
	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL3 Init Failed:", s3.GetError())
		return false
	}
	window = s3.CreateWindow(
		INIT_WINDOW_TITLE,
		INIT_WINDOW_WIDTH,
		INIT_WINDOW_HEIGHT,
		s3.WINDOW_OPENGL | s3.WINDOW_RESIZABLE
	)
	if window == nil {
		fmt.eprintln("CreateWindow Failed:", s3.GetError())
		return false
	}

	s3.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(s3.GLProfile{.CORE}))
	s3.GL_SetAttribute(.DOUBLEBUFFER, 1)
	s3.GL_SetAttribute(.MULTISAMPLEBUFFERS, 1)
	s3.GL_SetAttribute(.MULTISAMPLESAMPLES, 4)

	gl_context = s3.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintln("Create GL Context Failed:", s3.GetError())
		return false
	}
	if !s3.GL_MakeCurrent(window, gl_context) {
		fmt.eprintln("绑定GL上下文失败:", s3.GetError())
		return false
	}

	gl.load_up_to(
		4,
		4,
		proc(p : rawptr, name : cstring) {
			(cast(^rawptr)p)^ = cast(rawptr)s3.GL_GetProcAddress(name)
		}
	)

	s3.GL_SetSwapInterval(1)

	program = linkProgram(compileShader(gl.VERTEX_SHADER, VERT_SRC), compileShader(gl.FRAGMENT_SHADER, FRAG_SRC))
	if program == 0 {
		return false
	}
	u_screen_size = gl.GetUniformLocation(program, "uScreenSize")
	initBatch()
	initWhiteTexture()
	return true
}

Quit :: proc() {
	gl.DeleteProgram(program)
	gl.DeleteBuffers(1, &vbo)
	gl.DeleteVertexArrays(1, &vao)
	gl.DeleteTextures(1, &white_tex)
	s3.GL_DestroyContext(gl_context)
	s3.DestroyWindow(window)
	s3.Quit()
}

// 当前窗口物理尺寸(像素):GL framebuffer 的真实尺寸,渲染/布局都用它。
// 注意不能用 s3.GetWindowSize(那是逻辑尺寸/点,受 DPI 缩放影响)。
GetWindowSize :: proc() -> (w, h : u32) {
	cw, ch : c.int
	s3.GetWindowSizeInPixels(window, &cw, &ch)
	return u32(cw), u32(ch)
}

// 窗口指针(供 input 启用文本输入等)
GetWindow :: proc() -> ^s3.Window {
	return window
}

// ---------------------------------------------------------------------------
// 帧
// ---------------------------------------------------------------------------

BeginFrame :: proc() {
	w, h := GetWindowSize()
	screen_w, screen_h = f32(w), f32(h)

	gl.Viewport(0, 0, c.int(w), c.int(h))
	gl.ClearColor(0.07, 0.09, 0.12, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	quad_count = 0
	current_tex = 0

	gl.UseProgram(program)
	gl.Uniform2f(u_screen_size, screen_w, screen_h)
}

EndFrame :: proc() {
	flushBatch()
	s3.GL_SwapWindow(window)
}

// ---------------------------------------------------------------------------
// 绘制
// ---------------------------------------------------------------------------

// 实心矩形,color = 0xRRGGBB
DrawRect :: proc(x, y, w, h : f32, color : u32) {
	pushQuad(white_tex, x, y, x + w, y + h, 0, 0, 1, 1, color)
}

// 单字形,(x, y) = 基线位置;返回前进宽,无字形时按格宽
DrawRune :: proc(font_h : mem.Handle, cp : rune, x, y : f32, color : u32) -> (advance : f32) {
	g, ok := fnt.GetGlyph(font_h, cp)
	if !ok {
		return fnt.GetMetrics(font_h).cell_width
	}
	tex := fnt.GetAtlasTexture(font_h)
	pushQuad(tex, x + g.xoff, y + g.yoff, x + g.xoff + g.bitmap_w, y + g.yoff + g.bitmap_h, g.uv0_x, g.uv0_y, g.uv1_x, g.uv1_y, color)
	return g.advance
}

// 文本,(x, y) = 基线位置
DrawText :: proc(font_h : mem.Handle, text : string, x, y : f32, color : u32) {
	m := fnt.GetMetrics(font_h)
	pen_x, pen_y := x, y
	for r in text {
		if r == '\n' {
			pen_x = x
			pen_y += m.cell_height
			continue
		}
		pen_x += DrawRune(font_h, r, pen_x, pen_y, color)
	}
}

pushQuad :: proc(tex : u32, x0, y0, x1, y1, u0, v0, u1, v1 : f32, color : u32) {
	if tex != current_tex {
		flushBatch()
		current_tex = tex
		gl.BindTexture(gl.TEXTURE_2D, tex)
	}
	if quad_count >= MAX_QUADS {
		flushBatch()
	}
	r := f32(color >> 16 & 0xFF) / 255
	g := f32(color >> 8 & 0xFF) / 255
	b := f32(color & 0xFF) / 255
	base := quad_count * 6
	quad_verts[base + 0] = Vertex { x0, y0, u0, v0, r, g, b, 1 }
	quad_verts[base + 1] = Vertex { x1, y0, u1, v0, r, g, b, 1 }
	quad_verts[base + 2] = Vertex { x1, y1, u1, v1, r, g, b, 1 }
	quad_verts[base + 3] = Vertex { x1, y1, u1, v1, r, g, b, 1 }
	quad_verts[base + 4] = Vertex { x0, y1, u0, v1, r, g, b, 1 }
	quad_verts[base + 5] = Vertex { x0, y0, u0, v0, r, g, b, 1 }
	quad_count += 1
}

flushBatch :: proc() {
	if quad_count == 0 {
		return
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, int(quad_count * 6 * size_of(Vertex)), raw_data(quad_verts[:quad_count * 6]), gl.DYNAMIC_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(quad_count * 6))
	quad_count = 0
}

// ---------------------------------------------------------------------------
// GL 初始化
// ---------------------------------------------------------------------------

compileShader :: proc(kind : u32, src : cstring) -> u32 {
	shader := gl.CreateShader(kind)
	srcs := [?]cstring{src}
	gl.ShaderSource(shader, 1, raw_data(srcs[:]), nil)
	gl.CompileShader(shader)
	status : i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		buf : [2048]byte
		gl.GetShaderInfoLog(shader, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("shader compile failed:", string(buf[:]))
		gl.DeleteShader(shader)
		return 0
	}
	return shader
}

linkProgram :: proc(vs, fs : u32) -> u32 {
	program := gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)
	gl.LinkProgram(program)
	status : i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &status)
	if status == 0 {
		buf : [2048]byte
		gl.GetProgramInfoLog(program, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("program link failed:", string(buf[:]))
		gl.DeleteProgram(program)
		return 0
	}
	return program
}

initBatch :: proc() {
	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)

	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, size_of(Vertex), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, size_of(Vertex), uintptr(2 * size_of(f32)))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.FLOAT, gl.FALSE, size_of(Vertex), uintptr(4 * size_of(f32)))

	gl.ActiveTexture(gl.TEXTURE0)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
}

initWhiteTexture :: proc() {
	gl.GenTextures(1, &white_tex)
	gl.BindTexture(gl.TEXTURE_2D, white_tex)
	pixel : u8 = 255
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, 1, 1, 0, gl.RED, gl.UNSIGNED_BYTE, &pixel)
}
