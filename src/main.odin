// CLI 测试:ConPTY → VT 解析 → TermBuffer → dump 到 dump.txt
// 用法:./src.exe [command](默认 cmd.exe)
// 注:command 参数直接传给 CreateProcessW,非交互命令需带 cmd 前缀:
//   ./src.exe "cmd /c chcp 65001 && echo 你好 && echo ok"
package main

import ct "conpty"
import cv "canvas"
import mem "memory"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	cmd := "cmd.exe"
	if len(os.args) > 1 {
		cmd = strings.join(os.args[1:], " ")
	}

	id, ok := ct.CreateConptyContext({120, 30}, cmd)
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

	time.sleep(800 * time.Millisecond) // 等启动输出
	drain(console_id)

	ct.WriteConptyInput(id, transmute([]byte)string("dir /b\r"))
	time.sleep(600 * time.Millisecond)
	drain(console_id)

	// 直接喂 VT 序列验证解析器(经输入管道会被 cmd 行编辑器吃掉)
	// 注:ConPTY 输入管道是字节流,cmd 按当前代码页解析,写中文需参数模式:
	//   ./src.exe "chcp 65001 && echo 你好 && echo ok"
	cv.ConsoleFeed(console_id, transmute([]byte)string("\r\n\x1b[31mRED\x1b[32mGREEN\x1b[1mBOLD\x1b[4mUNDERLINE\x1b[7mREVERSE\x1b[0mplain"))
	cv.ConsoleFeed(console_id, transmute([]byte)string("\r\n\x1b[44mBLUEBG\x1b[0mnormal"))
	cv.ConsoleFeed(console_id, transmute([]byte)string("\r\n你好UTF8")) // UTF-8 分片解析
	cv.ConsoleFeed(console_id, transmute([]byte)string("\x1b[5;10Habs-pos")) // 绝对定位覆盖写

	dumpConsole(console_id, "dump.txt")
	fmt.eprintln("dump -> dump.txt")
}

// 循环喂解析器直到消费完(ring 空时 UpdateConsole 立即返回)
drain :: proc(console_h : mem.Handle) {
	for i in 0 ..< 64 {
		cv.UpdateConsole(console_h)
	}
}

dumpConsole :: proc(console_h : mem.Handle, path : string) {
	console := cv.GetConsole(console_h)
	tb := cv.GetTermBuffer(cv.ConsoleActiveTermBuffer(console_h))
	if console == nil || tb == nil {
		fmt.eprintln("dump: console/tb nil")
		return
	}
	visible_top := max(0, len(tb.lines) - int(console.rows))

	buf := strings.builder_make()
	defer strings.builder_destroy(&buf)

	fmt.sbprintf(&buf, "rows=%d cols=%d lines=%d visible_top=%d cursor=(%d,%d) scroll=(%d,%d)\n",
		console.rows, console.cols, len(tb.lines), visible_top,
		console.cursor_row, console.cursor_col,
		console.vt.scroll_top, console.vt.scroll_bottom)

	for line, i in tb.lines {
		sb := strings.builder_make()
		for cell in line.cells {
			if cell.cp == 0 {
				strings.write_byte(&sb, ' ')
			} else {
				strings.write_rune(&sb, cell.cp)
			}
		}
		text := strings.trim_right(strings.to_string(sb), " ")
		strings.builder_destroy(&sb)

		flag := "h" // 历史行
		if i >= visible_top {
			flag = "v" // 可视行
		}
		if i == int(console.cursor_row) {
			flag = ">" // 光标行
		}

		// 非默认样式行,附颜色值验证 SGR;cp==0 的空 cell 不参与判定
		style_note := ""
		for cell in line.cells {
			if cell.cp == 0 {
				continue
			}
			if cell.fg != cv.DEFAULT_COLOR || cell.bg != cv.DEFAULT_COLOR || cell.bold || cell.italic || cell.underline || cell.reverse {
				style_note = fmt.tprintf(" [fg=%08X bg=%08X b=%v]", cell.fg, cell.bg, cell.bold)
				break
			}
		}
		fmt.sbprintf(&buf, "%4d %s%s| %s\n", i, flag, style_note, text)
	}
	if err := os.write_entire_file_from_string(path, strings.to_string(buf)); err != nil {
		fmt.eprintln("write dump failed:", err)
	}
}
