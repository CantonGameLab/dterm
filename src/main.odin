// 窗口主循环(纯编排壳):初始化 → 按 DAG 顺序调用各模块入口 → 清理。
// 数据流:event/input → canvas → render,单向;main 不持业务状态。
// 布局:
//   0(root, LeftRight)
//   ├─ 1(内部, UpDown)
//   │   ├─ 3(console:CascadiaCode 18 → cmd.exe)
//   │   └─ 4(console:msyh 26 → msys2 bash)
//   └─ 2(console:CascadiaMono 22 → powershell)
package main

import "canvas"
import "event"
import "input"
import "render"
import "memory"
import "core:fmt"

main :: proc() {
	if !render.Init() {
		fmt.eprintln("render init failed")
		return
	}
	defer render.Quit()
	if !input.Init(render.GetWindow()) {
		fmt.eprintln("input init failed")
		return
	}

	if !initWindows() {
		fmt.eprintln("init windows failed")
		return
	}

	theme := render.Theme { fg = 0xDCDCDC, bg = 0x1E1E1E, cursor = 0xFFFFFF }

	for {
		input.BeginFrame() // 清上一帧边沿(事件泵先于本模块调用)
		event.Update() // 事件泵 → 分发(源模块:尺寸→canvas,键鼠→input)
		if event.QuitRequested() {
			break
		}
		if !canvas.Update() { // 布局/输出/输入路由/会话,自管数据
			fmt.println("all windows closed")
			break
		}
		render.Update(theme)
	}
}

// 初始化窗口布局(经用户接口):
// 0(root, LeftRight)→ 1(UpDown)+ 2(console)
//                   1 → 3(console)+ 4(console)
initWindows :: proc() -> bool {
	// 根 0
	root := canvas.CreateWindowTreeRoot()
	if root.id == 0 {
		return false
	}

	// 0 分裂 → 1(左)+ 2(右);焦点移到新窗 2
	canvas.SplitNewWindow(.LeftRight)
	win2 := canvas.GetFocusWindow()

	// 焦点移到 1(左子),1 再分裂 → 3(上)+ 4(下)
	if !canvas.FocusMove(.Left) {
		return false
	}
	win1 := canvas.GetFocusWindow()
	canvas.SplitNewWindow(.UpDown)
	win4 := canvas.GetFocusWindow() // 新窗 = 下子 4
	if !canvas.FocusMove(.Up) {
		return false
	}
	win3 := canvas.GetFocusWindow() // 上子 3

	// 三个 console 窗:2 / 3 / 4,各自不同字体、大小、cmd
	// 字体名走系统目录(LoadFont 先按名找 .ttf/.otf/.ttc,找不到再当路径)
	// 2:右侧窗,CascadiaMono 22 → powershell
	if !setupConsole(win2, "CascadiaMono", 22, "powershell.exe -NoExit") {
		return false
	}
	// 3:左上窗,CascadiaCode 18 → cmd
	if !setupConsole(win3, "CascadiaCode", 18, "cmd.exe") {
		return false
	}

	// 只清会话、保留窗口与字体(窗口用于手动 launch 测试):
	// 注意:DestroyConsole 参数是 console 句柄,不能直接传窗口句柄(槽 id 会撞车)
	canvas.ClearWindowConsole(win2)
	canvas.ClearWindowConsole(win3)

	// 4:左下窗,msyh 26(.ttc)→ msys2 bash
	if !setupConsole(win4, "consola", 26,
		"C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start") {
		return false
	}

	// 焦点落到 3(左上),与布局顺序一致
	canvas.SetFocusWindow(win3)
	return true
}

// 配置并启动一个 console 窗:设字体 → 启动 cmd
setupConsole :: proc(win : memory.Handle, font_path : string, size : f32, cmd : string) -> bool {
	if !canvas.SetWindowFont(font_path, size, win) {
		fmt.eprintln("SetWindowFont failed:", font_path)
		return false
	}
	if !canvas.LaunchConsole(cmd, win) {
		fmt.eprintln("LaunchConsole failed:", cmd)
		return false
	}
	return true
}
