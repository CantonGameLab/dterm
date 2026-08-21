// 验证冒号子参数 SGR 解析:38:2::r:g:b / 38:5::n / 4:3m / reverse 7m
package main

import vp "../../src/vtparse"
import "core:fmt"
import "core:os"

parser : vp.Parser
sgr : [4]int // fg, bg, reverse, underline

cb :: proc(p : ^vp.Parser, action : vp.Action, ch : rune) {
	if action == .CsiDispatch {
		params := p.params[:p.num_params]
		// 简易 SGR 解析(模拟 vtSgr 的 38/48/7/4 处理)
		i := 0
		for i < len(params) {
			pp := params[i]
			switch pp {
			case 7: sgr[2] = 1
			case 4: sgr[3] = 1
			case 38, 48:
				idx := 0 if pp == 38 else 1
				mode := params[i + 1]
				if mode == 5 {
					skip := 1 if i + 3 < len(params) else 0
					sgr[idx] = params[i + 2 + skip]
					i += 2 + skip
				} else if mode == 2 {
					skip := 1 if i + 5 < len(params) else 0
					sgr[idx] = (params[i + 2 + skip] << 16) | (params[i + 3 + skip] << 8) | params[i + 4 + skip]
					i += 4 + skip
				}
			}
			i += 1
		}
	}
}

main :: proc() {
	vp.Init(&parser, cb)
	test :: proc(seq : string, name : string) {
		sgr = {}
		vp.Parse(&parser, transmute([]u8)seq)
		fmt.printf("%-24s fg=%06X bg=%06X rev=%d und=%d\n", name, sgr[0], sgr[1], sgr[2], sgr[3])
	}
	test("\x1b[38;2;255;0;0m", "分号真彩色 38;2;255;0;0")
	test("\x1b[38:2::255:0:0m", "冒号真彩色 38:2::255:0:0")
	test("\x1b[48:2::0:128:255m", "冒号背景 48:2::0:128:255")
	test("\x1b[38:5::196m", "冒号 256 色 38:5::196")
	test("\x1b[38;5;196m", "分号 256 色 38;5;196")
	test("\x1b[4:3m", "下划线样式 4:3")
	test("\x1b[7m", "反显 7")
	test("\x1b[38:2::10:20:30;48:2::40:50:60m", "混合 38+48 冒号")
}
