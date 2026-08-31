// 字体模块隔离测试:最小 GL 上下文 + LoadFont + GetMetrics + GetGlyph。
// 目的:确认字体度量/字形光栅化/图集 UV 是否正确,排查渲染问题。
package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import fnt "../../src/font"
import "core:c"

main :: proc() {
	// 最小 GL 上下文(字体图集需要 GL)
	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL Init failed:", s3.GetError())
		return
	}
	defer s3.Quit()

	window := s3.CreateWindow("fonttest", 128, 128, s3.WINDOW_OPENGL)
	if window == nil {
		fmt.eprintln("CreateWindow failed:", s3.GetError())
		return
	}
	defer s3.DestroyWindow(window)

	s3.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(s3.GLProfile{.CORE}))

	glctx := s3.GL_CreateContext(window)
	if glctx == nil {
		fmt.eprintln("GL context failed:", s3.GetError())
		return
	}
	defer s3.GL_DestroyContext(glctx)
	s3.GL_MakeCurrent(window, glctx)

	gl.load_up_to(4, 4, proc(p : rawptr, name : cstring) {
		(cast(^rawptr)p)^ = cast(rawptr)s3.GL_GetProcAddress(name)
	})

	// 加载字体
	font_h, ok := fnt.LoadFont("resource/font/Go-Mono/GoMonoNerdFontMono-Regular.ttf", 14)
	if !ok {
		fmt.eprintln("LoadFont FAILED")
		return
	}
	defer fnt.ReleaseFont(font_h)

	m := fnt.GetMetrics(font_h)
	tex := fnt.GetAtlasTexture(font_h)
	fmt.printf("metrics: cell_w=%.2f cell_h=%.2f ascent=%.2f  atlas_tex=%d\n",
		m.cell_width, m.cell_height, m.ascent, tex)

	// 字形采样
	samples := "MA你 gW@"
	for cp in samples {
		g, gok := fnt.GetGlyph(font_h, cp)
		if !gok {
			fmt.printf("U+%04X -> NO GLYPH(空白/缺字)\n", u32(cp))
			continue
		}
		fmt.printf("U+%04X advance=%.2f bitmap=%.0fx%.0f off=(%.1f,%.1f) uv=(%.4f,%.4f)-(%.4f,%.4f)\n",
			u32(cp), g.advance, g.bitmap_w, g.bitmap_h, g.xoff, g.yoff,
			g.uv0_x, g.uv0_y, g.uv1_x, g.uv1_y)
	}

	// 检查位图像素内容(排除"尺寸对但全空"的情况)
	font := fnt.GetFont(font_h)
	nonzero := 0
	total := 0
	for row in 0 ..< 12 {
		for col in 0 ..< 10 {
			idx := row * int(font.atlas.width) + col
			total += 1
			if font.atlas.pixels[idx] != 0 {
				nonzero += 1
			}
		}
	}
	fmt.printf("atlas 左上 10x12 区域非零像素: %d / %d\n", nonzero, total)
}
