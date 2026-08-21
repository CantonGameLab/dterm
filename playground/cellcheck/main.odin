// 逐格检查:打印指定行的每个 cell(列号 + 字符 + 样式)
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"
import "core:os"

main :: proc() {
	path := "playground/vtcapture/capture.bin"
	if len(os.args) > 1 {
		path = os.args[1]
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read failed")
		return
	}
	defer delete(data)

	conpty_h, ok := ct.CreateConptyContext({80, 24}, "cmd.exe")
	if !ok {
		return
	}
	defer ct.DestroyConpty(conpty_h)
	console_h, ok2 := cv.CreateConsole(24, 80, conpty_h)
	if !ok2 {
		return
	}
	defer cv.DestroyConsole(console_h)

	cv.ConsoleFeed(console_h, data)

	c := cv.GetConsole(console_h)
	tb := cv.GetTermBuffer(c.active_term_buffer_id)
	for row in 0 ..< min(3, len(tb.lines)) {
		fmt.printf("row %d (len=%d):\n", row, len(tb.lines[row].cells))
		for col in 0 ..< min(14, len(tb.lines[row].cells)) {
			cell := tb.lines[row].cells[col]
			fmt.printf("  [%2d] cp=U+%04X wide=%v rev=%v fg=%08X bg=%08X\n",
				col, u32(cell.cp), cell.wide, cell.reverse, cell.fg, cell.bg)
		}
	}
}
