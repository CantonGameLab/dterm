// nvim 场景综合测试:模拟全屏应用启动序列 + 定位断言。
// 重点覆盖:带参序列后紧跟无参序列(残留参数回归)、交替屏、SGR、折行、滚动区。
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

fail_count := 0

check :: proc(name : string, got, want : int) {
	if got == want {
		fmt.printf("ok   %-36s got=%d\n", name, got)
	} else {
		fmt.printf("FAIL %-36s got=%d want=%d\n", name, got, want)
		fail_count += 1
	}
}

feed :: proc(console_h : mem.Handle, s : string) {
	cv.ConsoleFeed(console_h, transmute([]byte)s)
}

main :: proc() {
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

	// 1. nvim 式启动:参数字典序列后紧跟无参序列(残留参数陷阱)
	feed(console_h, "\x1b[?1h\x1b=\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[?1049h\x1b[>4;2m\x1b[?7h")
	feed(console_h, "\x1b[2J\x1b[H") // 清屏 + 回原点;1049(参数 1049)后必须归零
	c := cv.GetConsole(console_h)
	check("CUP after 1049: cursor_row", int(c.cursor_row), 0)
	check("CUP after 1049: cursor_col", int(c.cursor_col), 0)
	check("alt buffer active", int(c.active_term_buffer_id != c.term_buffer_ids[0]), 1)
	check("cursor hidden", int(c.vt.cursor_visible == false), 1)
	check("mouse sgr on", int(c.vt.sgr_mouse), 1)
	check("bracketed paste on", int(c.vt.bracketed_paste), 1)

	// 2. 画"界面":绿字标题 + 无参 ESC[m 重置 + 定位写内容(CUP 是 1-based)
	feed(console_h, "\x1b[32mNvim Demo\x1b[mZ") // Z 验证 ESC[m 重置样式
	feed(console_h, "\x1b[3;1Hline2") // 0-based 第 2 行,避免覆盖 X
	feed(console_h, "\x1b[2;3H\x1b[31mX\x1b[m") // 0-based 第 1 行第 2 列红 X
	feed(console_h, "\x1b[5;10H\x1b[38;5;208m色\x1b[m")
	tb := cv.GetTermBuffer(c.active_term_buffer_id)
	check("lines count", len(tb.lines), 5)
	check("title fg green", int(tb.lines[0].cells[0].fg == cv.ANSI16[2]), 1)
	check("ESC[m reset fg", int(tb.lines[0].cells[9].fg == cv.DEFAULT_COLOR), 1)
	check("Z after reset", int(tb.lines[0].cells[9].cp == 'Z'), 1)
	check("X at row1 col2", int(tb.lines[1].cells[2].cp == 'X'), 1)
	check("X fg red", int(tb.lines[1].cells[2].fg == cv.ANSI16[1]), 1)
	check("line2 at row2", int(tb.lines[2].cells[0].cp == 'l'), 1)
	check("color char at row4 col9", int(tb.lines[4].cells[9].cp == '色'), 1)
	check("color char fg 208", int(tb.lines[4].cells[9].fg == 0xFF8700), 1)
	check("cursor after draws", int(c.cursor_row), 4)
	check("cursor col after draws", int(c.cursor_col), 11) // 色占 2 列

	// 3. 折行:写满 80 列 → 光标停最后一列(pending);再写才折到下一行
	feed(console_h, "\x1b[1;1H")
	for i in 0 ..< 80 {
		feed(console_h, "A")
	}
	c = cv.GetConsole(console_h)
	check("wrap: pending at last col", int(c.cursor_row), 0)
	check("wrap: cursor_col at 79", int(c.cursor_col), 79)
	check("wrap: pending flag", int(c.vt.wrap_pending), 1)
	feed(console_h, "B") // 第 81 个字符触发折行
	c = cv.GetConsole(console_h)
	check("wrap: wrapped to row1", int(c.cursor_row), 1)
	check("wrap: col0 after wrap", int(c.cursor_col), 1)
	check("wrap: B at row1 col0", int(tb.lines[1].cells[0].cp == 'B'), 1)
	check("wrap: line0 cells", len(tb.lines[0].cells), 80)

	// 4. 退出交替屏 → 回主屏 + 光标恢复
	feed(console_h, "\x1b[?1049l")
	c = cv.GetConsole(console_h)
	check("alt exit: main buffer", int(c.active_term_buffer_id == c.term_buffer_ids[0]), 1)
	check("alt exit: cursor restored", int(c.cursor_row), 0)

	// 5. 滚动区:CSI 2;23r,光标在底行时 LF 触发滚动,光标不动
	feed(console_h, "\x1b[2;23r\x1b[23;1H")
	for i in 0 ..< 3 {
		feed(console_h, "\n")
	}
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("scroll region: cursor_row", int(c.cursor_row), 22)
	check("scroll region: lines", len(tb.lines), 23)
	check("scroll region: top kept", int(len(tb.lines[0].cells)), 0)

	// 6. 状态栏场景:填满 80 列 + \r\n 相对移动(旧"立即折行"会多走一行 → 两行状态栏)
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[H") // 进交替屏:滚动区应重置全屏
	c = cv.GetConsole(console_h)
	check("alt enter: scroll region reset", int(c.vt.scroll_top), 0)
	feed(console_h, "\x1b[22;1H\x1b[7m") // 状态栏行(0-based 21),反色
	for i in 0 ..< 80 {
		feed(console_h, "X")
	}
	feed(console_h, "\x1b[0m\r\n") // 重置 + CRLF 相对移到命令行行
	feed(console_h, "\x1b[7m-- INSERT --\x1b[0m")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("statusbar: cursor_row", int(c.cursor_row), 22)
	check("statusbar: X at row21 col79", int(tb.lines[21].cells[79].cp == 'X'), 1)
	check("statusbar: INSERT at row22", int(tb.lines[22].cells[0].cp == '-'), 1)
	check("statusbar: no extra row23", int(len(tb.lines) <= 23), 1)

	// 7. 退出交替屏:恢复主屏光标 + 滚动区
	feed(console_h, "\x1b[?1049l")
	c = cv.GetConsole(console_h)
	check("alt exit: cursor restored", int(c.cursor_row), 22)
	check("alt exit: scroll region restored", int(c.vt.scroll_top), 1)
	check("alt exit: scroll bottom restored", int(c.vt.scroll_bottom), 22)

	// 8. nvim eob 绘制核心:SGR 不取消 wrap-pending(写满 + 改色 + ~ 必须折行)
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[H")
	for i in 0 ..< 80 {
		feed(console_h, "A")
	}
	feed(console_h, "\x1b[31m") // SGR 改色
	feed(console_h, "~")        // 期望折行到下一行行首
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("sgr keeps pending: ~ at row1 col0", int(tb.lines[1].cells[0].cp == '~'), 1)
	check("sgr keeps pending: cursor (1,1)", int(c.cursor_row), 1)

	// 9. CR 取消 wrap-pending(写满 + CR 后字符留在本行)
	feed(console_h, "\x1b[1;1H")
	for i in 0 ..< 80 {
		feed(console_h, "B")
	}
	feed(console_h, "\rC")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("cr cancels pending: C at row0 col0", int(tb.lines[0].cells[0].cp == 'C'), 1)
	check("cr cancels pending: cursor col", int(c.cursor_col), 1)

	// 10. 内容行绘制:nvim 打开源码文件场景
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[H")
	// 10a. tab 缩进 + 文本(tab 到 8 列停靠位)
	feed(console_h, "\x1b[1;1H\tmain :: proc() {")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("tab: 'm' at col8", int(tb.lines[0].cells[8].cp == 'm'), 1)
	check("tab: col0-7 empty", int(tb.lines[0].cells[0].cp == 0), 1)
	// 10b. 行中 SGR 语法高亮:注释绿色 + 恢复
	feed(console_h, "\x1b[2;1Hif !ok {")
	feed(console_h, "\x1b[38;5;65m // 注释\x1b[0m")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("highlight: slash at col9", int(tb.lines[1].cells[9].cp == '/'), 1)
	check("highlight: comment green", int(tb.lines[1].cells[9].fg == 0x5F875F), 1)
	check("highlight: reset after", int(c.vt.style.fg == cv.DEFAULT_COLOR), 1)
	// 10c. 长行折行:85 字符写到行 3,折到行 4
	feed(console_h, "\x1b[4;1H")
	for i in 0 ..< 85 {
		feed(console_h, "D")
	}
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("long line: row3 col79", int(tb.lines[3].cells[79].cp == 'D'), 1)
	check("long line: row4 col0", int(tb.lines[4].cells[0].cp == 'D'), 1)
	check("long line: cursor (4,5)", int(c.cursor_row), 4)
	// 10d. 文本 + EL 清行尾(内容行标准画法)
	feed(console_h, "\x1b[6;1Hshort\x1b[K")
	feed(console_h, "\x1b[7;1Hnext")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("el: 'next' at row6", int(tb.lines[6].cells[0].cp == 'n'), 1)

	// 11. 宽字符:汉字占 2 列,续列标记,后续字符位置正确
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[H")
	feed(console_h, "\x1b[1;1H你好x")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("wide: 你 at col0", int(tb.lines[0].cells[0].cp == '你'), 1)
	check("wide: continuation at col1", int(tb.lines[0].cells[1].wide), 1)
	check("wide: 好 at col2", int(tb.lines[0].cells[2].cp == '好'), 1)
	check("wide: x at col4", int(tb.lines[0].cells[4].cp == 'x'), 1)
	check("wide: cursor col5", int(c.cursor_col), 5)
	// 宽字符在最后列放不下:先折行
	feed(console_h, "\x1b[2;1H")
	for i in 0 ..< 79 {
		feed(console_h, "A")
	}
	feed(console_h, "你") // col 79 放不下 2 列 → 折行到 col 0
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("wide: A at row1 col78", int(tb.lines[1].cells[78].cp == 'A'), 1)
	check("wide: 你 at row2 col0", int(tb.lines[2].cells[0].cp == '你'), 1)
	check("wide: cursor (2,2)", int(c.cursor_row), 2)
	// BS/CUB 跳过续列
	feed(console_h, "\x1b[4;1H你好")
	feed(console_h, "\x1b[2D") // CUB 2 → 应停在 col 0(跳过续列)
	c = cv.GetConsole(console_h)
	check("wide: CUB skips continuation", int(c.cursor_col), 0)

	// 12. 补全窗口场景:背景 SGR + 文本 + EL 0 → 行尾用背景填充成完整矩形
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[H")
	feed(console_h, "\x1b[5;5H\x1b[48;5;236m\x1b[38;5;252mitem1\x1b[K")
	feed(console_h, "\x1b[6;5H\x1b[48;5;236m\x1b[38;5;252mitem2\x1b[K")
	feed(console_h, "\x1b[7;5H\x1b[48;5;236m\x1b[38;5;252mitem3\x1b[K")
	feed(console_h, "\x1b[0m")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("pum: item1 at row4 col4", int(tb.lines[4].cells[4].cp == 'i'), 1)
	check("pum: text fg 252", int(tb.lines[4].cells[4].fg == 0xD0D0D0), 1)
	check("pum: text bg 236", int(tb.lines[4].cells[4].bg == 0x303030), 1)
	check("pum: erased tail keeps bg", int(tb.lines[4].cells[79].bg == 0x303030), 1)
	check("pum: tail has no cp", int(tb.lines[4].cells[79].cp == 0), 1)
	check("pum: row width 80", int(len(tb.lines[4].cells)), 80)
	check("pum: row6 item2", int(tb.lines[5].cells[4].cp == 'i'), 1)
	// 无背景时 EL:擦除 cell 背景应为默认(渲染不画)
	feed(console_h, "\x1b[9;1Hab\x1b[0m\x1b[K")
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("el default bg", int(tb.lines[8].cells[5].bg == cv.DEFAULT_COLOR), 1)
	check("el default: no cp", int(tb.lines[8].cells[5].cp == 0), 1)

	// 13. Origin mode(CSI ?6h):光标定位相对滚动区
	feed(console_h, "\x1b[?1049h\x1b[2J\x1b[5;10r\x1b[?6h")
	feed(console_h, "\x1b[H") // CUP(1,1) → 滚动区顶(0-based 4)
	c = cv.GetConsole(console_h)
	check("origin: CUP home at scroll top", int(c.cursor_row), 4)
	feed(console_h, "\x1b[6;1H") // CUP(6,1) → 滚动区内第 6 行(0-based 9)
	c = cv.GetConsole(console_h)
	check("origin: CUP 6 at row9", int(c.cursor_row), 9)
	feed(console_h, "\x1b[24;1H") // CUP(24,1) → 限制在滚动区底(0-based 9)
	c = cv.GetConsole(console_h)
	check("origin: CUP clamped to bottom", int(c.cursor_row), 9)
	feed(console_h, "\x1b[10A") // CUU 10 → 滚动区顶(0-based 4)
	c = cv.GetConsole(console_h)
	check("origin: CUU clamped to top", int(c.cursor_row), 4)
	feed(console_h, "\x1b[10B") // CUD 10 → 滚动区底(0-based 9)
	c = cv.GetConsole(console_h)
	check("origin: CUD clamped to bottom", int(c.cursor_row), 9)
	// DECSTBM 在 origin 下:光标移到新滚动区 home
	feed(console_h, "\x1b[3;8r")
	c = cv.GetConsole(console_h)
	check("origin: DECSTBM moves to home", int(c.cursor_row), 2)
	// 关闭 origin:绝对定位
	feed(console_h, "\x1b[?6l\x1b[H")
	c = cv.GetConsole(console_h)
	check("origin off: CUP absolute", int(c.cursor_row), 0)

	// 14. DECCOLM(CSI ?3h):132 列模式
	feed(console_h, "\x1b[?3h")
	c = cv.GetConsole(console_h)
	check("132: cols=132", int(c.cols), 132)
	check("132: cursor home", int(c.cursor_row), 0)
	feed(console_h, "\x1b[1;1H")
	for i in 0 ..< 132 {
		feed(console_h, "A")
	}
	c = cv.GetConsole(console_h)
	tb = cv.GetTermBuffer(c.active_term_buffer_id)
	check("132: 132 chars no wrap", int(c.cursor_row), 0)
	check("132: cursor at 131", int(c.cursor_col), 131)
	check("132: line width", int(len(tb.lines[0].cells)), 132)
	// 回到 80 列
	feed(console_h, "\x1b[?3l")
	c = cv.GetConsole(console_h)
	check("80: cols=80", int(c.cols), 80)
	check("80: cursor home", int(c.cursor_row), 0)
	check("80: screen cleared", int(len(tb.lines)), 0)

	if fail_count == 0 {
		fmt.println("ALL PASS")
	} else {
		fmt.eprintfln("%d FAILURES", fail_count)
	}
}
