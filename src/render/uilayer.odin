// UI 层:基于 nanovg(抗锯齿矢量渲染)画悬浮控件。
// 替代自绘 DrawRoundRect(像素阶梯近似,碎边)。nanovg 用项目已有 GL 上下文,
// 自带 shader/字体图集;每帧在 DrawFrame 之后调用 UiBegin/UiDraw/UiEnd。
package render

import nvg "vendor:nanovg"
import nvg_gl "vendor:nanovg/gl"
import "core:os"
import "core:fmt"

ui_ctx : ^nvg.Context
ui_font : int = -1

// 初始化 nanovg 上下文 + 加载字体;返回 false 表示失败(UI 层禁用,不影响主渲染)
UiInit :: proc() -> bool {
	ui_ctx = nvg_gl.Create({.ANTI_ALIAS})
	if ui_ctx == nil {
		return false
	}
	// 加载字体并入 nanovg 字体图集(nanovg 自己光栅化,抗锯齿)。
	// free_loaded_data=true:nanovg 接管字体数据生命周期,确保光栅化时数据存活
	data, err := os.read_entire_file_from_path("./resource/font/CascadiaCode/CaskaydiaCoveNerdFont-Regular.ttf", context.allocator)
	if err != nil || len(data) == 0 {
		fmt.eprintln("nvg font load failed")
		return false
	}
	ui_font = nvg.CreateFontMem(ui_ctx, "ui", data, true)
	fmt.eprintln("nvg font id:", ui_font)
	return true
}

UiQuit :: proc() {
	if ui_ctx != nil {
		nvg_gl.Destroy(ui_ctx)
		ui_ctx = nil
	}
}

// 开始一帧 UI(用窗口物理像素尺寸);调用后绘制,末尾 UiEnd
UiBegin :: proc(w, h : f32) {
	if ui_ctx == nil {
		return
	}
	nvg.BeginFrame(ui_ctx, w, h, 1.0) // devicePixelRatio=1(物理像素)
}

UiEnd :: proc() {
	if ui_ctx == nil {
		return
	}
	nvg.EndFrame(ui_ctx)
}

// 绘制悬浮控制台(圆角长条 + 输入文本),锚定窗口区域右上角。
// (x,y,w,h) = 目标窗口区域;bar = canvas 的 CommandBar;theme = 终端配色。
UiDrawCommandBar :: proc(x, y, w, h : f32, input : string, bg, fg : u32, font_scale : f32) {
	if ui_ctx == nil {
		return
	}
	// 长条几何:宽 = 区域宽 70%,高 = 40px(UI 用固定行高),锚定右上角
	bar_w := w * 0.72
	bar_h := 40.0 * font_scale
	margin : f32 = 10
	bar_x := x + w - bar_w - margin
	bar_y := y + margin
	radius : f32 = bar_h * 0.5

	// 颜色:浅色底(fg)+ 深色文字(bg),与终端深底明显区分
	to_nvg :: proc(c : u32) -> nvg.Color {
		r := f32(c >> 16 & 0xFF) / 255
		g := f32(c >> 8 & 0xFF) / 255
		b := f32(c & 0xFF) / 255
		result : nvg.Color
		result[0] = r
		result[1] = g
		result[2] = b
		result[3] = 1
		return result
	}
	bar_bg := to_nvg(bg)   // 浅色底(theme.fg)

	// 背景圆角胶囊:浅色底 + 白色边框勾勒
	nvg.BeginPath(ui_ctx)
	nvg.RoundedRect(ui_ctx, bar_x, bar_y, bar_w, bar_h, radius)
	nvg.FillColor(ui_ctx, bar_bg)
	nvg.Fill(ui_ctx)

	// 输入文本(抗锯齿矢量):深色字(较浅底上,清晰可读)
	pad_x : f32 = 14
	nvg.FontFaceId(ui_ctx, ui_font)
	nvg.FontSize(ui_ctx, 22 * font_scale)
	nvg.TextAlign(ui_ctx, .LEFT, .MIDDLE)
	nvg.FillColor(ui_ctx, to_nvg(fg)) // 深色字(theme.bg)
	nvg.Text(ui_ctx, bar_x + pad_x, bar_y + bar_h * 0.5, input)

	// 光标(深色,同文字色,在文字末尾)
	cursor_x := bar_x + pad_x + 11.0 * f32(len(input))
	nvg.BeginPath(ui_ctx)
	nvg.RoundedRect(ui_ctx, cursor_x, bar_y + bar_h * 0.22, 2, bar_h * 0.56, 1)
	nvg.FillColor(ui_ctx, to_nvg(fg))
	nvg.Fill(ui_ctx)
}
