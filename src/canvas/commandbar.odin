// 悬浮控制台数据:CommandBar 编辑状态(输入缓冲/光标/视图偏移)。
// 作为 iterm 工具(ToolType.CommandBar)内联在窗口的 iterms 条目里(fat struct,
// Iterm 里 using commandbar : CommandBar 提升字段),显隐 = 条目 visible。
// 每窗独立,切焦点各自保留;渲染在 render/uilayer(scene 按 iterm 锚定几何绘制),
// 输入状态机在 main。
package canvas

import mem "../memory"

// 编辑状态;归属 Iterm 条目(经 using 提升为 iterm 字段)
MAX_CMD_INPUT :: 512

CommandBar :: struct {
	input : [MAX_CMD_INPUT]u8, // 输入缓冲
	len : int, // 已输入字节数
	cursor : int, // 光标位置(字节,0..len;插入点)
	view_offset : int, // 横向滚动视口起点(字节),跟随光标
}

// 窗口的 .CommandBar iterm 下标;无则 -1
commandBarItermIndex :: proc(win : ^Window) -> int {
	for i in 0 ..< len(win.iterms) {
		if win.iterms[i].tool_type == .CommandBar {
			return i
		}
	}
	return -1
}

// 切换 id(或焦点)window 的悬浮控制台:首开建 iterm 条目(锚右上角,状态零值);
// 再开切换显隐(打开时清空编辑状态)。返回 true = 窗口有效(已创建/已切换)。
ToggleCommandBar :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	if idx := commandBarItermIndex(win); idx >= 0 {
		it := &win.iterms[idx]
		it.visible = !it.visible
		if it.visible {
			clearBar(&it.commandbar)
		}
		return true
	}
	// 首开:条目状态即零值,无需清零
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return false
	}
	append(&win.iterms, Iterm {
		tool_type = .CommandBar,
		layer = 100,
		visible = true,
		width = node.width * 0.72,
		height = 40, // 与 uilayer 的 bar_h 一致
		window_ax = 1.0, window_ay = 0.0, // 锚窗口右上角
		iterm_ax = 1.0, iterm_ay = 0.0,
	})
	return true
}

CommandBarVisible :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	idx := commandBarItermIndex(win)
	return idx >= 0 && win.iterms[idx].visible
}

// 取 id(或焦点)window 的 CommandBar 条目状态;无条目返回 nil
GetCommandBar :: proc(id : mem.Handle = {}) -> ^CommandBar {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return nil
	}
	win := NodeWindow(node_h)
	if win == nil {
		return nil
	}
	idx := commandBarItermIndex(win)
	if idx < 0 {
		return nil
	}
	return &win.iterms[idx].commandbar
}

clearBar :: proc(bar : ^CommandBar) {
	bar.len = 0
	bar.cursor = 0
	bar.view_offset = 0
}

// 在光标处插入字节(0 = 光标前插入)
CommandBarInsert :: proc(data : []byte, id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil {
		for b in data {
			if bar.len >= len(bar.input) {
				break
			}
			// 光标后字符右移
			for i := bar.len; i > bar.cursor; i -= 1 {
				bar.input[i] = bar.input[i - 1]
			}
			bar.input[bar.cursor] = b
			bar.cursor += 1
			bar.len += 1
		}
	}
}

// 退格:删光标前一个字符
CommandBarBackspace :: proc(id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil && bar.cursor > 0 {
		for i := bar.cursor - 1; i < bar.len - 1; i += 1 {
			bar.input[i] = bar.input[i + 1]
		}
		bar.cursor -= 1
		bar.len -= 1
	}
}

// Delete:删光标后一个字符
CommandBarDelete :: proc(id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil && bar.cursor < bar.len {
		for i := bar.cursor; i < bar.len - 1; i += 1 {
			bar.input[i] = bar.input[i + 1]
		}
		bar.len -= 1
	}
}

// 光标左右移动(1 = 右,-1 = 左)
CommandBarCursorMove :: proc(dir : int, id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil {
		bar.cursor = clamp(bar.cursor + dir, 0, bar.len)
	}
}

// 光标移动到行首/行尾
CommandBarHome :: proc(id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil {
		bar.cursor = 0
	}
}

CommandBarEnd :: proc(id : mem.Handle = {}) {
	if bar := GetCommandBar(id); bar != nil {
		bar.cursor = bar.len
	}
}

// 按词左右移动(跳过空白到下一个词边界)
CommandBarWordMove :: proc(dir : int, id : mem.Handle = {}) {
	bar := GetCommandBar(id)
	if bar == nil {
		return
	}
	is_space :: proc(b : u8) -> bool {
		return b == ' ' || b == '\t'
	}
	c := bar.cursor
	if dir > 0 {
		// 右移:跳过当前词和中间空白,停在下一词首
		for c < bar.len && is_space(bar.input[c]) {
			c += 1
		}
		for c < bar.len && !is_space(bar.input[c]) {
			c += 1
		}
		bar.cursor = c
	} else {
		// 左移:跳过前词和前空白,停在前一非空白后(或 0)
		if c > 0 {
			// 跳过光标前空白
			c -= 1
			for c > 0 && is_space(bar.input[c - 1]) {
				c -= 1
			}
			// 跳到词首
			for c > 0 && !is_space(bar.input[c - 1]) {
				c -= 1
			}
		}
		bar.cursor = c
	}
}

// 取走输入并清空(执行后调用)
CommandBarTake :: proc(id : mem.Handle = {}) -> string {
	if bar := GetCommandBar(id); bar != nil {
		s := string(bar.input[:bar.len])
		clearBar(bar)
		return s
	}
	return ""
}
