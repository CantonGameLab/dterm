// 窗口表数据:Window(会话句柄 + 字体 + 工具浮层)的生命周期操作。
// 窗口与树节点分离:TreeNode.window_id 挂载;创建/销毁/ensureWindow 归本文件。
package canvas

import mem "../memory"

// 窗口:leaf 节点承载的内容(console 应用 + 字体 + 工具浮层)。
// 与树节点分离:交换/移动窗口只交换 TreeNode.window_id。
Window :: struct {
	console_id : mem.Handle, // 绑定的 Console;0 = 空
	font_id : mem.Handle, // 窗口字体(LaunchConsole 时挂到 console);0 = 未设
	auto_close : bool, // console 应用退出后自动销毁本窗口
	iterms : [dynamic]Iterm, // 管理工具浮层(锚定于所属节点几何)
}

windows : mem.GenArray(MAX_WINDOW_SLOTS, Window)

// 新建窗口(内容实体,尚未挂载到节点)
CreateWindow :: proc() -> (h : mem.Handle) {
	return mem.Alloc(&windows, Window {})
}

GetWindow :: proc(h : mem.Handle) -> ^Window {
	return mem.Get(&windows, h)
}

// 释放窗口槽(含工具 iterms);调用方负责先销毁 console/font
DestroyWindowSlot :: proc(h : mem.Handle) {
	win := GetWindow(h)
	if win == nil {
		return
	}
	delete(win.iterms)
	// 清本窗口的悬浮控制台编辑状态(槽复用防脏数据)
	if h.id < MAX_WINDOW_SLOTS {
		command_bars[h.id] = {}
	}
	mem.Free(&windows, h)
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

