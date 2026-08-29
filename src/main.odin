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
			break
		}
		render.Update()
	}
}

// 初始化窗口布局(经用户接口):单窗 0,默认启动配置 = msys2 bash。
initWindows :: proc() -> bool {
	// 默认启动:新建窗口自动 设 consola 26 → 启动 msys2 bash;
	// 默认配置须在 CreateWindowTreeRoot 之前设置(只对之后创建的窗口生效)
	//canvas.SetDefaultLaunch(
	//	"C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start",
	//	"FiraCode Nerd Font Mono", 26)

	canvas.SetDefaultLaunch(
		"cmd.exe",
		"FiraCode Nerd Font Mono", 26)
	// 根窗 0(自动启动默认)
	root := canvas.CreateWindowTreeRoot()
	if root.id == 0 {
		return false
	}
	canvas.SetTheme(canvas.DRACULA_THEME)
	return true
}
