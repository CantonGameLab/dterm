// 窗口树数据:WindowTreeNode(节点)+ Transform(几何)+ SplitType/FocusDirection(方向枚举)。
// 树结构操作(分裂/摘除/挂载/重算/焦点/命中)+ 每帧树遍历编排(ConsoleUpdateTree)。
// 焦点是树状态;命中测试(nodeAtPoint)属树几何。
package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"

MAX_TREE_NODE_SLOTS :: 2000

ROOT_WINDOW_TREE_NODE_ID :: 1 // 硬编码根节点:transform = 窗口分辨率,position = {0,0}

// 绝对几何:像素坐标,由布局层按 split tree 递归算出
Transform :: struct {
	position_x : f32, // 矩形的左上角
	position_y : f32,
	height : f32,
	width : f32,
}

SplitType :: enum u8 {
	UpDown,
	LeftRight,
}

MAX_WINDOW_SLOTS :: 256

// 树节点:纯结构(几何/分割/父子/挂载窗口)。leaf 挂 window_id,内部节点 = 0
WindowTreeNode :: struct {
	window_id : mem.Handle, // 挂载的窗口;0 = 空(仅 leaf 有意义)

	using transform : Transform,

	frame_width : u32, // 分割条像素宽
	frame_color : u32,

	parent_id : mem.Handle, // 0 = 无父(仅根)

	left_son_id : mem.Handle, // left or up
	right_son_id : mem.Handle, // right or down

	split_factor : f32, // 左子树所占空间

	split_type : SplitType,

	is_leaf : bool,
}

window_tree_nodes : mem.GenArray(MAX_TREE_NODE_SLOTS, WindowTreeNode)

// 窗口分辨率(root 的初始尺寸;resize 时更新)
Window_Width : u32 = 1920

Window_Height : u32 = 1080

// 分割条默认样式:明黄色,3 像素宽
DEFAULT_FRAME_COLOR :: 0xFFFF00

DEFAULT_FRAME_WIDTH :: 1

// 当前聚焦的 window(leaf);0 = 无。全局唯一。
focused_node : mem.Handle

InitWindowTree :: proc() {
	mem.AllocAt(&window_tree_nodes, ROOT_WINDOW_TREE_NODE_ID, WindowTreeNode {
		is_leaf = true,
		frame_width = DEFAULT_FRAME_WIDTH,
		frame_color = DEFAULT_FRAME_COLOR,
		width = f32(Window_Width),
		height = f32(Window_Height),
	})
}

CreateWindowTreeNode :: proc() -> (h : mem.Handle) {
	return mem.Alloc(&window_tree_nodes, WindowTreeNode {
		is_leaf = true,
		frame_width = DEFAULT_FRAME_WIDTH,
		frame_color = DEFAULT_FRAME_COLOR,
	})
}

GetWindowTreeNode :: proc(h : mem.Handle) -> ^WindowTreeNode {
	return mem.Get(&window_tree_nodes, h)
}

// 按 id 构造当前世代的有效句柄(指令字符串的 @id 用);槽不存在返回 0
NodeHandleById :: proc(id : u32) -> mem.Handle {
	if id == 0 || int(id) >= window_tree_nodes.next {
		return {}
	}
	if !mem.Alive(&window_tree_nodes, int(id)) {
		return {}
	}
	return mem.Handle { id = id, generation = window_tree_nodes.generations[id] }
}

// 树的根 = parent_id 为 0 的节点(分裂 root 后根迁移到新父)
WindowTreeRoot :: proc() -> mem.Handle {
	for i in 1 ..< MAX_TREE_NODE_SLOTS {
		if node := mem.GetIndex(&window_tree_nodes, i); node != nil && node.parent_id.id == 0 {
			return mem.Handle { id = u32(i), generation = window_tree_nodes.generations[i] }
		}
	}
	return {}
}

// 清空整个窗口树(释放所有节点);之后可重新 CreateWindowTreeRoot
ResetWindowTree :: proc() {
	root := WindowTreeRoot()
	if root.id != 0 {
		TreeNodeRemoveAll(root)
	}
}

// 递归释放子树(含根),不保留结构
TreeNodeRemoveAll :: proc(h : mem.Handle) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		TreeNodeRemoveAll(node.left_son_id)
		TreeNodeRemoveAll(node.right_son_id)
	}
	mem.Free(&window_tree_nodes, h)
}

