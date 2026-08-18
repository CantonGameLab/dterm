// 窗口主循环:初始化 + 简单循环(事件 → 更新 → 渲染)+ 清理。
package main

import ct "conpty"
import cv "canvas"
import ev "event"
import inp "input"
import fnt "font"
import rd "render"
import mem "memory"
import "core:fmt"

main :: proc() {
	if !rd.Init() {
		fmt.eprintln("render init failed")
		return
	}
	defer rd.Quit()
	if !inp.Init(rd.GetWindow()) {
		fmt.eprintln("input init failed")
		return
	}

	cv.InitWindowTree()
	w, h := rd.GetWindowSize()
	cv.WindowTreeSetRootSize(w, h)

	font_h, font_ok := fnt.LoadFont("resource/font/Go-Mono/GoMonoNerdFontMono-Regular.ttf", 50)
	if !font_ok {
		fmt.eprintln("LoadFont failed")
		return
	}
	defer fnt.DestroyFont(font_h)

	conpty_h, conpty_ok := ct.CreateConptyContext({80, 24}, "cmd.exe")
	if !conpty_ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(conpty_h) // 兜底释放(读线程未启动时)

	console_h, console_ok := cv.CreateConsole(24, 80, conpty_h)
	if !console_ok {
		fmt.eprintln("CreateConsole failed")
		return
	}
	defer cv.DestroyConsole(console_h)
	cv.GetConsole(console_h).font_id = font_h

	if !ct.StartReadThread(conpty_h) {
		fmt.eprintln("StartReadThread failed")
		return
	}
	defer ct.StopReadThread(conpty_h)

	root_h := cv.WindowTreeRoot()
	iterm_index, _ := cv.TreeNodeAddIterm(root_h, cv.ItermType.Console, console_h)
	it := cv.ItermGet(root_h, iterm_index)
	it.scale_width = 1 // 填满节点
	it.scale_height = 1

	theme := rd.Theme { fg = 0xDCDCDC, bg = 0x1E1E1E, cursor = 0xFFFFFF }

	for {
		inp.BeginFrame() // 清上一帧 pressed + 重置输入缓冲
		if ev.Poll() {
			break
		}
		// 本帧输入(文本 + 控制字符/转义序列)发给 ConPTY
		if buf := inp.TakeText(); len(buf) > 0 {
			ct.WriteConptyInput(conpty_h, buf)
		}
		update()
		rd.BeginFrame()
		rd.DrawFrame(theme)
		rd.EndFrame()
	}
}

// 更新步:遍历树,对每个 Console 更新布局 + 拉取 ConPTY 输出
update :: proc() {
	updateWalk(cv.WindowTreeRoot())
}

updateWalk :: proc(node_h : mem.Handle) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		updateWalk(node.left_son_id)
		updateWalk(node.right_son_id)
		return
	}
	for i in 0 ..< len(node.iterms) {
		if node.iterms[i].type != cv.ItermType.Console {
			continue
		}
		console_h := node.iterms[i].console_id
		console := cv.GetConsole(console_h)
		if console == nil {
			continue
		}
		t := cv.ItermAbsoluteTransform(node_h, i)
		m := fnt.GetMetrics(console.font_id)
		old_rows, old_cols := console.rows, console.cols
		cv.ConsoleUpdateLayout(console_h, t, m.cell_width, m.cell_height)
		if console.rows != old_rows || console.cols != old_cols {
			ct.Resize(console.conpty_handle, console.cols, console.rows)
		}
		cv.UpdateConsole(console_h)
	}
}
