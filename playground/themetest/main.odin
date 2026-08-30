// 主题系统回归:颜色引用编码 + ResolveColor 解码 + SGR → cell 编码写链。
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

index :: proc(n : int) -> u32 {
	return 0x01_000000 | u32(n)
}

main :: proc() {
	t := cv.GetTheme()
	fmt.println("== 解码(默认主题)==")
	check("rgb passthrough", cv.ResolveColor(0x123456, 0), u32(0x123456))
	check("default → theme.fg", cv.ResolveColor(0xFFFFFFFF, t.fg), t.fg)
	check("index 1 → ansi[1]", cv.ResolveColor(index(1), 0), t.ansi[1])
	check("index 16 → cube 0", cv.ResolveColor(index(16), 0), u32(0x000000))
	check("index 21 → cube 00FF", cv.ResolveColor(index(21), 0), u32(0x0000FF))
	check("index 232 → gray 08", cv.ResolveColor(index(232), 0), u32(0x080808))
	check("index 255 → gray EE", cv.ResolveColor(index(255), 0), u32(0xEEEEEE))

	fmt.println("== SetTheme 生效 ==")
	t2 := t
	t2.ansi[1] = 0xABCDEF
	t2.focus_border = 0x112233
	cv.SetTheme(t2)
	check("ansi override", cv.ResolveColor(index(1), 0), u32(0xABCDEF))
	check("theme get", cv.GetTheme().focus_border, u32(0x112233))
	cv.SetTheme(cv.DEFAULT_THEME)
	check("restore", cv.ResolveColor(index(1), 0), t.ansi[1])

	fmt.println("== SGR → cell 编码 ==")
	ctx, ok := ct.CreateConptyContext({120, 40}, "cmd.exe")
	if !ok {
		fmt.println("pty failed")
		return
	}
	// 不启读线程:ConsoleFeed 直接喂解析器(绕过 ConPTY)
	ch, cok := cv.CreateConsole(40, 120, ctx)
	if !cok {
		fmt.println("console failed")
		return
	}
	defer cv.DestroyConsole(ch)
	seq := "\x1b[31mR\x1b[38;5;196mG\x1b[38;2;1;2;3mB\x1b[0mX"
	cv.ConsoleFeed(ch, transmute([]u8)seq)

	tb := cv.GetTermBuffer(cv.ConsoleActiveTermBuffer(ch))
	if tb == nil || len(tb.lines) == 0 || len(tb.lines[0].cells) < 4 {
		fmt.println("buffer shape failed")
		return
	}
	cells := tb.lines[0].cells
	check("R fg = index 1", cells[0].fg, index(1))
	check("G fg = index 196", cells[1].fg, index(196))
	check("B fg = rgb 010203", cells[2].fg, u32(0x010203))
	check("X fg = default", cells[3].fg, u32(0xFFFFFFFF))
}
