// 统计每个 type6 lookup 解析出的规则数(找解析遗漏)
package main

import stbtt "vendor:stb/truetype"
import fnt "../../src/font"
import "core:c"
import "core:fmt"
import "core:os"

be16s :: proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}
be32s :: proc(d : []u8, off : int) -> u32 {
	return u32(d[off]) << 24 | u32(d[off + 1]) << 16 | u32(d[off + 2]) << 8 | u32(d[off + 3])
}

main :: proc() {
	path := "C:\\Windows\\Fonts\\FiraCodeNerdFontMono-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read failed")
		return
	}
	defer delete(data)

	base := int(stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0))
	num := int(be16s(data, base + 4))
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32s(data, rec + 8))
		}
	}
	ll := gs + int(be16s(data, gs + 8))
	lc := int(be16s(data, ll))

	// 对每个 type6 lookup,直接按规范数子表/规则的"预期"数量(仅 Format1)
	for i in 0 ..< lc {
		lo := ll + int(be16s(data, ll + 2 + i * 2))
		lt := int(be16s(data, lo))
		if lt != 6 {
			continue
		}
		sc := int(be16s(data, lo + 4))
		for j in 0 ..< sc {
			so := lo + int(be16s(data, lo + 6 + j * 2))
			format := int(be16s(data, so))
			if format == 1 {
				sets := int(be16s(data, so + 4))
				total_rules := 0
				for k in 0 ..< sets {
					set := so + int(be16s(data, so + 6 + k * 2))
					total_rules += int(be16s(data, set))
				}
				// 打印规则数多的 lookup
				if total_rules > 5 {
					fmt.printf("lookup %d: fmt1 sets=%d rules=%d\n", i, sets, total_rules)
				}
			} else if format == 3 {
				pos := so + 2
				bt := int(be16s(data, pos))
				pos += 2 + bt * 2
				inp := int(be16s(data, pos))
				pos += 2 + inp * 2
				la := int(be16s(data, pos))
				pos += 2 + la * 2
				subs := int(be16s(data, pos))
				// 输入 cov 的 glyph 数
				cov := so + int(be16s(data, so + 2 + 2 + bt*2 + 2)) // input cov offset 位置
				_ = cov
				if subs > 0 {
					fmt.printf("lookup %d: fmt3 back=%d in=%d look=%d subs=%d\n", i, bt, inp, la, subs)
				}
			}
		}
	}
}
