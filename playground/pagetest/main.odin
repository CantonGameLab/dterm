// 分页回归:建页/切页/页计数/焦点独立/关页(含最后一页拒绝)。
package main

import cv "../../src/canvas"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	check("count=0 init", cv.PageCount(), 0)

	p1 := cv.PageNew()
	check("page1 created", p1.id != 0, true)
	check("count=1", cv.PageCount(), 1)
	check("current=1", cv.PageCurrent(), p1)
	n1 := cv.GetWindowTreeNode(cv.PageTreeRoot(p1))
	check("page1 root size", n1 != nil && n1.width > 0 && n1.height > 0, true)

	// 焦点独立:p1 焦点 = 根窗;分裂出第二窗再换页回来应恢复
	cv.SplitNewWindow(.LeftRight)
	split_focus := cv.GetFocusWindow()
	check("focus on split", split_focus.id != 0, true)

	p2 := cv.PageNew()
	check("page2 created", p2.id != 0, true)
	check("count=2", cv.PageCount(), 2)
	check("current=2", cv.PageCurrent(), p2)
	n2 := cv.GetWindowTreeNode(cv.PageTreeRoot(p2))
	check("page2 root size", n2 != nil && n2.width > 0 && n2.height > 0, true)
	check("page2 focus = root", cv.GetFocusWindow() != cv.PageTreeRoot(p2), false) // 建根窗后焦点 = 根

	// 切回 p1:焦点恢复(分裂窗)
	cv.PageSwitch(p1)
	check("switch back p1", cv.PageCurrent(), p1)
	check("p1 focus restored", cv.GetFocusWindow(), split_focus)

	// 环绕
	cv.PageNext()
	check("next = p2", cv.PageCurrent(), p2)
	cv.PagePrev()
	check("prev = p1", cv.PageCurrent(), p1)

	// 关页:当前 p1 → 自动切相邻 p2
	ok := cv.PageDestroy(p1)
	check("destroy p1", ok, true)
	check("count=1", cv.PageCount(), 1)
	check("auto switched to p2", cv.PageCurrent(), p2)

	// 最后一页拒绝
	ok = cv.PageDestroy(p2)
	check("last page refused", ok, false)
	check("count stays 1", cv.PageCount(), 1)

	// 跨页存活:当前页窗口关完 ≠ 程序退出(其他页还有窗口)
	pa := cv.PageNew() // count=2;pa 为当前(新页自动切换)
	pb := cv.PageNew() // count=3;pb 为当前;此时活页 = {p2, pa, pb}
	check("three pages", cv.PageCount(), 3)
	cv.PageSwitch(pa)
	cv.DestroyWindow() // 关 pa 唯一窗口(当前页树清空,根常驻)
	check("pa cleared, still alive", cv.PollSessions(), true)
	cv.PageSwitch(pb)
	cv.DestroyWindow()
	check("pb cleared, still alive", cv.PollSessions(), true) // p2 还有窗
	cv.PageSwitch(p2)
	cv.DestroyWindow() // 最后一页的窗口也没了
	check("all pages empty -> exit", cv.PollSessions(), false)
}
