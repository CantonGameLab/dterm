// 验证 oversample=1 下所有连体字形横线灰度一致
package main

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"

main :: proc() {
	path := "C:\\Users\\GroupTheory\\Source\\dterm\\resource\\font\\CascadiaCode\\CaskaydiaCoveNerdFont-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("read failed")
		return
	}
	defer delete(data)

	info : stbtt.fontinfo
	off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	stbtt.InitFont(&info, cast([^]byte)raw_data(data), off)

	size := f32(24)
	scale := stbtt.ScaleForPixelHeight(&info, size)

	dump :: proc(info : ^stbtt.fontinfo, scale : f32, gid : c.int, over : int, name : string) {
		x0, y0, x1, y1 : c.int
		stbtt.GetGlyphBitmapBox(info, gid, scale, scale, &x0, &y0, &x1, &y1)
		w, h := x1 - x0, y1 - y0
		buf := make([]u8, w * h)
		defer delete(buf)
		sub_x, sub_y : f32
		stbtt.MakeGlyphBitmapSubpixelPrefilter(info, raw_data(buf), w, h, w, scale, scale, 0, 0, i32(over), i32(over), &sub_x, &sub_y, gid)
		fmt.printf("=== %s over=%d sub_y=%.2f: ", name, over, sub_y)
		// 输出横线行(有主体灰度 >100 的行)的 max
		for row in 0 ..< h {
			left_max := 0
			for col in 0 ..< w / 3 {
				if int(buf[row*w+col]) > left_max {
					left_max = int(buf[row*w+col])
				}
			}
			if left_max > 100 {
				fmt.printf("y=%d:%d ", y0 + row, left_max)
			}
		}
		fmt.println()
	}

	fmt.println("oversample=1:")
	dump(&info, scale, 13869, 1, "hyphen_start (-->1)")
	dump(&info, scale, 13868, 1, "hyphen_middle (-->2)")
	dump(&info, scale, 14149, 1, "greater_hyphen_end (-->3)")
	dump(&info, scale, 14086, 1, "equal_equal_equal (===)")
	dump(&info, scale, 14085, 1, "equal_equal (==)")
	dump(&info, scale, 13815, 1, "hyphen_hyphen_hyphen (---)")
	dump(&info, scale, 17, 1, "hyphen 原始")
	fmt.println("oversample=2:")
	dump(&info, scale, 13869, 2, "hyphen_start (-->1)")
	dump(&info, scale, 13868, 2, "hyphen_middle (-->2)")
	dump(&info, scale, 14149, 2, "greater_hyphen_end (-->3)")
	dump(&info, scale, 14086, 2, "equal_equal_equal (===)")
}
