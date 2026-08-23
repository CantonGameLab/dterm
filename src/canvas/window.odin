// 窗口生命周期与会话管理:用户接口层,直接操作 canvas 状态。
// 语义完整、面向意图;是 userapi 平铺进 canvas 的结果(等 canvas 膨胀后再切子模块)。
// 约定:id 参数放最后、可省略(省略 = 当前焦点);0 = 空/focus。
package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"

// ---------------------------------------------------------------------------
// 窗口树
// ---------------------------------------------------------------------------

// 从空窗口树初始化根节点 + 根窗口,返回根节点 handle;重复调用幂等
CreateWindowTreeRoot :: proc() -> mem.Handle {
	InitWindowTree()
	root := WindowTreeRoot()
	win := CreateWindow()
	if win.id != 0 {
		TreeNodeSetWindow(root, win)
	}
	SetFocus(root)
	return root
}

// 对 id(或焦点)window 按 dir 分裂出新 window(新节点,无窗口内容);新窗成为焦点
SplitNewWindow :: proc(dir : SplitType, id : mem.Handle = {}) -> mem.Handle {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return {}
	}
	_, new_h, ok := TreeNodeSplit(node_h, dir, 0.5)
	if !ok {
		return {}
	}
	SetFocus(new_h)
	return new_h
}

// 删除 id(或焦点)window:关闭其 console 应用 + 会话,释放窗口,并从树中摘除。
// 目标是唯一剩余窗口(根)时,清空整个树(所有窗口关闭 = 程序可退出)。
DestroyWindow :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return false
	}
	win_h := node.window_id
	if win_h.id != 0 {
		win := GetWindow(win_h)
		if win != nil {
			// 关闭 console 应用 + 会话
			if win.console_id.id != 0 {
				console := GetConsole(win.console_id)
				if console != nil {
					if console.conpty_handle.id != 0 {
						ct.StopReadThread(console.conpty_handle)
						ct.DestroyConpty(console.conpty_handle)
					}
					DestroyConsole(win.console_id)
				}
			}
			// 释放窗口字体
			if win.font_id.id != 0 {
				fnt.DestroyFont(win.font_id)
			}
		}
		DestroyWindowSlot(win_h)
	}
	// 焦点落在被删窗:移到兄弟(顶替父位);兄弟内部节点则取最左 leaf
	if GetFocus() == node_h {
		brother := mem.Handle {}
		if parent := GetWindowTreeNode(node.parent_id); parent != nil {
			brother = parent.left_son_id == node_h ? parent.right_son_id : parent.left_son_id
		}
		if brother.id == 0 {
			brother = WindowTreeRoot()
		}
		if b := GetWindowTreeNode(brother); b != nil && !b.is_leaf {
			brother = firstLeaf(brother)
		}
		SetFocus(brother)
	}
	// 唯一剩余窗口(根):清空整个树
	if node_h == WindowTreeRoot() {
		ResetWindowTree()
		SetFocus({})
		return true
	}
	TreeNodeRemove(node_h)
	return true
}

// ---------------------------------------------------------------------------
// 分割配置
// ---------------------------------------------------------------------------

// 设置 id(或焦点)window 的父节点 split_factor(0.05..0.95)
SetSplitFactor :: proc(factor : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return false
	}
	return TreeNodeSetSplitFactor(node.parent_id, factor)
}

// 与 id(或焦点)window 的 dir 方向邻居交换窗口内容:只交换两节点的 window_id,
// 树结构不变
ExchangeWindow :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	a := GetWindowTreeNode(node_h)
	b := GetWindowTreeNode(target)
	if a == nil || b == nil {
		return false
	}
	a.window_id, b.window_id = b.window_id, a.window_id
	return true
}

// ---------------------------------------------------------------------------
// 字体
// ---------------------------------------------------------------------------

