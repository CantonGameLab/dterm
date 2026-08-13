package canvas

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

	console_id : u32, // 本 pane 的屏幕 id;0 = 空

	using scale_transform : ScaleTransform,
}

SplitType :: enum u8 {
	UpDown,
	LeftRight,
}

// 节点即窗口:几何、分割、内容(iter ms)一体
WindowTreeNode :: struct {
	iterms : [dynamic]Iterm,

	using transform : Transform,

	frame_width : u32, // 分割条像素宽
	frame_color : u32,

	parent_id : u32, // 0 = 无父(仅根)

	left_son_id : u32, // left or up
	right_son_id : u32, // right or down

	split_factor : f32, // 左子树所占空间

	split_type : SplitType,

	is_leaf : bool,
	in_use : bool, // 槽位占用标记;iterms 空合法,nil-ness 判空不可靠
}

window_tree_nodes : [MAX_TREE_NODE_SLOTS]WindowTreeNode
window_tree_nodes_count : u32 = 1

// 窗口分辨率(root 的初始尺寸;resize 时更新)
Window_Width : u32 = 1920
Window_Height : u32 = 1080

InitWindowTree :: proc() {
	window_tree_nodes[ROOT_WINDOW_TREE_NODE_ID] = WindowTreeNode {
		is_leaf = true,
		in_use = true,
		width = f32(Window_Width),
		height = f32(Window_Height),
	}
	window_tree_nodes[ROOT_WINDOW_TREE_NODE_ID].iterms = make([dynamic]Iterm)
	window_tree_nodes_count = ROOT_WINDOW_TREE_NODE_ID + 1
}

// 分配节点槽位(复用已释放);0 = 满
CreateWindowTreeNode :: proc() -> (id : u32) {
	for i in 1 ..< MAX_TREE_NODE_SLOTS {
		if window_tree_nodes[i].in_use {
			continue
		}
		window_tree_nodes[i] = WindowTreeNode { is_leaf = true, in_use = true }
		if u32(i) + 1 > window_tree_nodes_count {
			window_tree_nodes_count = u32(i) + 1
		}
		return u32(i)
	}
	return 0
}

GetWindowTreeNode :: proc(id : u32) -> ^WindowTreeNode {
	if id >= MAX_TREE_NODE_SLOTS {
		return nil
	}
	if !window_tree_nodes[id].in_use {
		return nil
	}
	return &window_tree_nodes[id]
}

