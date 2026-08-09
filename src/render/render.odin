package render

import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "core:c"
import "core:fmt"

INIT_WINDOW_WIDTH :: 1920
INIT_WINDOW_HEIGHT :: 1080
INIT_WINDOW_TITLE :: "dterm demo"

window : ^s3.Window
gl_context : s3.GLContext

renderInit :: proc() {
	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL3 Init Failed:", s3.GetError())
		return
	}
	defer s3.Quit()
	window = s3.CreateWindow(
		INIT_WINDOW_TITLE,
		INIT_WINDOW_WIDTH,
		INIT_WINDOW_HEIGHT,
		s3.WINDOW_OPENGL | s3.WINDOW_RESIZABLE
	)
	defer s3.DestroyWindow(window)

	s3.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(s3.GLProfile{.CORE}))
	s3.GL_SetAttribute(.DOUBLEBUFFER, 1)
	s3.GL_SetAttribute(.MULTISAMPLEBUFFERS, 1)
	s3.GL_SetAttribute(.MULTISAMPLESAMPLES, 4)

	gl_context = s3.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintfln("Create GL Context Failed:", s3.GetError())
		return
	}
	defer s3.GL_DestroyContext(gl_context)

	if !s3.GL_MakeCurrent(window, gl_context) {
		fmt.eprintfln("绑定GL上下文失败:", s3.GetError())
		return
	}

	gl.load_up_to(
		4, 
		4, 
		proc(p : rawptr, name : cstring) {
			(cast(^rawptr)p)^ = cast(rawptr)s3.GL_GetProcAddress(name)
		}
	)

	s3.GL_SetSwapInterval(0)


}

render :: proc() {
	width, height : c.int
	s3.GetWindowSize(window, &width, &height)
	gl.Viewport(0, 0, width, height)
	gl.Clear(0)
}
