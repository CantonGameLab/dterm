package main

import r "render"
import fnt "font"
import ct "conpty"
import cv "canvas"
import "core:fmt"
import "core:time"

FONT_PATH :: "C:/Windows/Fonts/consola.ttf"

main :: proc() {
	r.RenderInit()
	defer r.RenderQuit()

	font := fnt.LoadFont(FONT_PATH, 24)
	if font == nil {
		fmt.eprintln("LoadFont failed:", FONT_PATH)
	} else {
		defer fnt.DestroyFont(font)
		fnt.PreloadRange(font, 0x20, 0x7E)
	}

	id, ok := ct.CreateConptyContext({120, 30}, "cmd.exe")
	if !ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(id)

	console_id, ok2 := cv.CreateConsole(30, 120, id)
	if !ok2 {
		fmt.eprintln("CreateConsole failed")
		return
	}
	defer cv.DestroyConsole(console_id)

	if !ct.StartReadThread(id) {
		fmt.eprintln("StartReadThread failed")
		return
	}
	defer ct.StopReadThread(id)

	time.sleep(500 * time.Millisecond) // 等 cmd 启动横幅

	for !r.PollEvents() {
		cv.UpdateConsole(console_id)

		r.BeginFrame()
		// 测试矩形
		r.DrawRect(60, 60, 240, 140, 0x3A3D5C)
		r.DrawRect(76, 76, 208, 108, 0x2E3348)
		if font != nil {
			r.DrawText(font, "dterm render framework", 60, 40, 0xE0E0E0)
			buf : [256]byte
			n := cv.TermBufferLineCount(cv.ConsoleActiveTermBuffer(console_id))
			r.DrawText(font, fmt.bprintf(buf[:], "parsed %d lines", n), 60, 240, 0x98C379)
		}
		r.EndFrame()
		time.sleep(16 * time.Millisecond)
	}
}
