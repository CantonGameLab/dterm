// 最小复现:ECH 擦除格的背景色
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

feed :: proc(console_h : mem.Handle, s : string) {
	cv.ConsoleFeed(console_h, transmute([]byte)s)
}

main :: proc() {
	conpty_h, _ := ct.CreateConptyContext({80, 24}, "cmd.exe")
	defer ct.DestroyConpty(conpty_h)
	console_h, _ := cv.CreateConsole(24, 80, conpty_h)
	defer cv.DestroyConsole(console_h)

	feed(console_h, "\x1b[m") // 重置
	feed(console_h, "\x1b[10X") // ECH 10
	c := cv.GetConsole(console_h)
	tb := cv.GetTermBuffer(c.active_term_buffer_id)
	for col in 0 ..< 3 {
		cell := tb.lines[0].cells[col]
		fmt.printf("col %d: cp=%d fg=%08X bg=%08X\n", col, cell.cp, cell.fg, cell.bg)
	}
	fmt.printf("vt.style: fg=%08X bg=%08X\n", c.vt.style.fg, c.vt.style.bg)
}
