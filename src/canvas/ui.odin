// UI 定制数据:页签/状态栏/FPS 等 UI 文本共用一份字体(可定制项,userapi)。
// 渲染只读 GetUIFont;错误 = 保留旧字体(自愈)。默认 = reset 目标。
package canvas

import fnt "../font"
import mem "../memory"
import "core:fmt"

UI_DEFAULT_FONT :: "consola"
UI_DEFAULT_SIZE :: 18.0

ui_font : mem.Handle // 0 = 未设置(首次 Get 惰性加载默认)
ui_font_size : f32
ui_font_default_done : bool // 默认字体已尝试(失败不再每帧重试)

// 设置 UI 字体(LoadFont;失败保留旧字体,返回 false)
SetUIFont :: proc(path : string, size : f32) -> bool {
	new_font, ok := fnt.LoadFont(path, size)
	if !ok {
		fmt.eprintln("SetUIFont: LoadFont failed:", path, size)
		return false
	}
	ui_font = new_font
	ui_font_size = size
	ui_font_default_done = true
	return true
}

// 取 UI 字体句柄(渲染度量/文本;未设置时惰性加载默认 consola 18)
GetUIFont :: proc() -> mem.Handle {
	if ui_font.id == 0 && !ui_font_default_done {
		ui_font_default_done = true
		ui_font, _ = fnt.LoadFont(UI_DEFAULT_FONT, UI_DEFAULT_SIZE)
	}
	return ui_font
}

// 回默认(consola 18)
ResetUIFont :: proc() {
	ui_font = {}
	ui_font_size = UI_DEFAULT_SIZE
	ui_font_default_done = false
}