// ---------------------------------------------------------------------------
// 焦点
// ---------------------------------------------------------------------------
SetFocus :: proc(node_h : mem.Handle) {
	focused_node = node_h
}

GetFocus :: proc() -> mem.Handle {
	return focused_node
}

FocusDirection :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

// 方向导航:找焦点 leaf 在 dir 方向上的相邻 leaf。
// 上行找同轴边界祖先,下行找最远侧 leaf;无邻居返回 0。
FocusNeighbor :: proc(from : mem.Handle, dir : FocusDirection) -> mem.Handle {
	cur := from
	for {
		node := GetWindowTreeNode(cur)
		if node == nil || node.parent_id.id == 0 {
			return {}
		}
		parent := GetWindowTreeNode(node.parent_id)
		if parent == nil {
			return {}
		}
		is_horiz := dir == .Left || dir == .Right
		same_axis := (is_horiz && parent.split_type == .LeftRight) || (!is_horiz && parent.split_type == .UpDown)
		if same_axis {
			// 焦点在当前侧时,另一侧即候选;否则继续上行
			if dir == .Left && cur == parent.right_son_id {
				return focusDescend(parent.left_son_id, dir)
			}
			if dir == .Right && cur == parent.left_son_id {
				return focusDescend(parent.right_son_id, dir)
			}
			if dir == .Up && cur == parent.right_son_id {
				return focusDescend(parent.left_son_id, dir)
			}
			if dir == .Down && cur == parent.left_son_id {
				return focusDescend(parent.right_son_id, dir)
			}
		}
		cur = node.parent_id
	}
}

// 从候选根下行到最远侧 leaf;跨轴时固定取左/上子
focusDescend :: proc(h : mem.Handle, dir : FocusDirection) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		return h
	}
	is_horiz := dir == .Left || dir == .Right
	if is_horiz && node.split_type == .LeftRight {
		if dir == .Left {
			return focusDescend(node.right_son_id, dir) // 找最右
		}
		return focusDescend(node.left_son_id, dir) // 找最左
	}
	if !is_horiz && node.split_type == .UpDown {
		if dir == .Up {
			return focusDescend(node.right_son_id, dir) // 找最下
		}
		return focusDescend(node.left_son_id, dir) // 找最上
	}
	// 跨轴:固定取左/上子(简单方案)
	return focusDescend(node.left_son_id, dir)
}

// ---------------------------------------------------------------------------
// 节点内容操作(leaf 节点挂载一个窗口)
// ---------------------------------------------------------------------------
// 挂载/摘除窗口(0 = 摘除);仅 leaf 有效。交换窗口 = 交换两节点的 window_id
TreeNodeSetWindow :: proc(h : mem.Handle, win_h : mem.Handle) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || !node.is_leaf {
		return false
	}
	node.window_id = win_h
	return true
}

// 取节点挂载的窗口;内部节点或空返回 nil(句柄有效性由 GenArray 判定)
NodeWindow :: proc(h : mem.Handle) -> ^Window {
	node := GetWindowTreeNode(h)
	if node == nil {
		return nil
	}
	return GetWindow(node.window_id)
}

// leaf 节点几何即内容矩形(窗口占满节点)
NodeContentTransform :: proc(node_h : mem.Handle) -> Transform {
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return {}
	}
	return Transform {
		position_x = node.position_x,
		position_y = node.position_y,
		width = node.width,
		height = node.height,
	}
}

// 命中测试:包含点 (x, y)(窗口物理像素)的 leaf 节点;无命中返回 {}
nodeAtPoint :: proc(x, y : f32) -> mem.Handle {
	return nodeAtPointRec(WindowTreeRoot(), x, y)
}

nodeAtPointRec :: proc(h : mem.Handle, x, y : f32) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		if x >= node.position_x && x < node.position_x + node.width &&
			y >= node.position_y && y < node.position_y + node.height {
			return h
		}
		return {}
	}
	// 矩形互不重叠,顺序无关;先右后左保持稳定偏好
	if r := nodeAtPointRec(node.right_son_id, x, y); r.id != 0 {
		return r
	}
	return nodeAtPointRec(node.left_son_id, x, y)
}

