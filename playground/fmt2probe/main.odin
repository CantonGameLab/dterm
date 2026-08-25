// type 6 Format 2(类上下文)探测
package main

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"

be16f :: proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}
be32f :: proc(d : []u8, off : int) -> u32 {
	return u32(d[off]) << 24 | u32(d[off + 1]) << 16 | u32(d[off + 2]) << 8 | u32(d[off + 3])
}

// ClassDef:glyph → class
classOf :: proc(d : []u8, cdef : int, glyph : u16) -> i16 {
	format := be16f(d, cdef)
	if format == 1 {
		start := int(be16f(d, cdef + 2))
		count := int(be16f(d, cdef + 4))
		if int(glyph) >= start && int(glyph) < start + count {
			return i16(be16f(d, cdef + 6 + (int(glyph) - start) * 2))
		}
		return -1
	} else if format == 2 {
		range_count := int(be16f(d, cdef + 2))
		for r in 0 ..< range_count {
			rec := cdef + 4 + r * 6
			start := int(be16f(d, rec))
			end := int(be16f(d, rec + 2))
			if int(glyph) >= start && int(glyph) <= end {
				return i16(be16f(d, rec + 4))
			}
		}
		return -1
	}
	return -1
}

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
	num := int(be16f(data, base + 4))
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32f(data, rec + 8))
		}
	}
	ll := gs + int(be16f(data, gs + 8))
	lc := int(be16f(data, ll))

	gid_of :: proc(info : ^stbtt.fontinfo, ch : rune) -> int {
		return int(stbtt.FindGlyphIndex(info, ch))
	}

	for i in 0 ..< lc {
		lo := ll + int(be16f(data, ll + 2 + i * 2))
		if be16f(data, lo) != 6 {
			continue
		}
		sc := int(be16f(data, lo + 4))
		for j in 0 ..< sc {
			so := lo + int(be16f(data, lo + 6 + j * 2))
			if be16f(data, so) != 2 {
				continue
			}
			fmt.printf("lookup %d fmt2: covOff=%d backCD=%d inCD=%d lookCD=%d sets=%d\n",
				i, be16f(data, so + 2), be16f(data, so + 4), be16f(data, so + 6), be16f(data, so + 8), be16f(data, so + 10))
			back_cd := so + int(be16f(data, so + 4))
			in_cd := so + int(be16f(data, so + 6))
			look_cd := so + int(be16f(data, so + 8))
			// 用常见字符查类
			dash := u16(gid_of(&info, '-'))
			gt := u16(gid_of(&info, '>'))
			eq := u16(gid_of(&info, '='))
			lt := u16(gid_of(&info, '<'))
			fmt.printf("  classOf: '-'=%d '>'=%d '='=%d '<'=%d\n",
				classOf(data, in_cd, dash), classOf(data, in_cd, gt),
				classOf(data, in_cd, eq), classOf(data, in_cd, lt))
			fmt.printf("  backCD: '-'=%d '>'=%d '='=%d\n",
				classOf(data, back_cd, dash), classOf(data, back_cd, gt), classOf(data, back_cd, eq))
			// 类规则集
			set_count := int(be16f(data, so + 10))
			for k in 0 ..< set_count {
				set := so + int(be16f(data, so + 12 + k * 2))
				rule_count := int(be16f(data, set))
				for r in 0 ..< rule_count {
					ro := set + int(be16f(data, set + 2 + r * 2))
					pos := ro
					bt := int(be16f(data, pos))
					pos += 2
					fmt.printf("  set%d rule%d: backClasses=[", k, r)
					for b in 0 ..< bt {
						fmt.printf("%d ", be16f(data, pos + b * 2))
					}
					pos += bt * 2
					inp := int(be16f(data, pos))
					pos += 2
					fmt.printf("] inClasses=[")
					for b in 0 ..< inp - 1 {
						fmt.printf("%d ", be16f(data, pos + b * 2))
					}
					pos += (inp - 1) * 2
					la := int(be16f(data, pos))
					pos += 2
					fmt.printf("] lookClasses=[")
					for b in 0 ..< la {
						fmt.printf("%d ", be16f(data, pos + b * 2))
					}
					pos += la * 2
					subs := int(be16f(data, pos))
					pos += 2
					fmt.printf("] subs=[")
					for b in 0 ..< subs {
						fmt.printf("(seq=%d lookup=%d) ", be16f(data, pos + b * 4), be16f(data, pos + b * 4 + 2))
					}
					fmt.printf("]\n")
				}
			}
		}
	}
}

