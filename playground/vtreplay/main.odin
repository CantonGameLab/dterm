// 回放真实 bash 输出:经 vtparse + Console 全链路后 dump 终端内容。
// 用法:先跑 vtcapture,再 odin run playground/vtreplay/
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	data, err := os.read_entire_file_from_path("playground/vtcapture/capture.bin", context.allocator)
	if err != nil {
		fmt.eprintln("read capture.bin failed, run vtcapture first")
		return
	}
	defer delete(data)
	fmt.printf("replay %d bytes\n", len(data))

	// 真实 ConPTY 上下文仅用于通过 CreateConsole 校验;不启动读线程
	conpty_h, cok := ct.CreateConptyContext({80, 24}, "cmd.exe")
	if !cok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(conpty_h)

	console_h, ok2 := cv.CreateConsole(24, 80, conpty_h)
	if !ok2 {
		fmt.eprintln("CreateConsole failed")
		return
	}
	defer cv.DestroyConsole(console_h)

	cv.ConsoleFeed(console_h, data)

	console := cv.GetConsole(console_h)
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	fmt.printf("rows=%d cols=%d lines=%d cursor=(%d,%d)\n",
		console.rows, console.cols, len(tb.lines), console.cursor_row, console.cursor_col)

	// 逐行 dump:内容 + 样式摘要(首个非默认样式格)
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for i in 0 ..< len(tb.lines) {
		line := tb.lines[i]
		strings.builder_reset(&sb)
		sty := ""
		for c in 0 ..< len(line.cells) {
			cell := line.cells[c]
			if cell.cp != 0 {
				strings.write_rune(&sb, cell.cp)
			} else {
				strings.write_byte(&sb, ' ')
			}
			if sty == "" && (cell.fg != cv.DEFAULT_COLOR || cell.bg != cv.DEFAULT_COLOR || cell.bold || cell.reverse) {
				sty = fmt.tprintf(" [fg=%06x bg=%06x b=%v r=%v]", cell.fg, cell.bg, cell.bold, cell.reverse)
			}
		}
		fmt.printf("[%3d] %s%s\n", i, strings.to_string(sb), sty)
	}
}
