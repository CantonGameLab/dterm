// type 6(ChainContextSubst)结构探测
package main

import stbtt "vendor:stb/truetype"
import "core:fmt"
import "core:os"

be16 :: proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}
be32 :: proc(d : []u8, off : int) -> u32 {
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
	num := int(be16(data, base + 4))
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32(data, rec + 8))
		}
	}
	ll := gs + int(be16(data, gs + 8))
	lc := int(be16(data, ll))

	type6_seen := 0
	for i in 0 ..< lc {
		lo := ll + int(be16(data, ll + 2 + i * 2))
		lt := be16(data, lo)
		if lt == 6 {
			sc := int(be16(data, lo + 4))
			for j in 0 ..< sc {
				so := lo + int(be16(data, lo + 6 + j * 2))
				format := be16(data, so)
				fmt.printf("type6 lookup %d sub %d: format=%d\n", i, j, format)
				if format == 1 {
					// 打印结构
					rule_sets := int(be16(data, so + 4))
					fmt.printf("  coverageOff=%d ruleSets=%d\n", be16(data, so + 2), rule_sets)
					if rule_sets > 0 {
						rs := so + int(be16(data, so + 6))
						rules := int(be16(data, rs))
						fmt.printf("  ruleSet0: rules=%d\n", rules)
						if rules > 0 {
							ro := rs + int(be16(data, rs + 2))
							bt := int(be16(data, ro))
							pos := ro + 2
							fmt.printf("    rule0: backtrack=%d [", bt)
							for b in 0 ..< bt {
								fmt.printf(" %d", be16(data, pos + b * 2))
							}
							pos += bt * 2
							inp := int(be16(data, pos))
							pos += 2
							fmt.printf(" ] input=%d [", inp)
							for b in 0 ..< inp - 1 { // 数组只有 count-1 个(首个在 coverage)
								fmt.printf(" %d", be16(data, pos + b * 2))
							}
							pos += (inp - 1) * 2
							la := int(be16(data, pos))
							pos += 2
							fmt.printf(" ] lookahead=%d [", la)
							for b in 0 ..< la {
								fmt.printf(" %d", be16(data, pos + b * 2))
							}
							pos += la * 2
							subs := int(be16(data, pos))
							pos += 2
							fmt.printf(" ] subst=%d", subs)
							for b in 0 ..< subs {
								si := be16(data, pos + b * 4)
								li := be16(data, pos + b * 4 + 2)
								fmt.printf(" (seq=%d lookup=%d)", si, li)
							}
							fmt.println()
						}
					}
				} else if format == 3 {
					bt := int(be16(data, so + 2))
					fmt.printf("  backtrack=%d", bt)
					pos := so + 4
					for b in 0 ..< bt {
						fmt.printf(" covOff=%d", be16(data, pos + b * 2))
					}
					inp := int(be16(data, pos + bt * 2))
					fmt.printf(" input=%d", inp)
					pos += 2 + bt * 2
					for b in 0 ..< inp {
						fmt.printf(" covOff=%d", be16(data, pos + b * 2))
					}
					la := int(be16(data, pos + inp * 2))
					fmt.printf(" lookahead=%d", la)
					pos += 2 + inp * 2
					for b in 0 ..< la {
						fmt.printf(" covOff=%d", be16(data, pos + b * 2))
					}
					subs := int(be16(data, pos + la * 2))
					fmt.printf(" subst=%d", subs)
					pos += 2 + la * 2
					for b in 0 ..< subs {
						si := be16(data, pos + b * 4)
						li := be16(data, pos + b * 4 + 2)
						fmt.printf(" (seq=%d lookup=%d)", si, li)
					}
					fmt.println()
				}
			}
			type6_seen += 1
			if type6_seen >= 6 {
				return
			}
		}
	}
}
