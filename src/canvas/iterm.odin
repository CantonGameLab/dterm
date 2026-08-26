// 工具浮层数据:Iterm(锚点/尺寸/渲染目标)+ ToolType 枚举。
// 挂在所属窗口的 iterms 数组上;锚定变换经窗口几何换算。
package canvas

import mem "../memory"

// 管理工具类型(dterm 内置 UI,不走 conpty;后续按需补充)
ToolType :: enum u8 {
	Console,   // 工具控制台(dterm 内部命令/输出)
	FileTree,  // 侧边文件树
	Preview,   // 预览面板
	StatusBar, // 状态栏
	Terminal,  // 备用终端面板
	CommandBar, // 悬浮控制台(F2 切换;编辑状态池按窗口索引,可见性 = iterm.visible)
}

// 工具 iterm 锚定:大小是绝对像素,位置由双锚点决定。
// 对齐规则:iterm 系数坐标转化的绝对坐标,永远等于 window 系数坐标转化的绝对坐标:
//   window_pos + window_size*window_coord == iterm_pos + iterm_size*iterm_coord
// 即 iterm_pos = window_pos + window_size*window_coord - iterm_size*iterm_coord。
// 例:双锚点 (0,0) = 左上角贴 window 左上角;(0.5,0.5) = 中心对齐。
// 工具私有数据 = fat struct:各类型状态直接内联(using 提升),无独立状态池。
Iterm :: struct {
	tool_type : ToolType,
	console_id : mem.Handle, // 工具渲染目标(内部 console,conpty_handle = 0);0 = 空
	layer : u16, // 绘制顺序层(小 = 先画,被上层覆盖)
	visible : bool, // 工具显隐(F2 切换 CommandBar 等)

	width, height : f32, // 绝对大小(px)

	iterm_ax, iterm_ay : f32, // iterm 自身系数坐标(锚点,0..1)
	window_ax, window_ay : f32, // window 系数坐标(锚点,0..1)

	// 按 tool_type 判别取用;using 使状态字段直接提升到 iterm 层
	using commandbar : CommandBar,
}

// ---------------------------------------------------------------------------
// Iterm 数据操作(iterm 无独立 id,按窗口内下标定位;窗口自动创建)
// ---------------------------------------------------------------------------
TreeNodeAddIterm :: proc(h : mem.Handle, tool_type : ToolType) -> (index : int, ok : bool) {
	win := nodeWindowEnsure(h)
	if win == nil {
		return 0, false
	}
	append(&win.iterms, Iterm { tool_type = tool_type, visible = true })
	return len(win.iterms) - 1, true
}

TreeNodeRemoveIterm :: proc(h : mem.Handle, index : int) {
	win := nodeWindowEnsure(h)
	if win == nil || index < 0 || index >= len(win.iterms) {
		return
	}
	ordered_remove(&win.iterms, index)
}

ItermGet :: proc(node_h : mem.Handle, index : int) -> ^Iterm {
	win := nodeWindowEnsure(node_h)
	if win == nil || index < 0 || index >= len(win.iterms) {
		return nil
	}
	return &win.iterms[index]
}

// iterm 绝对矩形 = 锚定变换(见 Iterm 注释)
ItermAbsoluteTransform :: proc(node_h : mem.Handle, index : int) -> Transform {
	node := GetWindowTreeNode(node_h)
	it := ItermGet(node_h, index)
	if node == nil || it == nil {
		return {}
	}
	return Transform {
		position_x = node.position_x + node.width * it.window_ax - it.width * it.iterm_ax,
		position_y = node.position_y + node.height * it.window_ay - it.height * it.iterm_ay,
		width = it.width,
		height = it.height,
	}
}

// 取节点窗口,无则自动创建(仅 leaf;内部节点返回 nil)
nodeWindowEnsure :: proc(node_h : mem.Handle) -> ^Window {
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
	node.window_id = win_h
	return GetWindow(win_h)
}

