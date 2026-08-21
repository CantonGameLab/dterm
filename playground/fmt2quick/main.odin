// 精简:所有 Format 2 子表,查 '-' '>' '<' '=' 在 inputClassDef 里的类
package main

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"

be16g :: proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}
be32g :: proc(d : []u8, off : int) -> u32 {
	return u32(d[off]) << 24 | u32(d[off + 1]) << 16 | u32(d[off + 2]) << 8 | u32(d[off + 3])
}

classOfg :: proc(d : []u8, cdef : int, glyph : u16) -> i32 {
	format := be16g(d, cdef)
	if format == 1 {
		start := int(be16g(d, cdef + 2))
		count := int(be16g(d, cdef + 4))
		if int(glyph) >= start && int(glyph) < start + count {
			return i32(be16g(d, cdef + 6 + (int(glyph) - start) * 2))
		}
		return -1
	} else if format == 2 {
		range_count := int(be16g(d, cdef + 2))
		for r in 0 ..< range_count {
			rec := cdef + 4 + r * 6
			start := int(be16g(d, rec))
			end := int(be16g(d, rec + 2))
			if int(glyph) >= start && int(glyph) <= end {
				return i32(be16g(d, rec + 4))
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
	num := int(be16g(data, base + 4))
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32g(data, rec + 8))
		}
	}
	ll := gs + int(be16g(data, gs + 8))
	lc := int(be16g(data, ll))
	dash := u16(stbtt.FindGlyphIndex(&info, '-'))
	gt := u16(stbtt.FindGlyphIndex(&info, '>'))
	lt := u16(stbtt.FindGlyphIndex(&info, '<'))
	eq := u16(stbtt.FindGlyphIndex(&info, '='))

	for i in 0 ..< lc {
		lo := ll + int(be16g(data, ll + 2 + i * 2))
		if be16g(data, lo) != 6 {
			continue
		}
		sc := int(be16g(data, lo + 4))
		for j in 0 ..< sc {
			so := lo + int(be16g(data, lo + 6 + j * 2))
			if be16g(data, so) != 2 {
				continue
			}
			in_cd := so + int(be16g(data, so + 6))
			back_cd := so + int(be16g(data, so + 4))
			look_cd := so + int(be16g(data, so + 8))
			di, gi, li, ei := classOfg(data, in_cd, dash), classOfg(data, in_cd, gt), classOfg(data, in_cd, lt), classOfg(data, in_cd, eq)
			db, gb := classOfg(data, back_cd, dash), classOfg(data, back_cd, gt)
			dl2, gl2 := classOfg(data, look_cd, dash), classOfg(data, look_cd, gt)
			fmt.printf("lookup %d: in[-=%d >=%d <=%d ==%d] back[-=%d >=%d] look[-=%d >=%d]\n",
				i, di, gi, li, ei, db, gb, dl2, gl2)
		}
	}
}
