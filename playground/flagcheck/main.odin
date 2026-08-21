// 检查 lookupFlag 与子表偏移:markFilteringSet 存在性
package main

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"

be16m :: proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}
be32m :: proc(d : []u8, off : int) -> u32 {
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
	num := int(be16m(data, base + 4))
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32m(data, rec + 8))
		}
	}
	ll := gs + int(be16m(data, gs + 8))
	lc := int(be16m(data, ll))
	mask_count := 0
	type_counts : [9]int
	for i in 0 ..< lc {
		lo := ll + int(be16m(data, ll + 2 + i * 2))
		lt := int(be16m(data, lo))
		flag := int(be16m(data, lo + 2))
		sc := int(be16m(data, lo + 4))
		if lt >= 1 && lt <= 8 {
			type_counts[lt] += 1
		}
		if flag & 0x10 != 0 {
			mask_count += 1
			if mask_count <= 5 {
				fmt.printf("lookup %d: type=%d flag=0x%X subs=%d\n", i, lt, flag, sc)
			}
		}
	}
	fmt.printf("type counts: ")
	for t in 1 ..= 8 {
		if type_counts[t] > 0 {
			fmt.printf("t%d=%d ", t, type_counts[t])
		}
	}
	fmt.printf("\nmarkFilteringSet lookups: %d\n", mask_count)
	// 全部 type4/type6 lookup 的 flag
	fmt.printf("type4/6 flags: ")
	for i in 0 ..< lc {
		lo := ll + int(be16m(data, ll + 2 + i * 2))
		lt := int(be16m(data, lo))
		if lt == 4 || lt == 6 {
			flag := int(be16m(data, lo + 2))
			if flag & 0x10 != 0 {
				fmt.printf("lookup%d(flag=%X) ", i, flag)
			}
		}
	}
	fmt.println()
}
