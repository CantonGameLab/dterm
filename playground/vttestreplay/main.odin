// vttest 分步回放:按 "Push <RETURN>"(holdit 提示)把字节流分段,
// 每段喂给 Console 后 dump 屏幕,逐图检查 vttest 测试图案。
// 用法:odin run playground/vttestreplay/ capture_vttest1.bin
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"
import "core:os"
import "core:strings"

dump_screen :: proc(console_h : mem.Handle, title : string) {
	console := cv.GetConsole(console_h)
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	fmt.printf("===== %s (lines=%d cols=%d vis_top=%d cur=(%d,%d)) =====\n", title, len(tb.lines),
		console.cols, max(0, len(tb.lines) - int(console.rows) - int(tb.scroll_offset)), console.cursor_row, console.cursor_col)
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	vis_top := max(0, len(tb.lines) - int(console.rows) - int(tb.scroll_offset))
	for i in 0 ..< int(console.rows) {
		line_idx := vis_top + i
		if line_idx >= len(tb.lines) {
			break
		}
		strings.builder_reset(&sb)
		line := tb.lines[line_idx]
		for c in 0 ..< len(line.cells) {
			cell := line.cells[c]
			if cell.cp != 0 {
				strings.write_rune(&sb, cell.cp)
			} else if cell.wide {
				strings.write_byte(&sb, '·')
			} else if cell.bg != cv.DEFAULT_COLOR {
				strings.write_byte(&sb, '#')
			} else {
				strings.write_byte(&sb, ' ')
			}
		}
		fmt.printf("[%02d] %s\n", i, strings.to_string(sb))
	}
	fmt.println()
}

main :: proc() {
	path := "playground/vtcapture/capture.bin"
	if len(os.args) > 1 {
		path = os.args[1]
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read failed:", path)
		return
	}
	defer delete(data)
	fmt.printf("replay %d bytes from %s\n", len(data), path)

	conpty_h, ok := ct.CreateConptyContext({80, 24}, "cmd.exe")
	if !ok {
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

	// 按 "Push <RETURN>" 分段(ASCII 序列)
	marker := "Push <RETURN>"
	seg_start := 0
	seg_no := 0
	for i := 0; i <= len(data) - len(marker); i += 1 {
		match := true
		for j in 0 ..< len(marker) {
			if data[i + j] != marker[j] {
				match = false
				break
			}
		}
		if match {
			seg := data[seg_start:i + len(marker)]
			seg_no += 1
			cv.ConsoleFeed(console_h, seg)
			dump_screen(console_h, fmt.tprintf("step %d", seg_no))
			seg_start = i + len(marker)
		}
	}
	// 最后一段
	if seg_start < len(data) {
		seg_no += 1
		cv.ConsoleFeed(console_h, data[seg_start:])
		dump_screen(console_h, fmt.tprintf("step %d (final)", seg_no))
	}
	fmt.printf("total %d steps\n", seg_no)
}
