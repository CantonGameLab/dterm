// SDL 事件层(源模块,DAG 起点):事件泵 → 分发到各模块。
//   窗口尺寸 → canvas(树根几何);键/鼠/文本 → input 设备通道。
// 与 render 互不依赖;main 每帧按序调用 Update。
package event

import s3 "vendor:sdl3"
import cv "../canvas"
import inp "../input"

quit_requested : bool

// 每帧唯一入口:poll 全部 SDL 事件并分发;退出请求经 QuitRequested 暴露
Update :: proc() {
	for e : s3.Event; s3.PollEvent(&e); {
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			quit_requested = true
		case .WINDOW_PIXEL_SIZE_CHANGED: // 物理像素尺寸(渲染/布局用);WINDOW_RESIZED 是逻辑点尺寸
			cv.WindowTreeSetRootSize(u32(e.window.data1), u32(e.window.data2))
		case .KEY_DOWN, .KEY_UP, .TEXT_INPUT:
			inp.Handle(&e)
		case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
			inp.Handle(&e) // 鼠标原始状态进 input 通道,绑定/编码由 canvas 层决策
		}
	}
}

// 轮询并应用全部事件;返回 true = 请求退出(兼容旧名)
Poll :: proc() -> (quit : bool) {
	Update()
	return quit_requested
}

// 退出请求(窗口关闭/QUIT)
QuitRequested :: proc() -> bool {
	return quit_requested
}
