// 树栈复现:initWindows 三窗布局 → 按用户操作 destroy×2 → ToggleCommandBar,
// 打印每步的树根/焦点/CommandBar 状态,定位 F2 失效环节。
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

// 简化:节点 id 打印(树结构/焦点)
dump :: proc(tag : string) {
	fmt.printf("%-24s root=%d focus=%d barVisible=%v\n", tag,
		cv.WindowTreeRoot().id, cv.GetFocusWindow().id, cv.CommandBarVisible())
}

main :: proc() {
	cv.CreateWindowTreeRoot()
	cv.SplitNewWindow(.LeftRight)
	win2 := cv.GetFocusWindow()
	cv.FocusMove(.Left)
	win1 := cv.GetFocusWindow()
	cv.SplitNewWindow(.UpDown)
	win4 := cv.GetFocusWindow()
	cv.FocusMove(.Up)
	win3 := cv.GetFocusWindow()
	cv.SetFocusWindow(win3)

	// 模拟 setupConsole(SetWindowFont 建窗):给三个窗都挂窗口
	wns := [3]mem.Handle{win2, win3, win4}
	for n in wns {
		nnode := cv.GetWindowTreeNode(n)
		if nnode != nil && nnode.window_id.id == 0 {
			cv.TreeNodeSetWindow(n, cv.CreateWindow())
		}
	}
	fmt.printf("init: root=%d win1=%d win2=%d win3=%d win4=%d\n",
		cv.WindowTreeRoot().id, win1.id, win2.id, win3.id, win4.id)
	dump("init done")

	// 用户:焦点窗 3 上 F2 开条 + destroy
	cv.ToggleCommandBar() // F2
	fmt.printf("toggle@3: barVisible=%v\n", cv.CommandBarVisible())
	cv.DestroyWindow() // destroy(焦点窗)
	dump("after destroy#1")

	// 用户:新焦点(第二个窗)destroy
	cv.DestroyWindow()
	dump("after destroy#2")

	// 用户:剩余窗按 F2
	f := cv.GetFocusWindow()
	cv.ToggleCommandBar()
	w := cv.NodeWindow(f)
	iterms := -1
	if w != nil {
		iterms = len(w.iterms)
	}
	fmt.printf("post-toggle focus=%d win=%v iterms=%d barVisible=%v\n", f.id, w != nil, iterms, cv.CommandBarVisible())
	dump("final")

	// 再按一次 F2:关闭
	cv.ToggleCommandBar()
	fmt.printf("toggle-off: barVisible=%v\n", cv.CommandBarVisible())
}
