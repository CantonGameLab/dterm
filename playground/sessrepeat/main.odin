// 多会话压力复现:同一 console 连续喂 3 遍 claude dump(中间夹会话切换),
// 每次喂完后打印屏幕首行/关键行快照 → 对比错位是否累积。
// 用法:odin run playground/sessrepeat/(仓库根,dump.bin 同目录)
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	data, err := os.read_entire_file_from_path("dump.bin", context.allocator)
	if err != nil {
		fmt.eprintln("no dump.bin")
		return
	}
	defer delete(data)

	ctx, ok := ct.CreateConptyContext({120, 40}, "cmd.exe")
	if !ok { fmt.eprintln("pty failed"); return }
	_ = ct.StartReadThread(ctx)
	ch, cok := cv.CreateConsole(40, 120, ctx)
	if !cok { fmt.eprintln("console failed"); return }

	// 大历史预填充:模拟多次会话累积的真实场景(base = len-rows >> 0)
	for i in 0 ..< 1500 {
		hist := fmt.tprintf("history filler line %d\r\n", i)
		cv.ConsoleFeed(ch, transmute([]byte)hist)
	}
	tb0 := cv.GetTermBuffer(cv.ConsoleActiveTermBuffer(ch))
	fmt.println("prefilled lines:", len(tb0.lines))

	for round in 1 ..= 3 {
		// 会话黏连间隔:模拟前一会话的尾巴(bash 提示符 + 少量输出)
		if round > 1 {
			sep := "\x1b[0m`~\x1b[31m$\x1b[0m claude\r\nwarning line\r\n"
			cv.ConsoleFeed(ch, transmute([]byte)sep)
		}
		cv.ConsoleFeed(ch, data)

		c := cv.GetConsole(ch)
		tb := cv.GetTermBuffer(cv.ConsoleActiveTermBuffer(ch))
		fmt.printf("== round %d: rows=%d cols=%d lines=%d cursor=(%d,%d)\n",
			round, c.rows, c.cols, len(tb.lines), c.cursor_row, c.cursor_col)
		// 可视区快照:base+r(屏幕行)→ 物理行
		base := max(0, len(tb.lines) - int(c.rows))
		fmt.printf("  screen base=%d\n", base)
		idxs := [?]int{0, 4, 12}
		for idx in idxs {
			if base+idx < len(tb.lines) {
				fmt.printf("  screen %02d (phys %d): %s\n", idx, base+idx, line2s(&tb.lines[base+idx]))
			}
		}
	}
}

line2s :: proc(line : ^cv.Line) -> string {
	sb : strings.Builder
	n := 0
	for cell in line.cells {
		if n >= 60 { break }
		switch {
		case cell.cp == 0:
			strings.write_rune(&sb, ' ')
		case cell.cp >= 0x7F:
			strings.write_rune(&sb, '#')
		case:
			strings.write_byte(&sb, u8(cell.cp))
		}
		n += 1
	}
	return strings.to_string(sb)
}