// ---------------------------------------------------------------------------
// WindowTreeNode 数据操作
// ---------------------------------------------------------------------------
// 分裂:id 保留为左子树,新分配父节点接管其位置,右子为空叶子
TreeNodeSplit :: proc(h : mem.Handle, split_type : SplitType, factor : f32) -> (parent_h, right_h : mem.Handle, ok : bool) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}, {}, false
	}
	parent_h = CreateWindowTreeNode()
	if parent_h.id == 0 {
		return {}, {}, false
	}
	right_h = CreateWindowTreeNode()
	if right_h.id == 0 {
		mem.Free(&window_tree_nodes, parent_h)
		return {}, {}, false
	}
	np := &window_tree_nodes.data[parent_h.id]
	np.parent_id = node.parent_id // 接管 id 在父中的位置(根分裂则成为新根)
	np.is_leaf = false
	np.split_type = split_type
	np.split_factor = max(0.05, min(0.95, factor))
	np.frame_width = node.frame_width
	np.frame_color = node.frame_color
	np.position_x = node.position_x // 几何继承 id 原区域,子区域由布局重算
	np.position_y = node.position_y
	np.width = node.width
	np.height = node.height
	if gp := GetWindowTreeNode(np.parent_id); gp != nil {
		if gp.left_son_id == h {
			gp.left_son_id = parent_h
		}
		if gp.right_son_id == h {
			gp.right_son_id = parent_h
		}
	}
	node.parent_id = parent_h
	np.left_son_id = h
	np.right_son_id = right_h
	window_tree_nodes.data[right_h.id].parent_id = parent_h
	RecalculateTransforms(parent_h)
	return parent_h, right_h, true
}

// 摘除子树并释放节点槽(含 iterms/font);根不可删;父变单子时提升兄弟顶替,保持满二叉树
TreeNodeRemove :: proc(h : mem.Handle) {
	if h.id == 0 || h == WindowTreeRoot() {
		return
	}
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	pid := node.parent_id
	parent := GetWindowTreeNode(pid)
	if parent != nil {
		if parent.left_son_id == h {
			parent.left_son_id = {}
		}
		if parent.right_son_id == h {
			parent.right_son_id = {}
		}
	}
	if !node.is_leaf {
		TreeNodeRemove(node.left_son_id)
		TreeNodeRemove(node.right_son_id)
	}
	mem.Free(&window_tree_nodes, h)
	if parent == nil {
		return
	}
	switch {
	case parent.left_son_id.id != 0 && parent.right_son_id.id == 0:
		treeNodePromote(pid, parent.left_son_id)
	case parent.left_son_id.id == 0 && parent.right_son_id.id != 0:
		treeNodePromote(pid, parent.right_son_id)
	case parent.left_son_id.id == 0 && parent.right_son_id.id == 0:
		parent.is_leaf = true
	case:
		RecalculateTransforms(pid)
	}
}

// son 顶替 parent 的位置(几何继承,由上层重算覆盖)
treeNodePromote :: proc(parent_h, son_h : mem.Handle) {
	p := GetWindowTreeNode(parent_h)
	son := GetWindowTreeNode(son_h)
	if p == nil || son == nil {
		return
	}
	gpid := p.parent_id
	son.parent_id = gpid
	son.position_x = p.position_x
	son.position_y = p.position_y
	son.width = p.width
	son.height = p.height
	if gp := GetWindowTreeNode(gpid); gp != nil {
		if gp.left_son_id == parent_h {
			gp.left_son_id = son_h
		}
		if gp.right_son_id == parent_h {
			gp.right_son_id = son_h
		}
	}
	if gpid.id != 0 {
		mem.Free(&window_tree_nodes, parent_h)
		RecalculateTransforms(gpid)
		return
	}
	// parent 是根(无父):根壳常驻,直接吸收 son(后续分裂/删除依赖稳定的根槽;
	// 释放根会让其 id 进空闲池,被复用成"第二个根")
	p.is_leaf = son.is_leaf
	p.window_id = son.window_id
	p.left_son_id = son.left_son_id
	p.right_son_id = son.right_son_id
	if sl := GetWindowTreeNode(p.left_son_id); sl != nil {
		sl.parent_id = parent_h
	}
	if sr := GetWindowTreeNode(p.right_son_id); sr != nil {
		sr.parent_id = parent_h
	}
	mem.Free(&window_tree_nodes, son_h)
	RecalculateTransforms(parent_h)
}

TreeNodeSetSplitFactor :: proc(h : mem.Handle, factor : f32) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_factor = max(0.05, min(0.95, factor))
	RecalculateTransforms(h)
	return true
}

