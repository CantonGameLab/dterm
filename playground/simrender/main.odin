// dump.bin 全管线模拟:ConPTY + Console + 解析器 → 打印最终屏幕行。
// 用于区分"解析/写屏错位"与"字形/宽度渲染"问题。
// 用法:odin run playground/simrender/(仓库根,dump.bin 同目录)
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	data, err := os.read_entire_file_from_path("dump.bin", context.allocator)
	if err != nil {
		fmt.eprintln("no dump.bin (run oscapture first)")
		return
	}
	defer delete(data)

	ctx, ok := ct.CreateConptyContext({120, 40}, "cmd.exe")
	if !ok {
		fmt.eprintln("pty failed")
		return
	}
	_ = ct.StartReadThread(ctx)
	ch, cok := cv.CreateConsole(40, 120, ctx)
	if !cok {
		fmt.eprintln("console failed")
		return
	}
	cv.ConsoleFeed(ch, data)

	c := cv.GetConsole(ch)
	tb := cv.GetTermBuffer(cv.ConsoleActiveTermBuffer(ch))
	fmt.println("rows:", c.rows, "cols:", c.cols, "lines:", len(tb.lines))
	start := max(0, len(tb.lines) - int(c.rows))
	for r in start ..< len(tb.lines) {
		sb : strings.Builder
		for cell in tb.lines[r].cells {
			switch {
			case cell.cp == 0:
				strings.write_rune(&sb, ' ')
			case cell.wide && cell.cp != 0:
				strings.write_rune(&sb, '▊')
			case cell.cp >= 0x7F:
				strings.write_rune(&sb, '#')
			case:
				strings.write_byte(&sb, u8(cell.cp))
			}
		}
		fmt.println(strings.to_string(sb))
	}
}
