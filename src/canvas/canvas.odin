package canvas

import ct "../conpty"
import stbtt "vendor:stb/truetype"

MAX_TREE_NODE_SLOTS :: 2000

ItermType :: enum u16 {
	Console,
	FrameBuffer,
}

Transform :: struct {
	position_x : f32,
	position_y : f32,
	height : f32,
	width : f32,
}

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

Window :: struct {
	iterms : [dynamic]Iterm,
	using transform : Transform,
}

SplitType :: enum u8 {
	UpDown,
	LeftRight,
}

WindowTreeNode :: struct {
	left_son_id : u32, // left or up
	right_son_id : u32, // right or down
	split_type : SplitType,
	is_leaf : bool,
	split_factor : f32, // 左子树所占空间
}

windows : [MAX_TREE_NODE_SLOTS]Window
window_tree_nodes : [MAX_TREE_NODE_SLOTS]WindowTreeNode

// id 约定:0 号节点预分配为根(整屏),新 id 从 1 起;0 = 空
window_tree_nodes_count : u32 = 1

InitWindowTree :: proc() {
	window_tree_nodes[0] = WindowTreeNode {
		left_son_id  = 0,
		right_son_id = 0,
		is_leaf      = true,
		split_factor = 1,
	}
}

CreateWindowTreeNode :: proc() -> (id : u32) {
	if window_tree_nodes_count >= MAX_TREE_NODE_SLOTS {
		return 0
	}
	id = window_tree_nodes_count
	window_tree_nodes_count += 1
	window_tree_nodes[id] = WindowTreeNode {
		is_leaf = true,
	}
	return
}

GetWindow :: proc(id : u32) -> ^Window {
	if id >= MAX_TREE_NODE_SLOTS {
		return nil
	}
	return &windows[id]
}

GetWindowTreeNode :: proc(id : u32) -> ^WindowTreeNode {
	if id >= MAX_TREE_NODE_SLOTS {
		return nil
	}
	return &window_tree_nodes[id]
}
