// 验证:fallback em 对齐修复后,两字体的 '你' 位图尺寸是否一致
package main

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"

main :: proc() {
	size : f32 = 40

	// 主字体
	main_data, err := os.read_entire_file_from_path("./resource/font/CascadiaCode/CaskaydiaCoveNerdFont-Regular.ttf", context.allocator)
	if err != nil {
		fmt.eprintln("main font read fail")
		return
	}
	defer delete(main_data)
	main_info : stbtt.fontinfo
	off := stbtt.GetFontOffsetForIndex(raw_data(main_data), 0)
	stbtt.InitFont(&main_info, raw_data(main_data), off)
	main_scale := stbtt.ScaleForPixelHeight(&main_info, size)
	main_em := main_scale / stbtt.ScaleForMappingEmToPixels(&main_info, 1.0)
	fmt.printf("主字体 scale=%.6f em=%vpx\n", main_scale, main_em)

	// fallback
	fb_data, err2 := os.read_entire_file_from_path("C:\\Windows\\Fonts\\msyh.ttc", context.allocator)
	if err2 != nil {
		fmt.eprintln("fb font read fail")
		return
	}
	defer delete(fb_data)
	fb_info : stbtt.fontinfo
	off2 := stbtt.GetFontOffsetForIndex(raw_data(fb_data), 0)
	stbtt.InitFont(&fb_info, raw_data(fb_data), off2)
	old_scale := stbtt.ScaleForPixelHeight(&fb_info, size)
	new_scale := stbtt.ScaleForMappingEmToPixels(&fb_info, main_em)
	fmt.printf("雅黑 旧scale=%.6f(em=%vpx) 新scale=%.6f(em=%vpx)\n",
		old_scale, old_scale / stbtt.ScaleForMappingEmToPixels(&fb_info, 1.0),
		new_scale, new_scale / stbtt.ScaleForMappingEmToPixels(&fb_info, 1.0))

	box_of :: proc(info : ^stbtt.fontinfo, scale : f32) -> (int, int) {
		x0, y0, x1, y1 : c.int
		stbtt.GetCodepointBitmapBox(info, '你', scale, scale, &x0, &y0, &x1, &y1)
		return int(x1 - x0), int(y1 - y0)
	}

	old_w, old_h := box_of(&fb_info, old_scale)
	new_w, new_h := box_of(&fb_info, new_scale)
	mw, mh := box_of(&main_info, main_scale)
	fmt.printf("'你' 主字体位图:   %d x %d\n", mw, mh)
	fmt.printf("'你' 雅黑旧方式:   %d x %d (偏小)\n", old_w, old_h)
	fmt.printf("'你' 雅黑新方式:   %d x %d (em 对齐)\n", new_w, new_h)
}
