// GSUB 逐 lookup shaping 模拟:按 calt lookup 顺序应用连体规则。
package main

import stbtt "vendor:stb/truetype"
import fnt "../../src/font"
import "core:fmt"
import "core:os"

main :: proc() {
	path := "C:\\Windows\\Fonts\\FiraCodeNerdFontMono-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read failed")
		return
	}
	defer delete(data)

	info : stbtt.fontinfo
	off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	stbtt.InitFont(&info, cast([^]byte)raw_data(data), off)

	g := fnt.ParseGsub(data)
	defer fnt.DestroyGsub(&g)

	shape :: proc(g : ^fnt.Gsub, info : ^stbtt.fontinfo, text : string) {
		glyphs := make([dynamic]u16, len(text))
		defer delete(glyphs)
		for i in 0 ..< len(text) {
			glyphs[i] = u16(stbtt.FindGlyphIndex(info, rune(text[i])))
		}
		fmt.printf("%q: ", text)
		for gl in glyphs {
			fmt.printf("%d ", gl)
		}
		fmt.println()
		fnt.ShapeGlyphs(g, &glyphs)
		fmt.printf("  -> ")
		for gl in glyphs {
			fmt.printf("%d ", gl)
		}
		fmt.println()
	}

	shape(&g, &info, "->")
	shape(&g, &info, "=>")
	shape(&g, &info, "==")
	shape(&g, &info, "!=")
	shape(&g, &info, "-->")
	shape(&g, &info, "<-")
	shape(&g, &info, "<--")
	shape(&g, &info, "::")
	shape(&g, &info, "a->b")
	shape(&g, &info, "--")
	shape(&g, &info, "---")
	shape(&g, &info, "->-")
}
