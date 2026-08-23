// 验证:宽字符行上的光标移动语义(CUF/CUB/BS)
// 场景:行 = "汉a"(col0=汉 首格, col1=续列, col2='a'),cols=10
// 期望(xterm 语义):CUF n 从 col0 → col0+n(续列不可停,落在续列再前进)
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import mem "../../src/memory"
import "core:fmt"

fails := 0
check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-46s %s\n", name, status)
}

main :: proc() {
	conpty_h, ok := ct.CreateConptyContext({80, 24}, "cmd.exe")
	if !ok {
		fmt.eprintln("conpty fail")
		return
	}
	defer ct.DestroyConpty(conpty_h)
	console_h, cok := cv.CreateConsole(10, 10, conpty_h) // rows=10, cols=10
	if !cok {
		fmt.eprintln("console fail")
		return
	}
	defer cv.DestroyConsole(console_h)

	feed :: proc(console_h : mem.Handle, s : string) {
		cv.ConsoleFeed(console_h, transmute([]u8)s)
	}

	// 写入 "汉a"
	feed(console_h, "汉a")
	console := cv.GetConsole(console_h)
	// 写完:汉占 col0-1,'a' 在 col2,光标在 col3
	check("写入后光标 col=3", console.cursor_col == 3)
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	check("col0=汉(宽)", tb.lines[0].cells[0].cp == '汉' && tb.lines[0].cells[0].wide)
	check("col1=续列", tb.lines[0].cells[1].cp == 0 && tb.lines[0].cells[1].wide)
	check("col2=a", tb.lines[0].cells[2].cp == 'a')

	// CUB 1:从 col3 → col2(a)
	feed(console_h, "\x1b[D")
	check("CUB1: col3→2", console.cursor_col == 2)
	// CUB 1:col2 → col1? col1 是续列不可停 → col0(汉)
	feed(console_h, "\x1b[D")
	check("CUB1 跳过续列: col2→0", console.cursor_col == 0)
	// CUB 1:col0 到边界不动
	feed(console_h, "\x1b[D")
	check("CUB1 行首不动: col0", console.cursor_col == 0)

	// CUF 1:col0 → 跳过续列 → col2(a)
	feed(console_h, "\x1b[C")
	check("CUF1 跳过续列: col0→2", console.cursor_col == 2)
	// CUF 1:col2 → col3(空白,可停)
	feed(console_h, "\x1b[C")
	check("CUF1: col2→3", console.cursor_col == 3)

	// CUF 5 从 col0:期望到 col5(空白,不会因为宽字符多跳)
	console.cursor_col = 0
	feed(console_h, "\x1b[5C")
	check("CUF5 从 col0 → col5", console.cursor_col == 5)

	// CUF 20 从 col0:clamp 到 cols-1=9
	console.cursor_col = 0
	feed(console_h, "\x1b[20C")
	check("CUF20 从 col0 → col9(clamp)", console.cursor_col == 9)

	// CUB 20:clamp 到 0
	feed(console_h, "\x1b[20D")
	check("CUB20 → col0(clamp)", console.cursor_col == 0)

	// BS(0x08)从 col2 回退:col1 续列 → col0
	feed(console_h, "\x1b[2C") // 到 col2
	feed(console_h, "\x08")
	check("BS 跳过续列: col2→0", console.cursor_col == 0)

	// 连续宽字符:行 = "汉汉a"
	feed(console_h, "\r\n汉汉a")
	// col0=汉, col1=续, col2=汉, col3=续, col4=a, 光标 col5
	console.cursor_col = 0
	feed(console_h, "\x1b[2C") // CUF2:col0+2=col2(第二个汉首格,不是续列,无需跳)
	check("连续宽 CUF2: col0→2", console.cursor_col == 2)
	feed(console_h, "\x1b[C") // CUF1:col2+1=col3 续列 → col4(a)
	check("连续宽 CUF1: col2→4", console.cursor_col == 4)

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