// 树的根 = parent_id 为 0 的节点(分裂 root 后根迁移到新父)
WindowTreeRoot :: proc() -> u32 {
	for i in 1 ..< MAX_TREE_NODE_SLOTS {
		if window_tree_nodes[i].in_use && window_tree_nodes[i].parent_id == 0 {
			return u32(i)
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Iterm 数据操作(iterm 无独立 id,按节点内下标定位)
// ---------------------------------------------------------------------------

TreeNodeAddIterm :: proc(id : u32, type : ItermType, console_id : u32) -> (index : int, ok : bool) {
	node := GetWindowTreeNode(id)
	if node == nil {
		return 0, false
	}
	append(&node.iterms, Iterm { type = type, console_id = console_id })
	return len(node.iterms) - 1, true
}

TreeNodeRemoveIterm :: proc(id : u32, index : int) {
	node := GetWindowTreeNode(id)
	if node == nil || index < 0 || index >= len(node.iterms) {
		return
	}
	ordered_remove(&node.iterms, index)
}

ItermGet :: proc(node_id : u32, index : int) -> ^Iterm {
	node := GetWindowTreeNode(node_id)
	if node == nil || index < 0 || index >= len(node.iterms) {
		return nil
	}
	return &node.iterms[index]
}

// iterm 绝对矩形 = 节点几何 × scale(归一化)
ItermAbsoluteTransform :: proc(node_id : u32, index : int) -> Transform {
	node := GetWindowTreeNode(node_id)
	it := ItermGet(node_id, index)
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
TreeNodeSplit :: proc(id : u32, split_type : SplitType, factor : f32) -> (parent_id, right_id : u32, ok : bool) {
	node := GetWindowTreeNode(id)
	if node == nil {
		return 0, 0, false
	}
	parent := CreateWindowTreeNode()
	if parent == 0 {
		return 0, 0, false
	}
	right := CreateWindowTreeNode()
	if right == 0 {
		window_tree_nodes[parent] = {}
		return 0, 0, false
	}
	np := &window_tree_nodes[parent]
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
		if gp.left_son_id == id {
			gp.left_son_id = parent
		}
		if gp.right_son_id == id {
			gp.right_son_id = parent
		}
	}
	node.parent_id = parent
	np.left_son_id = id
	np.right_son_id = right
	window_tree_nodes[right].parent_id = parent
	RecalculateTransforms(parent)
	return parent, right, true
}

// 摘除子树并释放节点槽(含 iterms);根不可删;父变单子时提升兄弟顶替,保持满二叉树
TreeNodeRemove :: proc(id : u32) {
	if id == 0 || id == WindowTreeRoot() {
		return
	}
	node := GetWindowTreeNode(id)
	if node == nil {
		return
	}
	pid := node.parent_id
	parent := GetWindowTreeNode(pid)
	if parent != nil {
		if parent.left_son_id == id {
			parent.left_son_id = 0
		}
		if parent.right_son_id == id {
			parent.right_son_id = 0
		}
	}
	if !node.is_leaf {
		TreeNodeRemove(node.left_son_id)
		TreeNodeRemove(node.right_son_id)
	}
	delete(node.iterms)
	node^ = {}
	if parent == nil {
		return
	}
	switch {
	case parent.left_son_id != 0 && parent.right_son_id == 0:
		treeNodePromote(pid, parent.left_son_id)
	case parent.left_son_id == 0 && parent.right_son_id != 0:
		treeNodePromote(pid, parent.right_son_id)
	case parent.left_son_id == 0 && parent.right_son_id == 0:
		parent.is_leaf = true
	case:
		RecalculateTransforms(pid)
	}
}

// son 顶替 parent 的位置(几何继承,由上层重算覆盖)
treeNodePromote :: proc(parent_id, son_id : u32) {
	p := GetWindowTreeNode(parent_id)
	son := GetWindowTreeNode(son_id)
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
		if gp.left_son_id == parent_id {
			gp.left_son_id = son_id
		}
		if gp.right_son_id == parent_id {
			gp.right_son_id = son_id
		}
	}
	delete(p.iterms)
	p^ = {}
	if gpid != 0 {
		RecalculateTransforms(gpid)
	}
	// gpid == 0:son 成为新根,几何已继承
}

TreeNodeSetSplitFactor :: proc(id : u32, factor : f32) -> bool {
	node := GetWindowTreeNode(id)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_factor = max(0.05, min(0.95, factor))
	RecalculateTransforms(id)
	return true
}

TreeNodeSetSplitType :: proc(id : u32, split_type : SplitType) -> bool {
	node := GetWindowTreeNode(id)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_type = split_type
	RecalculateTransforms(id)
	return true
}

// 设子节点并同步父引用;son 是 id 的祖先时拒绝(成环)
TreeNodeSetLeftSon :: proc(id, son_id : u32) -> bool {
	return treeNodeSetSon(id, son_id, true)
}

TreeNodeSetRightSon :: proc(id, son_id : u32) -> bool {
	return treeNodeSetSon(id, son_id, false)
}

treeNodeSetSon :: proc(id, son_id : u32, is_left : bool) -> bool {
	node := GetWindowTreeNode(id)
	if node == nil || son_id == id {
		return false
	}
	if son_id != 0 {
		son := GetWindowTreeNode(son_id)
		if son == nil {
			return false
		}
		for p := node.parent_id; p != 0; p = window_tree_nodes[p].parent_id {
			if p == son_id {
				return false // son 在 id 的祖先链上,挂上去即成环
			}
		}
		if old := window_tree_nodes[son_id].parent_id; old != 0 && old != id {
			op := &window_tree_nodes[old]
			if op.left_son_id == son_id {
				op.left_son_id = 0
			}
			if op.right_son_id == son_id {
				op.right_son_id = 0
			}
		}
		window_tree_nodes[son_id].parent_id = id
	}
	if is_left {
		node.left_son_id = son_id
	} else {
		node.right_son_id = son_id
	}
	node.is_leaf = node.left_son_id == 0 && node.right_son_id == 0
	RecalculateTransforms(id)
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
RecalculateTransforms :: proc(id : u32) {
	node := GetWindowTreeNode(id)
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
