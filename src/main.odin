package main

import ct "conpty"
import rr "render"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import stt "vendor:stb/truetype"
import "core:fmt"

should_close_window : bool

main :: proc() {
	rr.renderInit()
	for !should_close_window {
		event: s3.Event
		for s3.PollEvent(&event) {
			
		}
		rr.render()
		s3.GL_SwapWindow(rr.window)
	}
	return
}
