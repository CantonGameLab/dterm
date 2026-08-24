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
// (x,y,w,h) = 目标窗口区域;input = 完整输入;cursor = 光标字节位置;
// bg/fg = 底色/文字色;font_scale = 字号缩放。
UiDrawCommandBar :: proc(x, y, w, h : f32, input : string, cursor : int, bg, fg : u32, font_scale : f32) {
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
	pad_x : f32 = 14
	font_size : f32 = 22 * font_scale

	// 颜色:浅色底(bg)+ 深色文字(fg),与终端深底明显区分
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

	// 背景圆角胶囊
	nvg.BeginPath(ui_ctx)
	nvg.RoundedRect(ui_ctx, bar_x, bar_y, bar_w, bar_h, radius)
	nvg.FillColor(ui_ctx, to_nvg(bg))
	nvg.Fill(ui_ctx)

	nvg.FontFaceId(ui_ctx, ui_font)
	nvg.FontSize(ui_ctx, font_size)
	nvg.TextAlign(ui_ctx, .LEFT, .MIDDLE)
	nvg.FillColor(ui_ctx, to_nvg(fg)) // 文本颜色(深色字,浅底上清晰)
	base_y := bar_y + bar_h * 0.5

	// 视口:光标不可见时滚动,保证光标在显示范围内(超宽翻页,不折行)。
	// 光标前的文本宽度 = 视口起点到光标的偏移。
	if cursor > 0 {
		// 光标前文本
		pre := string(input[:min(cursor, len(input))])
		cursor_w := nvg.TextBounds(ui_ctx, 0, base_y, pre)
		// 显示区宽度(减左右 padding)
		avail := bar_w - 2 * pad_x
		if cursor_w > avail {
			// 视口右对齐:显示偏移 = 光标宽 - avail(再留光标后余量)
			// 简化为:从 input 中裁剪出"光标可见"的窗口
			scroll := cursor_w - avail + 10
			// 从 input 起点找字节偏移,使 pre 从 scroll 位置开始(线性近似:等宽字符)
			start := int(scroll / (font_size * 0.6)) // 近似字符宽
			if start > cursor {
				start = cursor
			}
			start = max(0, start)
			view := input[start:]
			nvg.Text(ui_ctx, bar_x + pad_x, base_y, view)
			// 光标宽 = 光标前可见部分宽度
			vis_pre := string(view[:cursor - start])
			cursor_x := bar_x + pad_x + nvg.TextBounds(ui_ctx, bar_x + pad_x, base_y, vis_pre)
			// 光标
			nvg.BeginPath(ui_ctx)
			nvg.RoundedRect(ui_ctx, cursor_x, bar_y + bar_h * 0.22, 2, bar_h * 0.56, 1)
			nvg.FillColor(ui_ctx, to_nvg(fg))
			nvg.Fill(ui_ctx)
			return
		}
	}

	nvg.Text(ui_ctx, bar_x + pad_x, base_y, input)
	// 光标:光标前文本宽度
	cursor_x := bar_x + pad_x + nvg.TextBounds(ui_ctx, bar_x + pad_x, base_y, string(input[:min(cursor, len(input))]))
	nvg.BeginPath(ui_ctx)
	nvg.RoundedRect(ui_ctx, cursor_x, bar_y + bar_h * 0.22, 2, bar_h * 0.56, 1)
	nvg.FillColor(ui_ctx, to_nvg(fg))
	nvg.Fill(ui_ctx)
}
