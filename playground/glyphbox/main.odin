// 比较 Cascadia 连体半字形的横线粗细与亚像素相位
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

	dump :: proc(info : ^stbtt.fontinfo, scale : f32, gid : c.int, name : string) {
		x0, y0, x1, y1 : c.int
		stbtt.GetGlyphBitmapBox(info, gid, scale, scale, &x0, &y0, &x1, &y1)
		w, h := x1 - x0, y1 - y0
		fmt.printf("=== %s gid=%d box=(%d,%d)-(%d,%d) w=%d h=%d\n", name, gid, x0, y0, x1, y1, w, h)
		if w <= 0 || h <= 0 || w > 96 || h > 64 {
			fmt.println("  (blank or too big)")
			return
		}
		buf := make([]u8, w * h)
		defer delete(buf)
		stbtt.MakeGlyphBitmap(info, raw_data(buf), w, h, w, scale, scale, gid)
		for row in 0 ..< h {
			maxv := 0
			for col in 0 ..< w {
				if int(buf[row*w+col]) > maxv { maxv = int(buf[row*w+col]) }
			}
			mark := " "
			if maxv > 200 { mark = "#" } else if maxv > 100 { mark = "+" } else if maxv > 20 { mark = "." }
			fmt.printf("%s(%3d) ", mark, maxv)
			for col in 0 ..< w {
				v := buf[row*w+col]
				c := ' '
				if v > 200 { c = '#' } else if v > 100 { c = '+' } else if v > 20 { c = '.' }
				fmt.printf("%c", c)
			}
			fmt.println()
		}
	}

	// --> 三个半字形
	dump(&info, scale, 13869, "hyphen_start.seq")
	dump(&info, scale, 13868, "hyphen_middle.seq")
	dump(&info, scale, 14149, "greater_hyphen_end.seq")
	// === 连体
	dump(&info, scale, 14086, "equal_equal_equal.liga")
	dump(&info, scale, 14085, "equal_equal.liga")
	dump(&info, scale, 33, "equal (原始)")
}
