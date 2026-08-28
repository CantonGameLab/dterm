// 输入绑定层:输入设备事件 → 数据化命令。
// 单向管线:事件(input 通道)→ [mods+key] 查绑定表 → ParsedCommand(数据化 userapi
// 封装)→ ExecuteCommand(唯一解释器);命中 = 纯动作(序列不进应用)。
// 鼠标:滚轮 → review、点击 → 聚焦、应用鼠标模式(1000/1002/1003)→ SGR 编码写回。
package canvas

import ct "../conpty"
import fnt "../font"
import inp "../input"
import "core:fmt"

// ---------------------------------------------------------------------------
// 快捷键绑定表(数据化):组合键(mods+key)→ 数据化命令
// ---------------------------------------------------------------------------

// 组合修饰:Alt/Ctrl/Shift 自由组合;规则 = Shift 不得单独出现(须与 Alt/Ctrl 伴生)
KeyMod :: enum u8 {
	Alt,
	Ctrl,
	Shift,
	Win, // 事件侧保留(绑定表不用;事件含 Win 时与绑定不匹配)
}

KeyMods :: bit_set[KeyMod; u8]

// input 修饰字节(1=Shift 2=Alt 4=Ctrl 8=Win)→ KeyMods
modsFromByte :: proc(m : u8) -> KeyMods {
	s : KeyMods
	if m & 1 != 0 {
		s += {.Shift}
	}
	if m & 2 != 0 {
		s += {.Alt}
	}
	if m & 4 != 0 {
		s += {.Ctrl}
	}
	if m & 8 != 0 {
		s += {.Win}
	}
	return s
}

// 一条绑定:触发 = mods+key;动作 = 数据化命令(与字符串指令共用 ParsedCommand)
Binding :: struct {
	key : inp.Scancode,
	mods : KeyMods,
	cmd : ParsedCommand,
}

// 默认绑定表(数据;增改快捷键只动这里)
default_bindings := [5]Binding{
	{ key = .PAGEUP, mods = {}, cmd = { kind = .ReviewUp } },
	{ key = .PAGEDOWN, mods = {}, cmd = { kind = .ReviewDown } },
	{ key = .F2, mods = {}, cmd = { kind = .ToggleCommandBar } },
	{ key = .EQUALS, mods = {.Ctrl, .Shift}, cmd = { kind = .FontSizeUp } },
	{ key = .MINUS, mods = {.Ctrl, .Shift}, cmd = { kind = .FontSizeDown } },
}

// Shift 单独出现 = 非法绑定(规则校验,仅检查一次)
bindings_checked : bool

validateBindings :: proc() {
	if bindings_checked {
		return
	}
	bindings_checked = true
	for b in default_bindings {
		if b.mods == {.Shift} {
			fmt.eprintln("binding invalid: Shift alone not allowed")
		}
	}
}

// 查绑定:精确匹配 (key, mods);命中返回命令
findBinding :: proc(sc : u32, mods : KeyMods) -> (Binding, bool) {
	if mods == {.Shift} {
		return {}, false // Shift 单独 = 非法触发(不参与匹配)
	}
	for b in default_bindings {
		if u32(b.key) == sc && b.mods == mods {
			return b, true
		}
	}
	return {}, false
}

// 每帧调用(事件已入 input 通道):绑定表 → ExecuteCommand(数据化动作)
ProcessKeys :: proc() {
	validateBindings()
	n := inp.KeyEventCount()
	for i in 0 ..< n {
		ev := inp.KeyEventGet(i)
		if ev == nil {
			continue
		}
		if b, ok := findBinding(ev.sc, modsFromByte(ev.mods)); ok {
			ExecuteCommand(b.cmd)
			ev.consumed = true // 动作已执行,序列不再进应用
		}
	}
	// 输入路由由 main 决定:bar 可见 → CommandBar 编辑状态机;否则 TakeAppInput → InputText
}

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
