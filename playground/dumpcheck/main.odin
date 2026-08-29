// dump.bin 解析检查:喂进 dterm 解析器,统计非 ASCII 输出;
// 再把每个图标字符送去字体系统(consola 26 + 中文 fallback),查字形是否存在。
// 用法:odin run playground/dumpcheck/(在仓库根,dump.bin 同目录)
package main

import cv "../../src/canvas"
import fnt "../../src/font"
import "core:fmt"
import "core:os"

chrs : [512]rune
cnts : [512]int
n : int

cb :: proc(p : ^cv.Parser, action : cv.Action, ch : rune) {
	if action == .Print && ch >= 0x7F {
		// 去重收集
		for i in 0 ..< n {
			if chrs[i] == ch {
				cnts[i] += 1
				return
			}
		}
		if n < len(chrs) {
			chrs[n] = ch
			cnts[n] = 1
			n += 1
		}
	}
}

main :: proc() {
	data, err := os.read_entire_file_from_path("dump.bin", context.allocator)
	if err != nil {
		fmt.eprintln("dump.bin not found (run oscapture first)")
		return
	}
	defer delete(data)
	parser : cv.Parser
	cv.Init(&parser, cb)
	cv.Parse(&parser, data)
	fmt.println("dump bytes:", len(data), " unique non-ascii prints:", n)

	f, fok := fnt.LoadFont("consola", 26)
	if !fok {
		fmt.eprintln("LoadFont consola failed")
		return
	}
	for i in 0 ..< n {
		g, gok := fnt.GetGlyph(f, chrs[i])
		fmt.printf("U+%04X '%c' x%d glyph=%v\n", u32(chrs[i]), chrs[i], cnts[i], gok)
	}
}