TreeNodeSetSplitType :: proc(h : mem.Handle, split_type : SplitType) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_type = split_type
	RecalculateTransforms(h)
	return true
}

// 设子节点并同步父引用;son 是 id 的祖先时拒绝(成环)
TreeNodeSetLeftSon :: proc(h, son_h : mem.Handle) -> bool {
	return treeNodeSetSon(h, son_h, true)
}

TreeNodeSetRightSon :: proc(h, son_h : mem.Handle) -> bool {
	return treeNodeSetSon(h, son_h, false)
}

treeNodeSetSon :: proc(h, son_h : mem.Handle, is_left : bool) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || son_h == h {
		return false
	}
	if son_h.id != 0 {
		son := GetWindowTreeNode(son_h)
		if son == nil {
			return false
		}
		// 环检测:son 在 id 的祖先链上则挂载即成环;每步经句柄判有效
		for p := node.parent_id; p.id != 0; {
			if p == son_h {
				return false
			}
			parent := GetWindowTreeNode(p)
			if parent == nil {
				break
			}
			p = parent.parent_id
		}
		if old := son.parent_id; old.id != 0 && old != h {
			if op := GetWindowTreeNode(old); op != nil {
				if op.left_son_id == son_h {
					op.left_son_id = {}
				}
				if op.right_son_id == son_h {
					op.right_son_id = {}
				}
			}
		}
		son.parent_id = h
	}
	if is_left {
		node.left_son_id = son_h
	} else {
		node.right_son_id = son_h
	}
	node.is_leaf = node.left_son_id.id == 0 && node.right_son_id.id == 0
	RecalculateTransforms(h)
	return true
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------
// 窗口分辨率变化:更新 root 尺寸并整体重算
WindowTreeSetRootSize :: proc(width, height : u32) {
	root := GetWindowTreeNode(WindowTreeRoot())
	if root == nil {
		return
	}
	Window_Width = width
	Window_Height = height
	root.position_x = 0
	root.position_y = 0
	root.width = f32(width)
	root.height = f32(height)
	RecalculateTransforms(WindowTreeRoot())
}

// 按 split_factor / split_type / frame_width 递归划分子节点几何
RecalculateTransforms :: proc(h : mem.Handle) {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return
	}
	left := GetWindowTreeNode(node.left_son_id)
	right := GetWindowTreeNode(node.right_son_id)
	if left == nil || right == nil {
		return // 正常二叉树,内部节点恒双子
	}
	fw := f32(node.frame_width)
	switch node.split_type {
	case .LeftRight:
		avail := node.width - fw
		lw := avail * node.split_factor
		left.position_x = node.position_x
		left.position_y = node.position_y
		left.width = lw
		left.height = node.height
		right.position_x = node.position_x + lw + fw
		right.position_y = node.position_y
		right.width = avail - lw
		right.height = node.height
	case .UpDown:
		avail := node.height - fw
		lh := avail * node.split_factor
		left.position_x = node.position_x
		left.position_y = node.position_y
		left.width = node.width
		left.height = lh
		right.position_x = node.position_x
		right.position_y = node.position_y + lh + fw
		right.width = node.width
		right.height = avail - lh
	}
	RecalculateTransforms(node.left_son_id)
	RecalculateTransforms(node.right_son_id)
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

// 遍历窗口树,更新每个 leaf 节点绑定的 Console 的布局(尺寸变化时
// Resize ConPTY)并拉取输出。由 main 每帧调用一次;递归属于树结构操作,归 canvas 管理。
ConsoleUpdateTree :: proc(node_h : mem.Handle) {
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		ConsoleUpdateTree(node.left_son_id)
		ConsoleUpdateTree(node.right_son_id)
		return
	}
	win := NodeWindow(node_h)
	if win == nil || GetConsole(win.console_id) == nil {
		return
	}
	console_h := win.console_id
	console := GetConsole(console_h)
	if console == nil {
		return
	}

	//检测Console 是否需要resize
	t := NodeContentTransform(node_h)
	m := fnt.GetMetrics(console.font_id)

	old_rows, old_cols := console.rows, console.cols
	ConsoleUpdateLayout(console_h, t, m.cell_width, m.cell_height)
	if console.rows != old_rows || console.cols != old_cols {
		ct.Resize(console.conpty_handle, console.cols, console.rows)
	}

	//通过vtparser自动更新Console
	UpdateConsole(console_h)
}

