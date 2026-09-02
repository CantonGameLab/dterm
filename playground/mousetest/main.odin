// 分屏拖拽回归:命中(含正交等距)/开始/更新/clamp/释放/右键取消回滚/
// 自愈(page 切换)/独占(不切页不聚焦)/IDLE 右键不开始。
// 纯几何:PageCreate + 手动分裂,不启动会话(宿主无关)。
// 条位置 = 派生量(随 split_factor 移动),所有命中/拖拽用动态计算点。
package main

import cv "../../src/canvas"
import inp "../../src/input"
import "core:fmt"
import "core:math"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

checkNear :: proc(name : string, got, want : f32) {
	if math.abs(got - want) < 1e-4 {
		fmt.printf("  ok  %s (%.6f)\n", name, got)
	} else {
		fmt.printf("FAIL  %s got=%.6f want=%.6f\n", name, got, want)
	}
}

mouseFrame :: proc(x, y : f32, press, release : u8, left, right, moved : bool) {
	inp.Mouse.x_ok = true
	inp.Mouse.x = x
	inp.Mouse.y = y
	inp.Mouse.press = press
	inp.Mouse.release = release
	inp.Mouse.left = left
	inp.Mouse.right = right
	inp.Mouse.moved = moved
}

// 当前竖条中心 x(左子右缘 + fw/2;唯一公式,与命中/绘制同源)
barCX :: proc(h : $T) -> f32 {
	n := cv.GetWindowTreeNode(h)
	left := cv.GetWindowTreeNode(n.left_son_id)
	return left.position_x + left.width + f32(n.frame_width) * 0.5
}

// 当前横条中心 y
barCY :: proc(h : $T) -> f32 {
	n := cv.GetWindowTreeNode(h)
	left := cv.GetWindowTreeNode(n.left_son_id)
	return left.position_y + left.height + f32(n.frame_width) * 0.5
}

