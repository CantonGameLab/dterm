// 窗口树:leaf 节点 = 一个 window = 一个终端应用(console),
// 内部节点 = 纯分割容器。工具 iterm 为管理工具浮层(锚定于节点几何)。
package canvas

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

// 管理工具类型(dterm 内置 UI,不走 conpty;后续按需补充)
ToolType :: enum u8 {
	Console,   // 工具控制台(dterm 内部命令/输出)
	FileTree,  // 侧边文件树
	Preview,   // 预览面板
	StatusBar, // 状态栏
	Terminal,  // 备用终端面板
}

// 工具 iterm 锚定:大小是绝对像素,位置由双锚点决定。
// 对齐规则:iterm 系数坐标转化的绝对坐标,永远等于 window 系数坐标转化的绝对坐标:
//   window_pos + window_size*window_coord == iterm_pos + iterm_size*iterm_coord
// 即 iterm_pos = window_pos + window_size*window_coord - iterm_size*iterm_coord。
// 例:双锚点 (0,0) = 左上角贴 window 左上角;(0.5,0.5) = 中心对齐。
Iterm :: struct {
	tool_type : ToolType,
	console_id : mem.Handle, // 工具渲染目标(内部 console,conpty_handle = 0);0 = 空
	layer : u16, // 绘制顺序层(小 = 先画,被上层覆盖)

	width, height : f32, // 绝对大小(px)

	iterm_ax, iterm_ay : f32, // iterm 自身系数坐标(锚点,0..1)
	window_ax, window_ay : f32, // window 系数坐标(锚点,0..1)
}

// 窗口:leaf 节点承载的内容(console 应用 + 字体 + 工具浮层)。
// 与树节点分离:交换/移动窗口只交换 TreeNode.window_id。
Window :: struct {
	console_id : mem.Handle, // 绑定的 Console;0 = 空
	font_id : mem.Handle, // 窗口字体(LaunchConsole 时挂到 console);0 = 未设
	auto_close : bool, // console 应用退出后自动销毁本窗口
	iterms : [dynamic]Iterm, // 管理工具浮层(锚定于所属节点几何)
}

MAX_WINDOW_SLOTS :: 256

windows : mem.GenArray(MAX_WINDOW_SLOTS, Window)

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

// 悬浮控制台:命令输入框,锚定焦点 window 右上角。
// 输入缓冲:行超宽时横向滚动(翻页),不折行;光标在缓冲内可自由移动。
MAX_CMD_INPUT :: 512
CommandBar :: struct {
	visible : bool,
	input : [MAX_CMD_INPUT]u8, // 输入缓冲
	len : int, // 已输入字节数
	cursor : int, // 光标位置(字节,0..len;插入点)
	view_offset : int, // 横向滚动视口起点(字节),跟随光标
}

command_bar : CommandBar

// 切换控制台可见性
ToggleCommandBar :: proc() {
	command_bar.visible = !command_bar.visible
	if command_bar.visible {
		command_bar.len = 0
		command_bar.cursor = 0
		command_bar.view_offset = 0
	}
}

CommandBarVisible :: proc() -> bool {
	return command_bar.visible
}

// 在光标处插入字节(0 = 光标前插入)
CommandBarInsert :: proc(data : []byte) {
	for b in data {
		if command_bar.len >= len(command_bar.input) {
			break
		}
		// 光标后字符右移
		for i := command_bar.len; i > command_bar.cursor; i -= 1 {
			command_bar.input[i] = command_bar.input[i - 1]
		}
		command_bar.input[command_bar.cursor] = b
		command_bar.cursor += 1
		command_bar.len += 1
	}
}

// 退格:删光标前一个字符
CommandBarBackspace :: proc() {
	if command_bar.cursor <= 0 {
		return
	}
	for i := command_bar.cursor - 1; i < command_bar.len - 1; i += 1 {
		command_bar.input[i] = command_bar.input[i + 1]
	}
	command_bar.cursor -= 1
	command_bar.len -= 1
}

// Delete:删光标后一个字符
CommandBarDelete :: proc() {
	if command_bar.cursor >= command_bar.len {
		return
	}
	for i := command_bar.cursor; i < command_bar.len - 1; i += 1 {
		command_bar.input[i] = command_bar.input[i + 1]
	}
	command_bar.len -= 1
}

// 光标左右移动(1 = 右,-1 = 左)
CommandBarCursorMove :: proc(dir : int) {
	command_bar.cursor = clamp(command_bar.cursor + dir, 0, command_bar.len)
}

// 光标移动到行首/行尾
CommandBarHome :: proc() {
	command_bar.cursor = 0
}

CommandBarEnd :: proc() {
	command_bar.cursor = command_bar.len
}

// 按词左右移动(跳过空白到下一个词边界)
CommandBarWordMove :: proc(dir : int) {
	is_space :: proc(b : u8) -> bool {
		return b == ' ' || b == '\t'
	}
	c := command_bar.cursor
	if dir > 0 {
		// 右移:跳过当前词和中间空白,停在下一词首
		for c < command_bar.len && is_space(command_bar.input[c]) {
			c += 1
		}
		for c < command_bar.len && !is_space(command_bar.input[c]) {
			c += 1
		}
		command_bar.cursor = c
	} else {
		// 左移:跳过前词和前空白,停在前一非空白后(或 0)
		if c > 0 {
			// 跳过光标前空白
			c -= 1
			for c > 0 && is_space(command_bar.input[c - 1]) {
				c -= 1
			}
			// 跳到词首
			for c > 0 && !is_space(command_bar.input[c - 1]) {
				c -= 1
			}
		}
		command_bar.cursor = c
	}
}

// 取走输入并清空(执行后调用)
CommandBarTake :: proc() -> string {
	s := string(command_bar.input[:command_bar.len])
	command_bar.len = 0
	command_bar.cursor = 0
	command_bar.view_offset = 0
	return s
}

// 返回输入缓冲指针(渲染层读取绘制)
GetCommandBar :: proc() -> ^CommandBar {
	return &command_bar
}

InitWindowTree :: proc() {
	mem.AllocAt(&window_tree_nodes, ROOT_WINDOW_TREE_NODE_ID, WindowTreeNode {
		is_leaf = true,
		frame_width = DEFAULT_FRAME_WIDTH,
		frame_color = DEFAULT_FRAME_COLOR,
		width = f32(Window_Width),
		height = f32(Window_Height),
	})
}

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
	mem.Free(&windows, h)
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
// Iterm 数据操作(iterm 无独立 id,按窗口内下标定位;窗口自动创建)
// ---------------------------------------------------------------------------

TreeNodeAddIterm :: proc(h : mem.Handle, tool_type : ToolType) -> (index : int, ok : bool) {
	win := nodeWindowEnsure(h)
	if win == nil {
		return 0, false
	}
	append(&win.iterms, Iterm { tool_type = tool_type })
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
	mem.Free(&window_tree_nodes, parent_h)
	if gpid.id != 0 {
		RecalculateTransforms(gpid)
	} else {
		// gpid == 0:son 成为新根,几何已继承 parent;但须重算子节点
		// 布局(左/右子宽仍是旧的一半,不会自动变全宽)
		RecalculateTransforms(son_h)
	}
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
