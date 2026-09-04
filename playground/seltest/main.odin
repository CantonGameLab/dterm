// 文本选区回归(buffer 坐标系语义):区间判定/提取(CRLF/wrapped/宽字符/trim)/
// 规范化(续列起点左移、终点右移)/自愈(交替屏/行越界)/平移(裁剪)/命令解析。
// 工具 console(conpty = 0,无会话);全部经公开接口。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

checkText :: proc(name, want : string) {
	data := cv.ExtractSelectionText()
	defer if data != nil {
		delete(data)
	}
	got := ""
	if data != nil {
		got = string(data) // 借用 data(比较后再随 defer 释放)
	}
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%q want=%q\n", name, got, want)
	}
}

runeW :: proc(r : rune) -> int {
	if r >= 0x4E00 && r <= 0x9FFF {
		return 2
	}
	return 1
}

// 覆盖式写一行文本(宽字符占 2 格,续列 cp=0)
writeText :: proc(tb : ^cv.TermBuffer, line_idx : int, s : string) {
	for len(tb.lines) <= line_idx {
		append(&tb.lines, cv.Line{})
	}
	line := &tb.lines[line_idx]
	clear(&line.cells)
	col := 0
	for r in s {
		w := runeW(r)
		for len(line.cells) <= col + w - 1 {
			append(&line.cells, cv.Cell { fg = cv.DEFAULT_COLOR, bg = cv.DEFAULT_COLOR })
		}
		line.cells[col] = cv.Cell { cp = r, fg = cv.DEFAULT_COLOR, bg = cv.DEFAULT_COLOR, wide = w == 2 }
		if w == 2 {
			line.cells[col + 1] = cv.Cell { fg = cv.DEFAULT_COLOR, bg = cv.DEFAULT_COLOR, wide = true }
		}
		col += w
	}
}

