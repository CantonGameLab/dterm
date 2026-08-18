// 渲染系统隔离测试:SDL + GL 窗口 + 图元批(矩形/文字)。
// 预期窗口内容(自上而下):
//   红/绿/蓝三个矩形 + 一条白线
//   "HELLO WORLD 123"(浅灰,基线 y=300)
//   "你好,世界! ABC"(黄,中文走 fallback,基线 y=360)
//   灰底块 + 黑字 "gray on block"(验证前景色/背景色)
// 若这些都能正常显示,渲染系统(窗口/GL/着色器/批量/字体)即正常。
package main

import rd "../../src/render"
import fnt "../../src/font"
import s3 "vendor:sdl3"
import "core:fmt"

main :: proc() {
	if !rd.Init() {
		fmt.eprintln("render init failed")
		return
	}
	defer rd.Quit()

	font_h, ok := fnt.LoadFont("resource/font/Go-Mono/GoMonoNerdFontMono-Regular.ttf", 24)
	if !ok {
		fmt.eprintln("LoadFont failed")
		return
	}
	defer fnt.DestroyFont(font_h)

	quit := false
	for !quit {
		for e : s3.Event; s3.PollEvent(&e); {
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				quit = true
			}
		}

		rd.BeginFrame()

		// 彩色矩形(DrawRect + 颜色)
		rd.DrawRect(40, 40, 240, 120, 0xFF3B30)  // 红
		rd.DrawRect(320, 40, 240, 120, 0x34C759) // 绿
		rd.DrawRect(600, 40, 240, 120, 0x007AFF) // 蓝
		rd.DrawRect(40, 200, 800, 6, 0xFFFFFF)   // 白线

		// 文字(DrawText,基线坐标)
		rd.DrawText(font_h, "HELLO WORLD 123", 40, 300, 0xDCDCDC)
		rd.DrawText(font_h, "你好,世界! ABC", 40, 360, 0xFFD60A)

		// 前景/背景叠加
		rd.DrawRect(40, 420, 320, 90, 0x8E8E93)
		rd.DrawText(font_h, "gray on block", 50, 470, 0x000000)

		rd.EndFrame()
	}
}
