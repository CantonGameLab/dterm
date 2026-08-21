// 窗口主循环:初始化 + 简单循环(事件 → 更新 → 渲染)+ 清理。
package main

import ct "conpty"
import cv "canvas"
import ev "event"
import inp "input"
import fnt "font"
import rd "render"
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

	font_h, font_ok := fnt.LoadFont("./resource/font/CascadiaCode/CaskaydiaCoveNerdFont-Regular.ttf", 40)
	if !font_ok {
		fmt.eprintln("LoadFont failed")
		return
	}
	defer fnt.DestroyFont(font_h)
	conpty_h, conpty_ok := ct.CreateConptyContext({80, 24}, "C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start")
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
		// 会话结束检测:Job 内进程树归零(exit 后所有进程退出)或读管道断开。
		// 注意:ConPTY 读管道在子进程退出后不会自动 EOF(conhost 持有写端),
		// 读线程断开只作兜底;主信号是 Job 计数(msys2_shell.cmd -no-start
		// 同步运行 bash,bash 退出后 cmd 包装才退出,Job 归零即会话结束)。
		jobs := ct.JobActiveProcesses(conpty_h)
		if jobs == 0 || !ct.IsReadThreadAlive(conpty_h) {
			update() // 消费环形缓冲中最后的输出(exit 前的内容)
			fmt.println("conpty session ended")
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

// 更新步:树遍历 + Console 布局/输出更新由 canvas 统一管理
update :: proc() {
	cv.ConsoleUpdateTree(cv.WindowTreeRoot())
}
