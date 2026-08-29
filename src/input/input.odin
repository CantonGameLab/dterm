// 输入模块:SDL 事件泵 + 键盘/鼠标事件 → 设备通道状态 + 两个输入通道:
//   - 键序列通道(key_events):translateKey 输出(控制字符/特殊键转义序列),
//     绑定层逐键裁决:命中动作不产生文本;未消费的最后进应用(文本语义)。
//   - 文本通道(text_buffer):TEXT_INPUT(可打印字符,IME/Shift 组合)。
// 入口 = Update(每帧一次:清边沿 → poll 全部事件 → 设备状态);退出通知/窗口
// 尺寸变更经 QuitRequested/TakeResize 暴露。不依赖任何业务模块。
package input

import s3 "vendor:sdl3"
import "core:mem"
import "core:strings"

// scancode 范围 0..511(枚举尾部 _ = 511)
SCANCODE_COUNT :: 512

MAX_BUFFER :: 256
MAX_KEY_EVENTS :: 64

// SDL scancode 类型透传(canvas 绑定层用,不必依赖 sdl3)
Scancode :: s3.Scancode

// 设备通道:本帧按键状态
KeyState :: struct {
	pressed : [SCANCODE_COUNT]bool, // 本帧刚按下(edge,只认 repeat=false)
	held    : [SCANCODE_COUNT]bool, // 当前按住(level)
}

// 鼠标设备通道(窗口物理像素坐标,同渲染层)
MouseState :: struct {
	x, y : f32, // 光标位置
	x_ok : bool, // 位置有效(收到过坐标事件)
	moved : bool, // 本帧位置发生变化(motion edge,供 1002/1003 移动上报)
	left, middle, right : bool, // 按住(level)
	press : u8, // 本帧刚按下:1=左 2=中 4=右(edge)
	release : u8, // 本帧刚释放:1=左 2=中 4=右(edge)
	wheel : i32, // 本帧滚轮 tick(正 = 向上滚,SDL 语义;FLIPPED 已反号)
	mods : u8, // 当前修饰(1=Shift 2=Alt 4=Ctrl 8=Win),SGR 鼠标编码用
}

// 键序列事件:绑定层逐键裁决(命中动作 → consumed;否则进应用 = 文本输入语义)
KeyEvent :: struct {
	sc : u32, // scancode(绑定表键)
	mods : u8, // 修饰(编码同 Mouse.mods)
	seq : [MAX_KEY_SEQ]u8, // 对应字节序列
	n : int,
	consumed : bool, // 绑定层动作已消费
}

InputBuffer :: struct {
	data : [MAX_BUFFER]u8,
	len  : int,
}

// 设备通道状态:外部直接读字段(纯读取不提供接口)
Keys : KeyState

// 鼠标通道(binding 层消费)
Mouse : MouseState

key_events : [MAX_KEY_EVENTS]KeyEvent
key_event_count : int

// 文本通道(仅 TEXT_INPUT)
text_buffer : InputBuffer

// 启用文本输入(IME/组合 → TEXT_INPUT);须在窗口创建后调用
Init :: proc(window : ^s3.Window) -> bool {
	return s3.StartTextInput(window)
}

// 写剪贴板(OSC 52 落点;SDL 内部拷贝,临时 NUL 结尾缓冲即可)
SetClipboardText :: proc(data : []byte) -> bool {
	if len(data) == 0 {
		return s3.SetClipboardText(cstring("")) // 清剪贴板
	}
	buf := make([]byte, len(data) + 1)
	copy(buf, data)
	defer delete(buf)
	return s3.SetClipboardText(cstring(raw_data(buf)))
}

// 每帧唯一入口:清上一帧边沿(事件泵在 event 模块,先于本模块调用)
BeginFrame :: proc() {
	for i in 0 ..< SCANCODE_COUNT {
		Keys.pressed[i] = false
	}
	Mouse.press = 0
	Mouse.release = 0
	Mouse.wheel = 0
	Mouse.moved = false
	key_events = {}
	key_event_count = 0
	text_buffer.len = 0
}

modFlags :: proc(mod : s3.Keymod) -> u8 {
	f : u8 = 0
	if mod & s3.KMOD_SHIFT != {} {
		f |= 1
	}
	if mod & s3.KMOD_ALT != {} {
		f |= 2
	}
	if mod & s3.KMOD_CTRL != {} {
		f |= 4
	}
	if mod & s3.KMOD_GUI != {} {
		f |= 8
	}
	return f
}

