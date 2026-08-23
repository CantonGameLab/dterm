// 验证三窗口布局构建逻辑(无头:不启动 ConPTY/不加载字体)。
// 布局:
//   0(root, LeftRight)
//   ├─ 1(UpDown)
//   │   ├─ 3
//   │   └─ 4
//   └─ 2
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

fails := 0

check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-40s %s\n", name, status)
}

leafCount :: proc(h : mem.Handle) -> int {
	node := cv.GetWindowTreeNode(h)
	if node == nil {
		return 0
	}
	if node.is_leaf {
		return 1
	}
	return leafCount(node.left_son_id) + leafCount(node.right_son_id)
}

main :: proc() {
	// 复刻 main.initWindows 的树操作序列(去掉字体/console 启动)
	root := cv.WindowTreeRoot()
	cv.InitWindowTree()
	root = cv.WindowTreeRoot()
	cv.SetFocus(root)

	// 0 分裂 → 1(左)+ 2(右);焦点 = 新窗 2
	_, win2, ok := cv.TreeNodeSplit(root, .LeftRight, 0.5)
	check("0 分裂成功", ok)
	cv.SetFocus(win2)

	// 焦点移到 1(左子),1 再分裂 → 3(上)+ 4(下)
	win1 := cv.FocusNeighbor(win2, .Left)
	check("找到左子 1", win1.id != 0)
	cv.SetFocus(win1)
	_, win4, ok2 := cv.TreeNodeSplit(win1, .UpDown, 0.5)
	check("1 分裂成功", ok2)
	win3 := cv.FocusNeighbor(win4, .Up)
	check("找到上子 3", win3.id != 0)

	// 结构验证
	check("leaf 数 = 3", leafCount(cv.WindowTreeRoot()) == 3)
	check("2 是 leaf", cv.GetWindowTreeNode(win2).is_leaf)
	check("3 是 leaf", cv.GetWindowTreeNode(win3).is_leaf)
	check("4 是 leaf", cv.GetWindowTreeNode(win4).is_leaf)

	// 根为 LeftRight,其左子 1 为 UpDown
	r := cv.GetWindowTreeNode(cv.WindowTreeRoot())
	check("根是 LeftRight", r.split_type == .LeftRight)
	one := cv.GetWindowTreeNode(r.left_son_id)
	check("左子 1 是 UpDown", one != nil && !one.is_leaf && one.split_type == .UpDown)
	check("1 的子 = 3,4", one.left_son_id == win3 && one.right_son_id == win4)
	check("根右子 = 2", r.right_son_id == win2)

	// 焦点往返
	cv.SetFocus(win3)
	check("3 向右邻居 = 2", cv.FocusNeighbor(win3, .Right) == win2)
	check("2 向左邻居 = 3 或 4(左子树最左)", cv.FocusNeighbor(win2, .Left) == win3)

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
