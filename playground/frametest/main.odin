// 验证 frame 布局:root 800x600,分裂后左右子各占 (800-3)/2,分割条 3px 明黄
package main

import cv "../../src/canvas"
import "core:fmt"

fails := 0

check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-44s %s\n", name, status)
}

approx :: proc(a, b : f32) -> bool {
	d := a - b
	if d < 0 {
		d = -d
	}
	return d < 0.01
}

main :: proc() {
	root := cv.CreateWindowTreeRoot()
	cv.WindowTreeSetRootSize(800, 600)

	// root 默认 frame
	r := cv.GetWindowTreeNode(root)
	check("root frame 默认 3px", r.frame_width == 3)
	check("root frame 默认明黄", r.frame_color == 0xFFFF00)

	// 分裂 → 新父接管 root 位置,root 变左子(leaf)
	_, right, ok := cv.TreeNodeSplit(root, .LeftRight, 0.5)
	check("分裂成功", ok)
	nr := cv.GetWindowTreeNode(cv.WindowTreeRoot())
	left := nr.left_son_id
	check("原 root 成为左子", left == root)
	l := cv.GetWindowTreeNode(left)
	rr := cv.GetWindowTreeNode(right)

	// 左 398.5 / 条 3 / 右 398.5(avail=797)
	check("左子宽 = 398.5", approx(l.width, 398.5))
	check("右子起点 = 401.5(左+3)", approx(rr.position_x, 401.5))
	check("右子宽 = 398.5", approx(rr.width, 398.5))
	check("frame 继承到子节点", rr.frame_width == 3 && rr.frame_color == 0xFFFF00)

	// 再分裂左子(上下):左子高 600,avail=597,上 298.5/条 3/下 298.5
	_, down, ok2 := cv.TreeNodeSplit(left, .UpDown, 0.5)
	check("纵向分裂成功", ok2)
	u := cv.GetWindowTreeNode(left) // 上子 = left 本身
	d := cv.GetWindowTreeNode(down)
	check("上子高 = 298.5", approx(u.height, 298.5))
	check("下子起点 y = 301.5(上+3)", approx(d.position_y, 301.5))

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