// 处理一个 SDL 事件(键盘 + 鼠标;event 模块分发)
Handle :: proc(e : ^s3.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		k := e.key
		sc := int(k.scancode)
		if !k.repeat {
			Keys.pressed[sc] = true
		}
		Keys.held[sc] = true
		Mouse.mods = modFlags(k.mod)
		seq, n := translateKey(k)
		// 无条件入队:绑定表裁决需要全量键(含无序列的 = / - 等);
		// n=0 的键未消费也不产生文本(可打印字符走 TEXT_INPUT 通道)
		keyEventAppend(u32(sc), Mouse.mods, seq, n)
	case .KEY_UP:
		Keys.held[int(e.key.scancode)] = false
		Mouse.mods = modFlags(e.key.mod)
	case .TEXT_INPUT:
		if e.text.text != nil {
			textAppend(transmute([]byte)string(e.text.text))
		}
	case .MOUSE_MOTION:
		Mouse.x = e.motion.x
		Mouse.y = e.motion.y
		Mouse.x_ok = true
		Mouse.moved = true
	case .MOUSE_BUTTON_DOWN:
		Mouse.x = e.button.x
		Mouse.y = e.button.y
		Mouse.x_ok = true
		switch e.button.button {
		case s3.BUTTON_LEFT:
			Mouse.left = true
			Mouse.press |= 1
		case s3.BUTTON_MIDDLE:
			Mouse.middle = true
			Mouse.press |= 2
		case s3.BUTTON_RIGHT:
			Mouse.right = true
			Mouse.press |= 4
		}
	case .MOUSE_BUTTON_UP:
		Mouse.x = e.button.x
		Mouse.y = e.button.y
		Mouse.x_ok = true
		switch e.button.button {
		case s3.BUTTON_LEFT:
			Mouse.left = false
			Mouse.release |= 1
		case s3.BUTTON_MIDDLE:
			Mouse.middle = false
			Mouse.release |= 2
		case s3.BUTTON_RIGHT:
			Mouse.right = false
			Mouse.release |= 4
		}
	case .MOUSE_WHEEL:
		w := e.wheel.integer_y
		if e.wheel.direction == .FLIPPED {
			w = -w
		}
		Mouse.wheel += w
		Mouse.x = e.wheel.mouse_x
		Mouse.y = e.wheel.mouse_y
		Mouse.x_ok = true
	}
}

// ---------------------------------------------------------------------------
// 通道读取(binding 层)
// ---------------------------------------------------------------------------

// 本帧键序列事件数
KeyEventCount :: proc() -> int {
	return key_event_count
}

// 第 i 条键事件(绑定层裁决;读取经返回指针,直接改 consumed)
KeyEventGet :: proc(i : int) -> ^KeyEvent {
	if i < 0 || i >= key_event_count {
		return nil
	}
	return &key_events[i]
}

// 集齐未消费键序列 + 文本(供应用);绑定层已消费的事件自动跳过。
// 顺序约定:键序列在前、TEXT_INPUT 在后(同帧双来源罕见)。
TakeAppInput :: proc() -> []u8 {
	n := 0
	for i in 0 ..< key_event_count {
		ev := &key_events[i]
		if !ev.consumed && n + ev.n <= MAX_BUFFER {
			copy(text_buffer.data[n:], ev.seq[:ev.n])
			n += ev.n
		}
	}
	// 文本搬到键序列之后(同数组内存重叠,用 memmove 语义的 mem.copy)
	if n > 0 && text_buffer.len > 0 {
		mem.copy(raw_data(text_buffer.data[n:]), raw_data(text_buffer.data[:]), text_buffer.len)
	}
	n += text_buffer.len
	return text_buffer.data[:n]
}

// 取走本帧文本通道(仅 TEXT_INPUT;绑定层裁决后使用)
TakeText :: proc() -> []u8 {
	return text_buffer.data[:text_buffer.len]
}

// 清空本帧输入通道(如快捷键触发时丢弃其转义序列/文本)
ClearText :: proc() {
	text_buffer.len = 0
	for i in 0 ..< key_event_count {
		key_events[i].consumed = true
	}
}

// 键名 → scancode(SDL 名称 = SDL_SCANCODE_ 后缀:"F2"/"PAGEUP"/"EQUALS"/"W";
// 大小写不敏感;未知名称返回 false)
ScancodeFromName :: proc(name : string) -> (Scancode, bool) {
	if len(name) == 0 {
		return {}, false
	}
	cs := strings.clone_to_cstring(name)
	defer delete(cs)
	p := cast([^]u8)cs
	for i in 0 ..< len(name) {
		c := p[i]
		if c >= 'a' && c <= 'z' {
			p[i] = c - 32
		}
	}
	sc := s3.GetScancodeFromName(cs)
	if sc == .UNKNOWN {
		return {}, false
	}
	return sc, true
}

// scancode → 键名(SDL 静态字符串,借用,只读)
ScancodeName :: proc(sc : Scancode) -> string {
	return string(s3.GetScancodeName(sc))
}

keyEventAppend :: proc(sc : u32, mods : u8, seq : [MAX_KEY_SEQ]u8, n : int) {
	if key_event_count >= MAX_KEY_EVENTS {
		return
	}
	ev := &key_events[key_event_count]
	ev.sc = sc
	ev.mods = mods
	ev.seq = seq
	ev.n = n
	ev.consumed = false
	key_event_count += 1
}

bufferAppend :: proc(data : []byte) {
	space := len(text_buffer.data) - text_buffer.len
	n := min(space, len(data))
	copy(text_buffer.data[text_buffer.len:], data[:n])
	text_buffer.len += n
}

textAppend :: proc(data : []byte) {
	bufferAppend(data)
}
