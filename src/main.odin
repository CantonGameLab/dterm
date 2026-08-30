// 窗口主循环(纯编排壳):初始化 → 按 DAG 顺序调用各模块入口 → 清理。
// 数据流:event/input → canvas → render,单向;main 不持业务状态。
// 布局:单窗口 0(root),默认 = msys2 bash。
package main

import "canvas"
import "event"
import "input"
import "render"
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

	// 主题:Dracula(换主题只改这一行;默认 = canvas.DEFAULT_THEME)

	for {
		input.BeginFrame() // 清上一帧边沿(事件泵先于本模块调用)
		event.Update() // 事件泵 → 分发(源模块:尺寸→canvas,键鼠→input)
		if event.QuitRequested() {
			break
		}
		if !canvas.Update() { // 布局/输出/输入路由/会话,自管数据
			fmt.println("all windows closed")
			fmt.println("Thank you for using our terminal emulator sailor!")
			break
		}
		render.Update()
	}
}

// 初始化窗口布局(经用户接口):键位绑定 + 单窗 0,默认启动配置。
initWindows :: proc() -> bool {
	// 键位绑定表(显式填充一次;查询纯读)
	canvas.ClearKeyBindings()

	// 焦点
	canvas.SetKeyBinding(.H, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Left })
	canvas.SetKeyBinding(.L, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Right })
	canvas.SetKeyBinding(.K, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Up })
	canvas.SetKeyBinding(.J, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Down })

	// 分屏
	canvas.SetKeyBinding(.L, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .LeftRight })
	canvas.SetKeyBinding(.J, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .UpDown })

	// 交换(几何方向邻居)
	canvas.SetKeyBinding(.H, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Left })
	canvas.SetKeyBinding(.L, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Right })
	canvas.SetKeyBinding(.K, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Up })
	canvas.SetKeyBinding(.J, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Down })

	// 销毁焦点窗口
	canvas.SetKeyBinding(.W, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Destroy })

	// 历史翻页
	canvas.SetKeyBinding(.PAGEUP, {.Shift}, canvas.ParsedCommand { kind = .ReviewUp })
	canvas.SetKeyBinding(.PAGEDOWN, {.Shift}, canvas.ParsedCommand { kind = .ReviewDown })

	// 命令栏
	canvas.SetKeyBinding(.F2, {}, canvas.ParsedCommand { kind = .ToggleCommandBar })

	// 字号
	canvas.SetKeyBinding(.EQUALS, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .FontSizeUp })
	canvas.SetKeyBinding(.MINUS, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .FontSizeDown })


	// 默认启动:新建窗口自动 设 FiraCode 26 → 启动 cmd;
	// 默认配置须在 CreateWindowTreeRoot 之前设置(只对之后创建的窗口生效)
	
	canvas.SetDefaultLaunch(
		"cmd.exe",
		"FiraCode Nerd Font Mono", 26)
	// 根窗 0(自动启动默认)
	root := canvas.CreateWindowTreeRoot()
	if root.id == 0 {
		return false
	}
	canvas.SetTheme(canvas.DRACULA_THEME)
	render.SetBackgroundShaderEnabled(true)
	render.ResetBackgroundShader()
	render.SetVSync(true)
	return true
}
