// 竖线字符渲染质量探针:打印 '|'(U+007C)与 '│'(U+2502)在目标字体下的
// 度量(advance/xoff/bitmap)/face 归属(看半像素/对齐/断线)。
// 需要最小 GL 上下文(字形图集上传),样板同 fonttest。
package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import fn "../../src/font"
import "core:c"

main :: proc() {
	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL Init failed:", s3.GetError())
		return
	}
	defer s3.Quit()

	window := s3.CreateWindow("barprobe", 128, 128, s3.WINDOW_OPENGL)
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

	fh, ok := fn.LoadFont("Cascadia Code", 26)
	if !ok {
		fmt.println("font load failed")
		return
	}
	defer fn.ReleaseFont(fh)

	m := fn.GetMetrics(fh)
	fmt.printf("cell=%.2fx%.2f ascent=%.2f\n", m.cell_width, m.cell_height, m.ascent)

	Bar :: '|'
	BarV :: '│'
	checkGlyph :: proc(fh : $F, cp : rune) {
		g, ok := fn.GetGlyph(fh, cp)
		fmt.printf("U+%04X: ok=%v gid=%d advance=%.2f bitmap=%dx%d xoff=%.1f yoff=%.1f\n",
			u32(cp), ok, fn.GlyphIndex(fh, cp), g.advance, g.bitmap_w, g.bitmap_h, g.xoff, g.yoff)
	}
	checkGlyph(fh, Bar)
	checkGlyph(fh, BarV)
	checkGlyph(fh, '-')
}