// 设定 id(或焦点)window 的字体样式(加载字体文件;LaunchConsole 前必须设置)。
// 节点无窗口时自动创建窗口。
SetWindowFont :: proc(path : string, size : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		return false
	}
	new_font, ok := fnt.LoadFont(path, size)
	if !ok {
		return false
	}
	if win.font_id.id != 0 {
		fnt.DestroyFont(win.font_id)
	}
	win.font_id = new_font
	// 若 console 已存在则立即应用
	if win.console_id.id != 0 {
		if console := GetConsole(win.console_id); console != nil {
			console.font_id = new_font
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// 会话(Console 应用)
// ---------------------------------------------------------------------------

// 在 id(或焦点)window 用 cmd 打开一个 console 应用;要求已设置字体(SetWindowFont)
LaunchConsole :: proc(cmd : string, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false // 无窗口,先 SetWindowFont(自动建窗)
	}
	if win.console_id.id != 0 {
		return false // 已有 console,不覆盖
	}
	if win.font_id.id == 0 {
		return false // 未设置字体,先 SetWindowFont
	}
	conpty_h, ok := ct.CreateConptyContext({80, 24}, cmd)
	if !ok {
		return false
	}
	if !ct.StartReadThread(conpty_h) {
		ct.DestroyConpty(conpty_h)
		return false
	}
	console_h, cok := CreateConsole(24, 80, conpty_h)
	if !cok {
		ct.StopReadThread(conpty_h)
		ct.DestroyConpty(conpty_h)
		return false
	}
	console := GetConsole(console_h)
	console.font_id = win.font_id
	win.console_id = console_h
	win.auto_close = true // 默认:应用退出即自动关窗;SetAutoClose(false) 可关闭
	return true
}

// 通过 conpty 向 id(或焦点)window 的 console 应用输入字符串
FeedConsole :: proc(data : []byte, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || win.console_id.id == 0 {
		return false
	}
	console := GetConsole(win.console_id)
	if console == nil || console.conpty_handle.id == 0 {
		return false
	}
	_, ok := ct.WriteConptyInput(console.conpty_handle, data)
	return ok
}

// 设置 id(或焦点)window 在 console 应用退出后是否自动销毁
SetAutoClose :: proc(auto_close : bool, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		return false
	}
	win.auto_close = auto_close
	return true
}

// ---------------------------------------------------------------------------
// 会话轮询(主循环每帧调用)
// ---------------------------------------------------------------------------

// 检测各 leaf 窗口的 console 会话是否结束(进程树归零或读管道断开);
// 结束后按该窗口 auto_close 决定:true → 销毁窗口,false → 保留窗口(画面冻结)。
// 返回 true = 仍有存活会话(主循环继续);false = 无任何存活会话(程序可退出)。
PollSessions :: proc() -> bool {
	alive := false
	// 先收集所有 leaf(遍历中不修改树,避免指针失效)
	leaves : [MAX_TREE_NODE_SLOTS]mem.Handle
	count := 0
	collectLeaves(WindowTreeRoot(), &leaves, &count)
	for i in 0 ..< count {
		node_h := leaves[i]
		win := NodeWindow(node_h)
		if win == nil || win.console_id.id == 0 {
			continue // 无窗口或空窗口,无会话
		}
		console := GetConsole(win.console_id)
		if console == nil || console.conpty_handle.id == 0 {
			continue // 工具 console 无会话
		}
		jobs := ct.JobActiveProcesses(console.conpty_handle)
		if jobs <= 0 || !ct.IsReadThreadAlive(console.conpty_handle) {
			// 会话结束:进程树归零 / Job 查询失败(-1,视为结束)/ 读管道断开。
			// 先消费剩余输出,再按 auto_close 处理
			updateWindow(node_h)
			if win.auto_close {
				DestroyWindow(node_h)
			}
		} else {
			alive = true // 仍有存活会话
		}
	}
	return alive
}

// 消费单个窗口 console 的剩余输出(会话结束前的最后内容)
updateWindow :: proc(node_h : mem.Handle) {
	win := NodeWindow(node_h)
	if win != nil && win.console_id.id != 0 {
		UpdateConsole(win.console_id)
	}
}

// 收集子树内所有 leaf 节点(定长数组,不分配)
collectLeaves :: proc(h : mem.Handle, leaves : ^[MAX_TREE_NODE_SLOTS]mem.Handle, count : ^int) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if node.is_leaf {
		if count^ < MAX_TREE_NODE_SLOTS {
			leaves[count^] = h
			count^ += 1
		}
		return
	}
	collectLeaves(node.left_son_id, leaves, count)
	collectLeaves(node.right_son_id, leaves, count)
}

// ---------------------------------------------------------------------------
// 焦点
// ---------------------------------------------------------------------------

// 设置 id 为当前焦点
SetFocusWindow :: proc(id : mem.Handle) -> bool {
	if GetWindowTreeNode(id) == nil {
		return false
	}
	SetFocus(id)
	return true
}

// 将 id(或焦点)window 的 dir 方向指向的 window 设为焦点
FocusMove :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	SetFocus(target)
	return true
}

// 查询当前焦点 window(节点 handle)
GetFocusWindow :: proc() -> mem.Handle {
	return GetFocus()
}

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------

// 统计当前 leaf(window)数量
WindowCount :: proc() -> int {
	count := 0
	countLeaves(WindowTreeRoot(), &count)
	return count
}

countLeaves :: proc(h : mem.Handle, count : ^int) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if node.is_leaf {
		count^ += 1
		return
	}
	countLeaves(node.left_son_id, count)
	countLeaves(node.right_son_id, count)
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

// id 省略(0)时解析为当前焦点
resolveWindow :: proc(id : mem.Handle) -> mem.Handle {
	if id.id != 0 {
		return id
	}
	return GetFocus()
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

// 取子树最左 leaf
firstLeaf :: proc(h : mem.Handle) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		return h
	}
	return firstLeaf(node.left_son_id)
}
