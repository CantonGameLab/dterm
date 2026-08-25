// 验证 iterm 锚定变换:双系数坐标对齐规则
//   iterm_pos = window_pos + window_size*window_coord - iterm_size*iterm_coord
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

check :: proc(name : string, got_x, got_y, want_x, want_y : f32) {
	ok := got_x == want_x && got_y == want_y
	status := "PASS"
	if !ok {
		status = "FAIL"
	}
	fmt.printf("%-28s got=(%.1f, %.1f) want=(%.1f, %.1f) %s\n", name, got_x, got_y, want_x, want_y, status)
}

main :: proc() {
	cv.InitWindowTree()
	root := cv.WindowTreeRoot()
	// window:位置 (100, 200),大小 800x600
	cv.GetWindowTreeNode(root).position_x = 100
	cv.GetWindowTreeNode(root).position_y = 200
	cv.GetWindowTreeNode(root).width = 800
	cv.GetWindowTreeNode(root).height = 600

	add :: proc(root : mem.Handle) -> int {
		idx, _ := cv.TreeNodeAddIterm(root, cv.ItermType.FrameBuffer)
		return idx
	}

	// 1) 双锚点 (0,0):iterm 左上角贴 window 左上角
	i0 := add(root)
	it := cv.ItermGet(root, i0)
	it.width, it.height = 100, 50
	it.iterm_anchor_x, it.iterm_anchor_y = 0, 0
	it.window_anchor_x, it.window_anchor_y = 0, 0
	t := cv.ItermAbsoluteTransform(root, i0)
	check("left-top", t.position_x, t.position_y, 100, 200)

	// 2) 双锚点 (1,1):iterm 右下角贴 window 右下角
	i1 := add(root)
	it = cv.ItermGet(root, i1)
	it.width, it.height = 100, 50
	it.iterm_anchor_x, it.iterm_anchor_y = 1, 1
	it.window_anchor_x, it.window_anchor_y = 1, 1
	t = cv.ItermAbsoluteTransform(root, i1)
	check("right-bottom", t.position_x, t.position_y, 800, 750) // 100+800-100, 200+600-50

	// 3) 双锚点 (0.5,0.5):中心对齐
	i2 := add(root)
	it = cv.ItermGet(root, i2)
	it.width, it.height = 100, 50
	it.iterm_anchor_x, it.iterm_anchor_y = 0.5, 0.5
	it.window_anchor_x, it.window_anchor_y = 0.5, 0.5
	t = cv.ItermAbsoluteTransform(root, i2)
	check("center", t.position_x, t.position_y, 450, 475) // 100+400-50, 200+300-25

	// 4) iterm 锚点 (0,0) 对齐 window 锚点 (1,0):iterm 左上角贴 window 右上角
	i3 := add(root)
	it = cv.ItermGet(root, i3)
	it.width, it.height = 100, 50
	it.iterm_anchor_x, it.iterm_anchor_y = 0, 0
	it.window_anchor_x, it.window_anchor_y = 1, 0
	t = cv.ItermAbsoluteTransform(root, i3)
	check("left-top @ right-top", t.position_x, t.position_y, 900, 200) // 100+800-0, 200+0-0
}

