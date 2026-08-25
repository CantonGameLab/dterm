// 窗口主循环:初始化(经用户接口建三窗口布局)+ 简单循环(事件 → 更新 → 渲染)+ 清理。
// 布局:
//   0(root, LeftRight)
//   ├─ 1(内部, UpDown)
//   │   ├─ 3(console:CascadiaCode 18 → cmd.exe)
//   │   └─ 4(console:msyh 26 → msys2 bash)
//   └─ 2(console:CascadiaMono 22 → powershell)
package main

import cv "canvas"
import ev "event"
import inp "input"
import rd "render"
import s3 "vendor:sdl3"
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

		cv.ConsoleUpdateTree(cv.WindowTreeRoot())

		cv.ProcessMouse() // 鼠标绑定:滚轮 review / 点击聚焦 / 应用鼠标模式(SGR)
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
		// 本帧输入:控制台可见时进控制台,否则走绑定层
		// (绑定层:快捷键动作优先;未消费序列+文本 = 文本输入,先退出 review 再送应用)
		if cv.CommandBarVisible() {
			if buf := inp.TakeAppInput(); len(buf) > 0 {
				handleCmdBarInput(buf)
			}
		} else {
			cv.ProcessKeys()
		}
		rd.BeginFrame()
		rd.DrawFrame(theme)
		rd.EndFrame()
	}
}

// 控制台输入:逐字节解析(含转义序列键)。
//   回车          :执行命令
//   裸 ESC(ESC [ 之外的 ESC):关闭控制台
//   ESC [ A/B/C/D :上/下/右/左(←→ 移动光标)
//   ESC [ H/F     :Home/End
//   ESC [ 1;5 D / 1;5 C:Ctrl+Left / Ctrl+Right(按词移动)
//   退格          :删光标前;Delete(ESC [ 3 ~):删光标后
//   可打印字符    :光标处插入
//   其他控制字符  :丢弃
handleCmdBarInput :: proc(buf : []u8) {
	for b in buf {
		cmdBarKey(b)
	}
	// 本帧结束仍停在"已见 ESC":说明是孤立 ESC 键(无后续序列字节)→ 关闭控制台。
	// 方向键/Ctrl 组合的 ESC 序列同帧完整到达,不会滞留。
	if esc_state == 1 {
		esc_state = 0
		cv.ToggleCommandBar()
		cv.CommandBarTake() // 丢弃未完成输入
	}
}

// 转义序列解析状态:0 = 无;1 = 已见 ESC;2 = 已见 ESC [;
// 3 = ESC [ 3 ~(Delete);4 = ESC [ 1;(Ctrl 前缀);5 = ESC [ 1;5(Ctrl+键)
esc_state : int

cmdBarKey :: proc(b : u8) {
	switch esc_state {
	case 1: // 已见 ESC
		if b == '[' {
			esc_state = 2
			return
		}
		// 裸 ESC(非 CSI 序列)= 关闭控制台
		esc_state = 0
		cv.ToggleCommandBar()
		cv.CommandBarTake() // 丢弃未完成输入
		return
	case 2: // 已见 ESC [ → 识别最终字节
		esc_state = 0
		switch b {
		case 'A', 'B': // 上/下:暂不支持(单行输入),忽略
			return
		case 'C': // 右
			cv.CommandBarCursorMove(1)
			return
		case 'D': // 左
			cv.CommandBarCursorMove(-1)
			return
		case 'H': // Home
			cv.CommandBarHome()
			return
		case 'F': // End
			cv.CommandBarEnd()
			return
		case '3': // Delete(ESC [ 3 ~):置状态等 '~'
			esc_state = 3
			return
		case '1': // ESC [ 1(可能接 ';5 C/D' 的 Ctrl 组合)
			esc_state = 4
			return
		case:
			return
		}
	case 3: // ESC [ 3 ~ 的 '~'
		esc_state = 0
		if b == '~' {
			cv.CommandBarDelete()
		}
		return
	case 4: // ESC [ 1;... 的 ';'(修饰键前缀)
		if b == ';' {
			esc_state = 5
			return
		}
		esc_state = 0
		return
	case 5: // ESC [ 1;5 X:Ctrl+修饰键(数字修饰位可多个,如 5=Ctrl)
		switch b {
		case 'C': // Ctrl+Right:按词右移
			esc_state = 0
			cv.CommandBarWordMove(1)
		case 'D': // Ctrl+Left:按词左移
			esc_state = 0
			cv.CommandBarWordMove(-1)
		case '0'..='9':
			// 修饰位数字(如 5,Ctrl):留在状态 5 等 C/D
			return
		case:
			esc_state = 0
		}
		return
	}

	// 正常输入
	switch {
	case b == '\r' || b == '\n':
		execCmdBar()
	case b == 0x1B: // 转义序列起始
		esc_state = 1
	case b == 0x7F || b == '\b': // 退格
		cv.CommandBarBackspace()
	case b < 0x20: // 其他控制字符丢弃
		return
	case:
		single : [1]u8 = { b }
		cv.CommandBarInsert(single[:])
	}
}

// 取走控制台输入并执行。
// 成功:关闭控制台;失败:保持打开 + 回显错误,便于修正
execCmdBar :: proc() {
	cmd := cv.CommandBarTake()
	if len(cmd) > 0 {
		// 控制台是专用命令框,无 ':' 前缀
		if cv.ExecuteCommandString(cmd) {
			cv.ToggleCommandBar() // 成功:关闭
		} else {
			// 失败:回显错误提示,控制台保持打开
			fmt.eprintln("CMD FAILED:", cmd)
			err := "<cmd error>"
			cv.CommandBarInsert(transmute([]u8)err)
		}
	} else {
		cv.ToggleCommandBar()
	}
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
	cv.ClearWindowConsole(win2)
	cv.ClearWindowConsole(win3)

	// 4:左下窗,msyh 26(.ttc)→ msys2 bash
	if !setupConsole(win4, "consola", 26,
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
}
