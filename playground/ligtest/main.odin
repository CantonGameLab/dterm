// GSUB 连体验证:ShapeGlyphs 逐 lookup 应用,断言最终 glyph 序列
// 期望值来自 fontTools 权威解析 + 手工验证的 HarfBuzz 语义。
package main

import stbtt "vendor:stb/truetype"
import fnt "../../src/font"
import "core:fmt"
import "core:os"

main :: proc() {
	path := "C:\\Windows\\Fonts\\FiraCodeNerdFontMono-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read font failed")
		return
	}
	defer delete(data)

	info : stbtt.fontinfo
	off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	if !stbtt.InitFont(&info, cast([^]byte)raw_data(data), off) {
		fmt.eprintln("InitFont failed")
		return
	}

	g := fnt.ParseGsub(data)
	defer fnt.DestroyGsub(&g)
	fmt.printf("rules: %d (lig sets=%d chain sets=%d calt lookups=%d)\n",
		g.rule_total, len(g.lig_coverage), len(g.chain_coverage), len(g.lookup_order))

	fail := 0
	check :: proc(g : ^fnt.Gsub, info : ^stbtt.fontinfo, text : string, want : []int) -> bool {
		glyphs := make([dynamic]u16, len(text))
		defer delete(glyphs)
		for i in 0 ..< len(text) {
			glyphs[i] = u16(stbtt.FindGlyphIndex(info, rune(text[i])))
		}
		fnt.ShapeGlyphs(g, &glyphs)
		ok := len(glyphs) == len(want)
		if ok {
			for i in 0 ..< len(want) {
				if int(glyphs[i]) != want[i] {
					ok = false
					break
				}
			}
		}
		status := "ok  "
		if !ok {
			status = "FAIL"
		}
		fmt.printf("%s %-8q -> [", status, text)
		for gl in glyphs {
			fmt.printf("%d ", gl)
		}
		fmt.printf("] want [")
		for w in want {
			fmt.printf("%d ", w)
		}
		fmt.printf("]\n")
		return ok
	}

	fail += 0 if check(&g, &info, "->",  []int{12190, 12318})            else 1
	fail += 0 if check(&g, &info, "=>",  []int{12317, 12321})            else 1
	fail += 0 if check(&g, &info, "==",  []int{12386, 12263})            else 1
	fail += 0 if check(&g, &info, "!=",  []int{12208, 12150})            else 1
	fail += 0 if check(&g, &info, "!==", []int{12208, 12386, 12151})     else 1
	fail += 0 if check(&g, &info, "->>", []int{12190, 12387, 12324})     else 1
	fail += 0 if check(&g, &info, "-->", []int{12190, 12189, 12318})     else 1
	fail += 0 if check(&g, &info, "<-",  []int{12332, 12188})            else 1
	fail += 0 if check(&g, &info, "<--", []int{12332, 12189, 12188})     else 1
	fail += 0 if check(&g, &info, "::",  []int{30, 30})                  else 1
	fail += 0 if check(&g, &info, "a->b",[]int{69, 12190, 12318, 70})    else 1
	fail += 0 if check(&g, &info, "--",  []int{12230, 12133})            else 1
	fail += 0 if check(&g, &info, "---", []int{12190, 12189, 12188})     else 1
	fail += 0 if check(&g, &info, "===", []int{12386, 12386, 12264})     else 1
	fail += 0 if check(&g, &info, "->-", []int{12190, 12319, 12188})     else 1
	fail += 0 if check(&g, &info, "ab",  []int{69, 70})                  else 1
	fail += 0 if check(&g, &info, "a",   []int{69})                      else 1

	if fail == 0 {
		fmt.println("ALL PASS")
	} else {
		fmt.eprintfln("%d FAILURES", fail)
	}
}
