// 窗口主循环:初始化(经用户接口建三窗口布局)+ 简单循环(事件 → 更新 → 渲染)+ 清理。
// 布局:
//   0(root, LeftRight)
//   ├─ 1(内部, UpDown)
//   │   ├─ 3(console:GoMono 20 → cmd.exe)
//   │   └─ 4(console:CascadiaMono 32 → msys2 bash)
//   └─ 2(console:Cascadia Regular 24 → powershell)
package main

import cv "canvas"
import ev "event"
import inp "input"
import rd "render"
import s3 "vendor:sdl3"
import mem "memory"
import "core:fmt"
import "core:strings"

// 字体文件路径
FONT_CASCADIA :: "./resource/font/CascadiaCode/CaskaydiaCoveNerdFont-Regular.ttf"
FONT_CASCADIA_MONO :: "./resource/font/CascadiaCode/CaskaydiaCoveNerdFontMono-Regular.ttf"
FONT_GO_MONO :: "./resource/font/Go-Mono/GoMonoNerdFont-Regular.ttf"

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

	if !initWindows() {
		fmt.eprintln("init windows failed")
		return
	}

	theme := rd.Theme { fg = 0xDCDCDC, bg = 0x1E1E1E, cursor = 0xFFFFFF }

	for {
		inp.BeginFrame() // 清上一帧 pressed + 重置输入缓冲
		if ev.Poll() {
			break
		}
		// 会话轮询:各窗口 console 应用退出后按 auto_close 独立处理;
		// 全部窗口销毁后程序退出。
		update() // 先消费所有窗口输出(含刚退出的)
		if !cv.PollSessions() {
			fmt.println("all sessions ended")
			break
		}
		// F2:切换悬浮控制台。触发时清空本帧输入缓冲(丢弃 F2 自身的转义序列),
		// 并跳过本帧输入,避免把功能键当文本喂进控制台。
		if inp.Keys.pressed[int(s3.Scancode.F2)] {
			cv.ToggleCommandBar()
			inp.ClearText()
			rd.BeginFrame()
			rd.DrawFrame(theme)
			rd.EndFrame()
			continue
		}
		// 本帧输入:控制台可见时进控制台,否则发给焦点 console
		if buf := inp.TakeText(); len(buf) > 0 {
			if cv.CommandBarVisible() {
				handleCmdBarInput(buf)
			} else {
				cv.FeedConsole(buf)
			}
		}
		rd.BeginFrame()
		rd.DrawFrame(theme)
		rd.EndFrame()
	}
}

// 控制台输入:逐字节过滤。
//   回车:执行命令(控制台是专用命令框,无需 ':' 前缀,执行时自动补)
//   ESC :关闭控制台
//   退格:删末尾
//   可打印字符:进缓冲
//   其他控制符/转义序列:丢弃(避免 F2/方向键等转义当文本)
handleCmdBarInput :: proc(buf : []u8) {
	for b in buf {
		switch {
		case b == '\r' || b == '\n':
			execCmdBar()
			return
		case b == 0x1B: // ESC 关闭控制台
			cv.ToggleCommandBar()
			cv.CommandBarTake() // 丢弃未完成输入
			return
		case b == 0x7F || b == '\b': // 退格
			cv.CommandBarFeed(buf[:1])
		case b < 0x20: // 其他控制字符丢弃
			continue
		case:
			cv.CommandBarFeed(buf[:1])
		}
	}
}

// 取走控制台输入并执行(自动补 ':' 前缀)
execCmdBar :: proc() {
	cmd := cv.CommandBarTake()
	if len(cmd) > 0 {
		prefix := cmd
		if prefix[0] != ':' {
			prefix = strings.concatenate({":", cmd})
			defer delete(prefix)
		}
		cv.ExecuteCommandString(prefix)
	}
	cv.ToggleCommandBar() // 执行后关闭
}

// 初始化窗口布局(经用户接口):
// 0(root, LeftRight)→ 1(UpDown)+ 2(console)
//                   1 → 3(console)+ 4(console)
initWindows :: proc() -> bool {
	// 根 0
	root := cv.CreateWindowTreeRoot()
	if root.id == 0 {
		return false
	}

	// 0 分裂 → 1(左)+ 2(右);焦点移到新窗 2
	cv.SplitNewWindow(.LeftRight)
	win2 := cv.GetFocusWindow()

	// 焦点移到 1(左子),1 再分裂 → 3(上)+ 4(下)
	if !cv.FocusMove(.Left) {
		return false
	}
	win1 := cv.GetFocusWindow()
	cv.SplitNewWindow(.UpDown)
	win4 := cv.GetFocusWindow() // 新窗 = 下子 4
	if !cv.FocusMove(.Up) {
		return false
	}
	win3 := cv.GetFocusWindow() // 上子 3

	// 三个 console 窗:2 / 3 / 4,各自不同字体、大小、cmd
	// 2:右侧窗,Cascadia 24 → powershell
	if !setupConsole(win2, FONT_CASCADIA, 24, "powershell.exe -NoExit") {
		return false
	}
	// 3:左上窗,GoMono 20 → cmd
	if !setupConsole(win3, FONT_GO_MONO, 20, "cmd.exe") {
		return false
	}
	// 4:左下窗,CascadiaMono 32 → msys2 bash
	if !setupConsole(win4, FONT_CASCADIA_MONO, 32,
		"C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start") {
		return false
	}

	// 焦点落到 3(左上),与布局顺序一致
	cv.SetFocusWindow(win3)
	return true
}

// 配置并启动一个 console 窗:设字体 → 启动 cmd
setupConsole :: proc(win : mem.Handle, font_path : string, size : f32, cmd : string) -> bool {
	if !cv.SetWindowFont(font_path, size, win) {
		fmt.eprintln("SetWindowFont failed:", font_path)
		return false
	}
	if !cv.LaunchConsole(cmd, win) {
		fmt.eprintln("LaunchConsole failed:", cmd)
		return false
	}
	return true
}

// 更新步:树遍历 + Console 布局/输出更新由 canvas 统一管理
update :: proc() {
	cv.ConsoleUpdateTree(cv.WindowTreeRoot())
}