main :: proc() {
	page := cv.PageCreate()
	if page.id == 0 {
		fmt.println("page create failed")
		return
	}
	cv.PageSwitch(page)
	root := cv.PageTreeRoot(page)

	// 树的根分裂为 LeftRight 0.5:根几何 1920 x 1048(默认)
	parent, right, ok := cv.TreeNodeSplit(root, .LeftRight, 0.5)
	if !ok {
		fmt.println("split failed")
		return
	}
	pr := cv.GetWindowTreeNode(parent)
	avail := pr.width - f32(pr.frame_width)
	cy := pr.position_y + pr.height * 0.5

	// ---- 命中(0.5 状态) ----
	cx := barCX(parent)
	check("hit center", cv.SplitFrameHit(cx, cy) == parent, true)
	check("hit edge pad", cv.SplitFrameHit(cx + 2.0, cy) == parent, true)
	check("miss outside", cv.SplitFrameHit(cx + 200, cy).id == 0, true)
	check("miss y-range", cv.SplitFrameHit(cx, pr.position_y + pr.height + 50).id == 0, true)

	// ---- 开始 + 更新 +100px ----
	mouseFrame(cx, cy, 1, 0, true, false, false)
	cv.ProcessMouse()
	check("begin active", cv.SplitDragActive(), true)
	mouseFrame(cx + 100, cy, 0, 0, true, false, true)
	cv.ProcessMouse()
	checkNear("factor +100px", cv.GetWindowTreeNode(parent).split_factor, 0.5 + 100.0 / avail)
	check("focus unchanged during drag", cv.CurrentPage().focused.id == 0, true)

	// ---- clamp ----
	mouseFrame(cx + 5000, cy, 0, 0, true, false, true)
	cv.ProcessMouse()
	checkNear("factor clamp high", cv.GetWindowTreeNode(parent).split_factor, 0.95)

	// ---- 释放保留 ----
	mouseFrame(cx + 5000, cy, 0, 1, false, false, false)
	cv.ProcessMouse()
	check("release inactive", cv.SplitDragActive(), false)
	checkNear("factor kept after release", cv.GetWindowTreeNode(parent).split_factor, 0.95)

	// 复位 0.5(后续段落几何固定;TreeNodeSetSplitFactor 单点入口)
	cv.TreeNodeSetSplitFactor(parent, 0.5)
	cx = barCX(parent)

	// ---- 右键取消回滚(origin = 0.5) ----
	mouseFrame(cx, cy, 1, 0, true, false, false)
	cv.ProcessMouse()
	mouseFrame(cx + 600, cy, 0, 0, true, false, true)
	cv.ProcessMouse() // 因子已漂移(动态条位置,位置不重算也正确)
	check("cancel active before", cv.SplitDragActive(), true)
	mouseFrame(cx + 600, cy, 4, 0, true, true, false)
	cv.ProcessMouse()
	check("cancel inactive", cv.SplitDragActive(), false)
	checkNear("cancel restores origin", cv.GetWindowTreeNode(parent).split_factor, 0.5)

	// ---- 取消后 moved 不再影响 ----
	mouseFrame(cx + 1000, cy, 0, 0, false, false, true)
	cv.ProcessMouse()
	checkNear("no update after cancel", cv.GetWindowTreeNode(parent).split_factor, 0.5)

	// ---- IDLE 右键条上不开始 ----
	mouseFrame(cx, cy, 4, 0, false, true, false)
	cv.ProcessMouse()
	check("idle right press no drag", cv.SplitDragActive(), false)

	// ---- 独占:拖拽中 tab 区按下不切页不聚焦 ----
	p2 := cv.PageCreate()
	if p2.id == 0 {
		fmt.println("page2 create failed")
		return
	}
	mouseFrame(cx, cy, 1, 0, true, false, false)
	cv.ProcessMouse()
	check("drag active before exclusivity", cv.SplitDragActive(), true)
	foc_before := cv.CurrentPage().focused
	mouseFrame(cx, f32(cv.Window_Height) + 10, 1, 0, true, false, false) // tab 区(条下)
	cv.ProcessMouse()
	check("exclusive: page not switched", cv.PageCurrent() == page, true)
	check("exclusive: focus untouched", cv.CurrentPage().focused == foc_before, true)
	mouseFrame(cx, cy, 0, 1, false, false, false)
	cv.ProcessMouse()

	// ---- 自愈:拖拽中切页 → 下帧取消 ----
	mouseFrame(cx, cy, 1, 0, true, false, false)
	cv.ProcessMouse()
	check("drag active before paging", cv.SplitDragActive(), true)
	cv.PageSwitch(p2)
	mouseFrame(cx + 100, cy, 0, 0, true, false, true)
	cv.ProcessMouse()
	check("self-heal after page switch", cv.SplitDragActive(), false)
	checkNear("old page factor intact", cv.GetWindowTreeNode(parent).split_factor, 0.5)
	cv.PageSwitch(page)

	// ---- 正交树:横条命中 + 交叉点等距先序 ----
	un_h, _, ok2 := cv.TreeNodeSplit(right, .UpDown, 0.4)
	if !ok2 {
		fmt.println("updown split failed")
		return
	}
	un := cv.GetWindowTreeNode(un_h)
	hy := barCY(un_h)
	hz := un.position_x + un.width * 0.5 + f32(un.frame_width) * 0.5
	check("updown bar hit", cv.SplitFrameHit(hz + 100, hy) == un_h, true)
	// 交叉点(cx'=barCX(parent) 随 0.5 → 960, hy):竖条距 0 vs 横条 0 → 等距 → 先序先见 = 竖条
	check("orthogonal tie -> preorder first", cv.SplitFrameHit(barCX(parent), hy) == parent, true)
	// 偏横 (960+2, hy):横条距 0 < 竖条 2 → 横条(un)
	check("orthogonal nearer wins", cv.SplitFrameHit(barCX(parent) + 2.0, hy) == un_h, true)

	fmt.println("mousetest done")
}
