// shape 性能:三种文本 × ShapeGlyphs 直接调用(无整行缓存)
package main

import stbtt "vendor:stb/truetype"
import fnt "../../src/font"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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
	fmt.printf("rules=%d calt=%d active=%d\n", g.rule_total, len(g.lookup_order), len(g.active_glyphs))

	texts := []struct{ name : string, s : string }{
		{"long lig   ", strings.repeat("<----------->", 40, context.allocator)},
		{"plain      ", strings.repeat("the quick brown fox jumps over the lazy dog 0123456789 ", 8, context.allocator)},
		{"code       ", strings.repeat("function foo(a, b) { return a->b && c != d; } // ==> ok ", 6, context.allocator)},
	}
	defer {
		for t in texts {
			delete(t.s)
		}
	}

	for t in texts {
		glyphs := make([dynamic]u16, len(t.s))
		defer delete(glyphs)
		for i in 0 ..< len(t.s) {
			glyphs[i] = u16(stbtt.FindGlyphIndex(&info, rune(t.s[i])))
		}
		start := time.now()
		iters := 1000
		for _ in 0 ..< iters {
			fnt.ShapeGlyphs(&g, &glyphs)
		}
		fmt.printf("%s (%4d chars): %.3f ms/op\n", t.name, len(t.s), time.duration_milliseconds(time.since(start)) / f64(iters))
	}
}
