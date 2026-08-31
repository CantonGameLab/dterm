// 窗口表数据:Window(会话句柄 + 字体变体集)的生命周期操作。
// 窗口与树节点分离:TreeNode.window_id 挂载;创建/销毁/ensureWindow 归本文件。
// 字体集 = 主字体 + Bold/Italic/BoldItalic 变体(0 = 无此变体,渲染走合成兜底);
// 每个变体一个引用计数(SetWindowFont 装载、销毁窗口释放)。
package canvas

import fnt "../font"
import mem "../memory"
import "core:strings"

// 窗口:leaf 节点承载的内容(console 应用 + 字体变体集)。
// 与树节点分离:交换/移动窗口只交换 TreeNode.window_id。
Window :: struct {
	console_id : mem.Handle, // 绑定的 Console;0 = 空
	font_id : mem.Handle, // 主字体(LaunchConsole 时挂到 console);0 = 未设
	font_bold : mem.Handle, // Bold 变体(0 = 无,渲染双描兜底)
	font_italic : mem.Handle, // Italic 变体(0 = 无,渲染斜切兜底)
	font_bold_italic : mem.Handle, // Bold Italic 变体(0 = 无)
	font_input : string, // 原始字体输入名(字号重载/继承 clone;所有权归窗口)
	auto_close : bool, // console 应用退出后自动销毁本窗口
}

windows : mem.GenArray(MAX_WINDOW_SLOTS, Window)

// 新建窗口(内容实体,尚未挂载到节点)
CreateWindow :: proc() -> (h : mem.Handle) {
	return mem.Alloc(&windows, Window {})
}

GetWindow :: proc(h : mem.Handle) -> ^Window {
	return mem.Get(&windows, h)
}

// 渲染查询:style(bold/italic)→ 变体字体句柄 + 各维度"合成兜底"标志。
// 变体存在 = 真 face(不再合成);不存在 = 主字体 + 渲染层按标志兜底
// (bold_syn → 双描,italic_syn → 斜切)。
WindowFontVariant :: proc(h : mem.Handle, bold, italic : bool) -> (fh : mem.Handle, bold_syn, italic_syn : bool) {
	win := GetWindow(h)
	if win == nil {
		return {}, true, true
	}
	switch {
	case bold && italic:
		if win.font_bold_italic.id != 0 {
			return win.font_bold_italic, false, false
		}
		if win.font_bold.id != 0 {
			return win.font_bold, false, true
		}
		if win.font_italic.id != 0 {
			return win.font_italic, true, false
		}
		return win.font_id, true, true
	case bold:
		if win.font_bold.id != 0 {
			return win.font_bold, false, false
		}
		return win.font_id, true, false
	case italic:
		if win.font_italic.id != 0 {
			return win.font_italic, false, false
		}
		return win.font_id, false, true
	}
	return win.font_id, false, false
}

// 释放窗口槽(含字体引用集);调用方负责先销毁 console
DestroyWindowSlot :: proc(h : mem.Handle) {
	win := GetWindow(h)
	if win == nil {
		return
	}
	releaseFontSet(win)
	mem.Free(&windows, h)
}

// 释放窗口的字体引用集(主 + 3 变体;各自引用计数归零即可复用)+ 输入名
releaseFontSet :: proc(win : ^Window) {
	if win.font_id.id != 0 {
		fnt.ReleaseFont(win.font_id)
		win.font_id = {}
	}
	if win.font_bold.id != 0 {
		fnt.ReleaseFont(win.font_bold)
		win.font_bold = {}
	}
	if win.font_italic.id != 0 {
		fnt.ReleaseFont(win.font_italic)
		win.font_italic = {}
	}
	if win.font_bold_italic.id != 0 {
		fnt.ReleaseFont(win.font_bold_italic)
		win.font_bold_italic = {}
	}
	if win.font_input != "" {
		delete(win.font_input)
		win.font_input = ""
	}
}

// 继承另一窗口的完整字体集(会话启动 split 新窗;引用 ×4 + 输入名 clone)
inheritFontSet :: proc(dst : ^Window, src : ^Window) {
	if src.font_id.id != 0 {
		dst.font_id = src.font_id
		fnt.RetainFont(src.font_id)
	}
	if src.font_bold.id != 0 {
		dst.font_bold = src.font_bold
		fnt.RetainFont(src.font_bold)
	}
	if src.font_italic.id != 0 {
		dst.font_italic = src.font_italic
		fnt.RetainFont(src.font_italic)
	}
	if src.font_bold_italic.id != 0 {
		dst.font_bold_italic = src.font_bold_italic
		fnt.RetainFont(src.font_bold_italic)
	}
	if src.font_input != "" {
		dst.font_input = strings.clone(src.font_input)
	}
}

// 取节点挂载的窗口;无窗口则自动创建并挂载(仅 leaf)
ensureWindow :: proc(node_h : mem.Handle) -> ^Window {
	if win := NodeWindow(node_h); win != nil {
		return win
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return nil
	}
	win_h := CreateWindow()
	if win_h.id == 0 {
		return nil
	}
	TreeNodeSetWindow(node_h, win_h)
	return GetWindow(win_h)
}
