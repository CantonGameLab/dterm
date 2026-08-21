// 统计 type 6 子表 format 分布 + 嵌套 lookup 类型
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

	// lookup 类型表
	lookup_types := make([]u16, lc)
	defer delete(lookup_types)
	for i in 0 ..< lc {
		lo := ll + int(be16(data, ll + 2 + i * 2))
		lookup_types[i] = be16(data, lo)
	}

	fmt_1, fmt_2, fmt_3, other := 0, 0, 0, 0
	ref_types : [16]int
	for i in 0 ..< lc {
		lo := ll + int(be16(data, ll + 2 + i * 2))
		lt := be16(data, lo)
		if lt == 6 {
			sc := int(be16(data, lo + 4))
			for j in 0 ..< sc {
				so := lo + int(be16(data, lo + 6 + j * 2))
				switch be16(data, so) {
				case 1: fmt_1 += 1
				case 2: fmt_2 += 1
				case 3: fmt_3 += 1
				case: other += 1
				}
				// 统计 subst 引用的 lookup 类型
				format := be16(data, so)
				if format == 1 {
					cov := so + int(be16(data, so + 2))
					rsets := int(be16(data, so + 4))
					for k in 0 ..< rsets {
						rs := so + int(be16(data, so + 6 + k * 2))
						rules := int(be16(data, rs))
						for r in 0 ..< rules {
							ro := rs + int(be16(data, rs + 2 + r * 2))
							pos := ro + 2
							bt := int(be16(data, ro))
							pos += bt * 2
							inp := int(be16(data, pos))
							pos += 2 + (inp - 1) * 2
							la := int(be16(data, pos))
							pos += 2 + la * 2
							subs := int(be16(data, pos))
							pos += 2
							for b in 0 ..< subs {
								li := be16(data, pos + b * 4 + 2)
								if int(li) < lc && int(lookup_types[li]) < 16 {
									ref_types[lookup_types[li]] += 1
								}
							}
						}
					}
				} else if format == 3 {
					bt := int(be16(data, so + 2))
					pos := so + 4 + bt * 2
					inp := int(be16(data, pos))
					pos += 2 + inp * 2
					la := int(be16(data, pos))
					pos += 2 + la * 2
					subs := int(be16(data, pos))
					pos += 2
					for b in 0 ..< subs {
						li := be16(data, pos + b * 4 + 2)
						if int(li) < lc && int(lookup_types[li]) < 16 {
							ref_types[lookup_types[li]] += 1
						}
					}
				}
			}
		}
	}
	fmt.printf("type6 subtable formats: fmt1=%d fmt2=%d fmt3=%d other=%d\n", fmt_1, fmt_2, fmt_3, other)
	fmt.printf("referenced lookup types: ")
	for t, n in ref_types {
		if n > 0 {
			fmt.printf("type%d=%d ", t, n)
		}
	}
	fmt.println()
	// 各 lookup 类型总数
	fmt.printf("lookup type totals: ")
	for t in 0 ..< 8 {
		n := 0
		for lt in lookup_types {
			if int(lt) == t {
				n += 1
			}
		}
		if n > 0 {
			fmt.printf("type%d=%d ", t, n)
		}
	}
	fmt.println()
}


