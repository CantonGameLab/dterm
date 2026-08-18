// SDL 事件层:事件 → 数据变更。事件是数据的生产者,渲染是纯消费者。
// 与 render 互不依赖,只在 main 里被编排。
package event

import s3 "vendor:sdl3"
import cv "../canvas"
import inp "../input"

// 轮询并应用全部事件;返回 true = 请求退出
Poll :: proc() -> bool {
	quit := false
	for e : s3.Event; s3.PollEvent(&e); {
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			quit = true
		case .WINDOW_PIXEL_SIZE_CHANGED: // 物理像素尺寸(渲染/布局用);WINDOW_RESIZED 是逻辑点尺寸
			cv.WindowTreeSetRootSize(u32(e.window.data1), u32(e.window.data2))
		case .KEY_DOWN, .KEY_UP, .TEXT_INPUT:
			inp.Handle(&e)
		}
	}
	return quit
}
