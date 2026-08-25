// GSUB 解析调试:打印 sfnt 表目录与 lookup 结构
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
	fmt.printf("base=%d scaler=0x%08X numTables=%d\n", base, be32(data, base), be16(data, base + 4))
	num := int(be16(data, base + 4))
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		tag := string(data[rec:rec + 4])
		fmt.printf("  %-6s offset=%d len=%d\n", tag, be32(data, rec + 8), be32(data, rec + 12))
	}
	// GSUB 表结构
	gs := -1
	for i in 0 ..< num {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == "GSUB" {
			gs = int(be32(data, rec + 8))
		}
	}
	if gs < 0 {
		fmt.println("no GSUB")
		return
	}
	fmt.printf("GSUB at %d: version=%d.%d scriptOff=%d featureOff=%d lookupListOff=%d\n",
		gs, be16(data, gs), be16(data, gs + 2),
		be16(data, gs + 4), be16(data, gs + 6), be16(data, gs + 8))
	ll := gs + int(be16(data, gs + 8))
	lc := int(be16(data, ll))
	fmt.printf("lookupList at %d: count=%d\n", ll, lc)
	for i in 0 ..< lc {
		lo := ll + int(be16(data, ll + 2 + i * 2))
		if be16(data, lo) == 4 { fmt.printf("  lookup %d: type=4 subs=%d\n", i, be16(data, lo + 4)) } else if be16(data, lo) == 6 { fmt.printf("  lookup %d: type=6 subs=%d\n", i, be16(data, lo + 4)) }
	}
}



