// 输入绑定层:输入设备事件 → 用户功能映射集中在此文件。
// 两层职责分离:
//   - 功能体 = window.odin 的用户函数(ConsoleScroll/SetFocus 等)
//   - 本文件 = "事件 → 调用"绑定(滚轮 → 历史 review、点击 → 聚焦、
//     应用鼠标模式 → SGR 编码写回 ConPTY)
// 键盘快捷键绑定后续也集中于此;CommandBar 的编辑状态机仍在 main(独立输入模态)。
package canvas

import ct "../conpty"
import fnt "../font"
import inp "../input"
import "core:fmt"

// 每帧调用(main):消费 input 包鼠标状态。
// 命中规则:鼠标点所在 leaf = 动作目标;应用鼠标模式(?1000/1002/1003)优先接管。
ProcessMouse :: proc() {
	m := &inp.Mouse
	if !m.x_ok {
		return
	}
	node_h := nodeAtPoint(m.x, m.y)
	if node_h.id == 0 {
		return
	}
	win := NodeWindow(node_h)
	if win == nil {
		return
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return
	}
	// 应用接管:鼠标事件编码为 SGR 序列写回应用,不再做 UI 动作
	if console.vt.mouse_mode != 0 {
		mouseToApp(console)
		return
	}
	// UI 绑定:点击聚焦;滚轮滚动历史(review)
	if m.press != 0 {
		SetFocus(node_h)
	}
	if m.wheel != 0 {
		SetFocus(node_h)
		// input 层语义:wheel 正 = 向上滚(SDL);向上翻历史 = ConsoleScroll(负)
		ConsoleScroll(-int(m.wheel), node_h)
	}
}

// 键盘文本输入绑定:任一键盘输入先退出 review 回普通模式(终端惯例:
// WS 等终端在滚动查看时产生输入即回到实时),再交给焦点窗口应用。
// CommandBar 模态可见时由 main 走 CommandBar 编辑路径,不进这里。
InputText :: proc(data : []byte) {
	ConsoleExitReview()
	FeedConsole(data)
}

// 键绑定表:scancode → 动作。命中 = 纯动作(不产生文本,不触发"输入退出 review")
// —— review 中翻页快捷键只翻页;未命中的键序列 + TEXT_INPUT 文本走 InputText
// (文本语义:退出 review + 送达应用)。
ProcessKeys :: proc() {
	focus_console := focusConsole()
	rows := 0
	if focus_console != nil {
		rows = int(focus_console.rows)
	}
	n := inp.KeyEventCount()
	for i in 0 ..< n {
		ev := inp.KeyEventGet(i)
		if ev == nil {
			continue
		}
		bound := false
		#partial switch inp.Scancode(ev.sc) {
		case .PAGEUP:
			ConsoleScroll(-rows) // 上翻一屏(进入 review)
			bound = true
		case .PAGEDOWN:
			ConsoleScroll(rows) // 下翻一屏(滚到底自动回普通)
			bound = true
		case .F2:
			ToggleCommandBar() // 悬浮控制台切换(user API;序列不进应用)
			bound = true
		}
		if bound {
			ev.consumed = true // 动作已执行,序列不再进应用
		}
	}
	// 输入路由由 main 决定:bar 可见 → CommandBar 编辑状态机;否则 TakeAppInput → InputText
}

// 焦点窗口的 console(绑定动作的目标)
focusConsole :: proc() -> ^Console {
	f := GetFocus()
	if f.id == 0 {
		return nil
	}
	win := NodeWindow(f)
	if win == nil {
		return nil
	}
	return GetConsole(win.console_id)
}

// ---------------------------------------------------------------------------
// 应用鼠标模式:SGR(xterm 1006)编码
// ---------------------------------------------------------------------------

// 鼠标屏幕位置 → 网格坐标(1-based,越界 clamp 到格子边缘,终端惯例)
mouseCell :: proc(console : ^Console, x, y : f32) -> (col, row : int, ok : bool) {
	m := fnt.GetMetrics(console.font_id)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return 0, 0, false
	}
	col = clamp(int((x - console.origin_x) / m.cell_width) + 1, 1, int(console.cols))
	row = clamp(int((y - console.origin_y) / m.cell_height) + 1, 1, int(console.rows))
	return col, row, true
}

// SGR 修饰位:Shift+4 Alt+8 Ctrl+16(input 的 bit 表示转 xterm 位)
sgrMods :: proc(mods : u8) -> u8 {
	r : u8 = 0
	if mods & 1 != 0 {
		r |= 4
	}
	if mods & 2 != 0 {
		r |= 8
	}
	if mods & 4 != 0 {
		r |= 16
	}
	return r
}

// 发送一个 SGR 鼠标序列:CSI < cb ; col ; row M(按下/滚轮/移动)/ m(释放)
sendSGR :: proc(console : ^Console, cb : u8, col, row : int, release : bool) {
	final := u8('M')
	if release {
		final = 'm'
	}
	msg := fmt.tprintf("\x1b[<%d;%d;%d%c", cb, col, row, final)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// 编码并上报本帧鼠标事件(协议 = SGR 1006;未启用时忽略,旧 X10 编码暂不支持)
mouseToApp :: proc(console : ^Console) {
	if !console.vt.sgr_mouse {
		return
	}
	m := &inp.Mouse
	col, row, ok := mouseCell(console, m.x, m.y)
	if !ok {
		return
	}
	mods := sgrMods(m.mods)

	// 按钮:0=左 1=中 2=右;按下 M,释放 m
	btn_by_bit := [?]u8{0, 1, 2} // bit1/2/4 → 按钮号
	for i in 0 ..< 3 {
		bit := u8(1 << u32(i))
		if m.press & bit != 0 {
			sendSGR(console, btn_by_bit[i] + mods, col, row, false)
		}
		if m.release & bit != 0 {
			sendSGR(console, btn_by_bit[i] + mods, col, row, true)
		}
	}

	// 滚轮:64=上 65=下,每 tick 一档
	if m.wheel != 0 {
		n := m.wheel < 0 ? -m.wheel : m.wheel
		cb := u8(64)
		if m.wheel < 0 {
			cb = 65
		}
		for k in 0 ..< n {
			sendSGR(console, cb + mods, col, row, false)
		}
	}

	// 移动:1002 = 按住时拖动(32+btn);1003 = 任意移动(无键 35)
	if m.moved {
		btn : u8 = 3 // 无键
		if m.right {
			btn = 2
		} else if m.middle {
			btn = 1
		} else if m.left {
			btn = 0
		}
		report := console.vt.mouse_mode == 3 || (console.vt.mouse_mode == 2 && btn != 3)
		if report {
			sendSGR(console, 32 + btn + mods, col, row, false)
		}
	}
}