main :: proc() {
	ch, ok := cv.CreateConsole(24, 80, {})
	if !ok {
		fmt.println("console create failed")
		return
	}
	console := cv.GetConsole(ch)
	tbh := console.active_term_buffer_id
	tb := cv.GetTermBuffer(tbh)
	check("buffer alive", tb != nil, true)

	writeText(tb, 0, "Hello World 你好世界   ") // 尾部 3 空格
	writeText(tb, 1, "abc")
	writeText(tb, 2, "def")
	tb.lines[2].wrapped = true // 软换行(由上一行折行)

	// ---- 无选区 ----
	check("no selection valid", cv.SelectionValid(), false)
	check("copy no selection = noop", cv.CopySelection(), false)
	check("extract no selection nil", cv.ExtractSelectionText() == nil, true)

	// ---- 单行区间 ----
	check("attach single", cv.SelectionAttach(tbh, { line = 0, col = 0 }, { line = 0, col = 5 }), true)
	checkText("extract single", "Hello")
	check("cell in", cv.CellSelected(0, 0, 1, 80), true)
	check("cell out", cv.CellSelected(0, 5, 1, 80), false)
	check("row out", cv.CellSelected(1, 0, 1, 80), false)
	check("cell wide w2 out", cv.CellSelected(0, 12, 2, 80), false)

	// ---- 向下多行:行 0 全行(trim 尾空格)+ CRLF + 行 1 前缀 ----
	cv.SelectionAttach(tbh, { 0, 0 }, { 1, 3 })
	checkText("extract down", "Hello World 你好世界\r\nabc")

	// ---- wrapped 拼接(行 2 由行 1 折行而来 → 无分隔) ----
	cv.SelectionAttach(tbh, { 0, 0 }, { 2, 3 })
	checkText("extract wrapped join", "Hello World 你好世界\r\nabcdef")

	// ---- 反向选择(锚在下) ----
	cv.SelectionAttach(tbh, { 2, 3 }, { 0, 0 })
	checkText("extract upward same", "Hello World 你好世界\r\nabcdef")

	// ---- 宽字符整字/截断 ----
	cv.SelectionAttach(tbh, { 0, 12 }, { 0, 16 })
	checkText("extract wide full", "你好")
	cv.SelectionAttach(tbh, { 0, 12 }, { 0, 13 }) // 终点在续列 → 右移包含整字
	checkText("extract wide tail", "你")
	cv.SelectionAttach(tbh, { 0, 13 }, { 0, 0 }) // 起点在续列 → 左移字首(反向)
	checkText("extract wide start in tail", "Hello World 你")

	// ---- 空选区(同点,不产生格) ----
	cv.SelectionAttach(tbh, { 0, 13 }, { 0, 13 })
	check("zero area no cell", cv.CellSelected(0, 12, 2, 80), false)
	checkText("zero area text", "")

	// ---- 自愈:交替屏(active buffer 切换) ----
	tb2, ok2 := cv.CreateTermBuffer()
	check("tb2 created", ok2, true)
	cv.ConsoleAttachTermBuffer(ch, tb2)
	check("switch buffer -> invalid", cv.SelectionValid(), false)
	cv.ConsoleAttachTermBuffer(ch, tbh)
	check("switch back -> valid", cv.SelectionValid(), true)

	// ---- 自愈:锚行越界(内容被删/裁剪未平移的兜底) ----
	cv.SelectionAttach(tbh, { 0, 0 }, { 1, 3 })
	remove_range(&tb.lines, 2, 3) // 删掉无关行(行 2)
	check("valid after unrelated delete", cv.SelectionValid(), true)
	remove_range(&tb.lines, 0, 2) // 删掉含锚的两行 → 锚行越界
	check("anchor oob -> invalid", cv.SelectionValid(), false)
	writeText(tb, 0, "Hello World 你好世界   ")
	writeText(tb, 1, "abc")
	writeText(tb, 2, "def")
	tb.lines[2].wrapped = true

	// ---- 平移:全屏滚动 → trimScrollback(公开路径) ----
	// 构造 10540 行,光标(物理行)贴底,写 81 字符触发 wrap → 全屏滚动 + 裁剪
	for len(tb.lines) < 10540 {
		append(&tb.lines, cv.Line{})
	}
	cv.SelectionAttach(tbh, { 9000, 0 }, { 9000, 5 })
	console.cursor_row = 10539
	console.cursor_col = 0
	len_before := len(tb.lines)
	for i in 0 ..< 80 {
		cv.ConsoleWriteRune(ch, 'x', cv.CellStyle { fg = cv.DEFAULT_COLOR, bg = cv.DEFAULT_COLOR })
	}
	cv.ConsoleWriteRune(ch, 'y', cv.CellStyle { fg = cv.DEFAULT_COLOR, bg = cv.DEFAULT_COLOR })
	cut := len_before + 1 - (24 + 10000) // 期望裁剪量(追加 1 行后裁剪)
	check("trim happened", len(tb.lines) == 24 + 10000, true)
	check("anchor shifted -cut", cv.CellSelected(9000 - cut, 0, 1, 80), true)
	check("old line no longer selected", cv.CellSelected(9000, 0, 1, 80), false)
	check("anchor valid after trim", cv.SelectionValid(), true)

	// ---- SelectionClear + 命令解析 ----
	cv.SelectionClear()
	check("clear -> invalid", cv.SelectionValid(), false)
	pc, okp := cmd.ParseCommandString("copy")
	check("parse copy", okp && pc.kind == cmd.CommandStringKind.CopySelection, true)
	pc2, okp2 := cmd.ParseCommandString("paste")
	check("parse paste", okp2 && pc2.kind == cmd.CommandStringKind.PasteClipboard, true)
	pc3, okp3 := cmd.ParseCommandString("clearselection")
	check("parse clearselection", okp3 && pc3.kind == cmd.CommandStringKind.SelectionClear, true)
	cmd.ExecuteCommand(pc3)
	check("exec clear noop", cv.SelectionValid(), false)

	// ==== M3:词选/行选/全选 ====
	// 恢复小内容(裁剪后前 3 行是空行,重写基准行)
	// 行 0 = "Hello World 你好世界   ";行 4 = "foo_bar, baz";行 5 = "你 好"
	writeText(tb, 0, "Hello World 你好世界   ")
	writeText(tb, 4, "foo_bar, baz")
	writeText(tb, 5, "你 好")
	tb.lines[4].wrapped = false

	// 词选:Hello World col6 → "World"
	check("setword hit", cv.SelectionSetWord(tbh, 0, 6), true)
	checkText("word World", "World")
	check("word cell", cv.CellSelected(0, 6, 1, 80), true)

	// 词选:col0 → "Hello"
	cv.SelectionSetWord(tbh, 0, 0)
	checkText("word Hello", "Hello")

	// 下划线入词:foo_bar 整体
	cv.SelectionSetWord(tbh, 4, 0)
	checkText("word foo_bar", "foo_bar")
	// 逗号(分隔符)→ 单格
	cv.SelectionSetWord(tbh, 4, 7)
	check("word sep single cell", cv.CellSelected(4, 7, 1, 80), true)
	// 词:baz(col 9)
	cv.SelectionSetWord(tbh, 4, 9)
	checkText("word baz", "baz")

	// 中文连续成段:col12 → "你好世界"
	cv.SelectionSetWord(tbh, 0, 12)
	checkText("word CJK run", "你好世界")
	// 中文空格断:行 5 "你 好" col0 → "你"
	cv.SelectionSetWord(tbh, 5, 0)
	checkText("word CJK sep", "你")
	// 点击续列(col13 = '你' 续列)→ 字首 → 词含全段
	cv.SelectionSetWord(tbh, 0, 13)
	checkText("word wide tail hit", "你好世界")

	// 三击行选:行 0 整行(trim 尾空格)
	cv.SelectionSetLine(tbh, 0)
	check("setline valid", cv.SelectionValid(), true)
	checkText("line extract", "Hello World 你好世界")
	check("line cell end", cv.CellSelected(0, 60, 1, 80), true) // [0,80) 全宽

	// 全选(无焦点 → false 空操作;有焦点场景走 GUI)
	check("selectall no focus", cv.SelectionSelectAll(), false)
	pc4, okp4 := cmd.ParseCommandString("selectall")
	check("parse selectall", okp4 && pc4.kind == cmd.CommandStringKind.SelectAll, true)

	fmt.println("seltest done")
}
