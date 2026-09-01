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

// 初始化窗口布局(配置函数:userapi 是给用户/配置段落的接口,此处直接使用;
// 运行期内部代码不绕用户接口,一律经 Get* 指针直接操作数据)。
initWindows :: proc() -> bool {
	// 键位绑定表(显式填充一次;查询纯读)
	canvas.ClearKeyBindings()

	// 焦点
	canvas.SetKeyBinding(.H, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Left })
	canvas.SetKeyBinding(.L, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Right })
	canvas.SetKeyBinding(.K, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Up })
	canvas.SetKeyBinding(.J, {.Alt}, canvas.ParsedCommand { kind = .FocusDir, fdir = .Down })

	// 分屏(四方向,与焦点键位同构):新窗在左/下/上/右
	canvas.SetKeyBinding(.H, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .LeftRight, split_first = true })
	canvas.SetKeyBinding(.J, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .UpDown })
	canvas.SetKeyBinding(.K, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .UpDown, split_first = true })
	canvas.SetKeyBinding(.L, {.Alt, .Shift}, canvas.ParsedCommand { kind = .Split, dir = .LeftRight })

	// 交换(几何方向邻居)
	canvas.SetKeyBinding(.H, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Left })
	canvas.SetKeyBinding(.L, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Right })
	canvas.SetKeyBinding(.K, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Up })
	canvas.SetKeyBinding(.J, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Exchange, fdir = .Down })

	// 销毁焦点窗口
	canvas.SetKeyBinding(.W, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .Destroy })

	// 新建页签(WT 惯例;关页 = 关光当前页窗口自动清出)
	canvas.SetKeyBinding(.T, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .PageNew })

	// 历史翻页
	canvas.SetKeyBinding(.PAGEUP, {.Shift}, canvas.ParsedCommand { kind = .ReviewUp })
	canvas.SetKeyBinding(.PAGEDOWN, {.Shift}, canvas.ParsedCommand { kind = .ReviewDown })

	// 命令栏
	canvas.SetKeyBinding(.F2, {}, canvas.ParsedCommand { kind = .ToggleCommandBar })

	// 字号
	canvas.SetKeyBinding(.EQUALS, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .FontSizeUp })
	canvas.SetKeyBinding(.MINUS, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .FontSizeDown })

	// 页签切换
	canvas.SetKeyBinding(.TAB, {.Ctrl}, canvas.ParsedCommand { kind = .PageNext })
	canvas.SetKeyBinding(.TAB, {.Ctrl, .Shift}, canvas.ParsedCommand { kind = .PagePrev })


	// 默认启动:新建窗口自动 设 FiraCode 26 → 启动 bash;
	// 默认配置须在 PageNew 之前设置(只对之后创建的窗口生效)
	
	// 调试会话:cmd.exe(msys2 bash 在受限宿主下 CreateFileMapping 失败;
	// 在你自己的终端会话里按环境换回 msys2_shell.cmd)
	canvas.SetDefaultLaunch(
		"bash.exe",
		"FiraCode Nerd Font Mono", 26)
	// 第一页:页根 + 根窗(自动启动默认),成为当前页
	page := canvas.PageNew()
	if page.id == 0 {
		return false
	}

	canvas.SetTheme(canvas.GRUVBOX_DARK_THEME)

	render.SetBackgroundShaderEnabled(true)
	render.ResetBackgroundShader()
	render.SetVSync(true)
	return true
}
