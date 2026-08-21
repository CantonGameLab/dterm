package canvas

import mem "../memory"

MAX_TREE_NODE_SLOTS :: 2000
ROOT_WINDOW_TREE_NODE_ID :: 1 // 硬编码根节点:transform = 窗口分辨率,position = {0,0}

ItermType :: enum u16 {
	Console,
	FrameBuffer,
}

// 绝对几何:像素坐标,由布局层按 split tree 递归算出
Transform :: struct {
	position_x : f32, // 矩形的左上角
	position_y : f32,
	height : f32,
	width : f32,
}

// 相对节点几何的归一化缩放:绝对矩形 = 节点 Transform × scale
ScaleTransform :: struct {
	scale_x : f32,
	scale_y : f32,
	scale_height : f32,
	scale_width : f32,
}

Iterm :: struct {
	layer : u16,
	type : ItermType,

	console_id : mem.Handle, // 本 pane 的屏幕句柄;0 = 空

	using scale_transform : ScaleTransform,
}

SplitType :: enum u8 {
	UpDown,
	LeftRight,
}

// 节点即窗口:几何、分割、内容(iter ms)一体
WindowTreeNode :: struct {
	iterms : [dynamic]Iterm,

	main_console_id : u32,

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

InitWindowTree :: proc() {
	mem.AllocAt(&window_tree_nodes, ROOT_WINDOW_TREE_NODE_ID, WindowTreeNode {
		is_leaf = true,
		width = f32(Window_Width),
		height = f32(Window_Height),
	})
	window_tree_nodes.data[ROOT_WINDOW_TREE_NODE_ID].iterms = make([dynamic]Iterm)
}

CreateWindowTreeNode :: proc() -> (h : mem.Handle) {
	return mem.Alloc(&window_tree_nodes, WindowTreeNode { is_leaf = true })
}

GetWindowTreeNode :: proc(h : mem.Handle) -> ^WindowTreeNode {
	return mem.Get(&window_tree_nodes, h)
}

// 树的根 = parent_id 为 0 的节点(分裂 root 后根迁移到新父)
WindowTreeRoot :: proc() -> mem.Handle {
	for i in 1 ..< MAX_TREE_NODE_SLOTS {
		if mem.Alive(&window_tree_nodes, i) && window_tree_nodes.data[i].parent_id.id == 0 {
			return mem.Handle { id = u32(i), generation = window_tree_nodes.generations[i] }
		}
	}
	return {}
}

// ---------------------------------------------------------------------------
// Iterm 数据操作(iterm 无独立 id,按节点内下标定位)
// ---------------------------------------------------------------------------

TreeNodeAddIterm :: proc(h : mem.Handle, type : ItermType, console_h : mem.Handle) -> (index : int, ok : bool) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return 0, false
	}
	append(&node.iterms, Iterm { type = type, console_id = console_h })
	return len(node.iterms) - 1, true
}

TreeNodeRemoveIterm :: proc(h : mem.Handle, index : int) {
	node := GetWindowTreeNode(h)
	if node == nil || index < 0 || index >= len(node.iterms) {
		return
	}
	ordered_remove(&node.iterms, index)
}

ItermGet :: proc(node_h : mem.Handle, index : int) -> ^Iterm {
	node := GetWindowTreeNode(node_h)
	if node == nil || index < 0 || index >= len(node.iterms) {
		return nil
	}
	return &node.iterms[index]
}

// iterm 绝对矩形 = 节点几何 × scale(归一化)
ItermAbsoluteTransform :: proc(node_h : mem.Handle, index : int) -> Transform {
	node := GetWindowTreeNode(node_h)
	it := ItermGet(node_h, index)
	if node == nil || it == nil {
		return {}
	}
	return Transform {
		position_x = node.position_x + node.width * it.scale_x,
		position_y = node.position_y + node.height * it.scale_y,
		width = node.width * it.scale_width,
		height = node.height * it.scale_height,
	}
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

// 摘除子树并释放节点槽(含 iterms);根不可删;父变单子时提升兄弟顶替,保持满二叉树
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
	delete(node.iterms)
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
	delete(p.iterms)
	mem.Free(&window_tree_nodes, parent_h)
	if gpid.id != 0 {
		RecalculateTransforms(gpid)
	}
	// gpid == 0:son 成为新根,几何已继承
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
		for p := node.parent_id; p.id != 0; p = window_tree_nodes.data[p.id].parent_id {
			if p == son_h {
				return false // son 在 id 的祖先链上,挂上去即成环
			}
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
