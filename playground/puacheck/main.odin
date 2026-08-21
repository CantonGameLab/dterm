// 检查 Fira Code PUA 连体字形:cmap 映射 + advance
package main

import stbtt "vendor:stb/truetype"
import "core:c"
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
	base := int(stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0))
	stbtt.InitFont(&info, cast([^]byte)raw_data(data), c.int(base))

	// 普通字符
	for ch in "->=!<>~:" {
		g := stbtt.FindGlyphIndex(&info, ch)
		adv : c.int
		stbtt.GetGlyphHMetrics(&info, g, &adv, nil)
		fmt.printf("%c: glyph=%d adv=%d\n", ch, g, adv)
	}
	// PUA 区域(E0A0-E0FF + 其他)
	for u in u32(0xE0A0) ..= 0xE0FF {
		g := stbtt.FindGlyphIndex(&info, rune(u))
		if g != 0 {
			adv : c.int
			stbtt.GetGlyphHMetrics(&info, g, &adv, nil)
			fmt.printf("U+%04X: glyph=%d adv=%d\n", u, g, adv)
		}
	}
	// 大范围 PUA
	count := 0
	for u in u32(0xE000) ..= 0xF8FF {
		g := stbtt.FindGlyphIndex(&info, rune(u))
		if g != 0 {
			count += 1
		}
	}
	fmt.printf("PUA glyphs mapped: %d\n", count)
}
