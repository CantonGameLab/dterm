// 输入模块:SDL 键盘事件 → 按键状态(设备通道)+ 输入缓冲(文本 + 控制字符)。
// 单事件泵在 event 包,分发给 Handle;BeginFrame 每帧开头清 pressed/缓冲。
package input

import s3 "vendor:sdl3"

// scancode 范围 0..511(枚举尾部 _ = 511)
SCANCODE_COUNT :: 512

MAX_BUFFER :: 256

// 设备通道:本帧按键状态
KeyState :: struct {
	pressed : [SCANCODE_COUNT]bool, // 本帧刚按下(edge,只认 repeat=false)
	held    : [SCANCODE_COUNT]bool, // 当前按住(level)
}

InputBuffer :: struct {
	data : [MAX_BUFFER]u8,
	len  : int,
}

// 设备通道状态:外部直接读字段(纯读取不提供接口)
Keys : KeyState

buffer : InputBuffer

// 启用文本输入(IME/组合 → TEXT_INPUT);须在窗口创建后调用
Init :: proc(window : ^s3.Window) -> bool {
	return s3.StartTextInput(window)
}

// 每帧开头:清 pressed(edge 只活一帧)+ 重置输入缓冲
BeginFrame :: proc() {
	for i in 0 ..< SCANCODE_COUNT {
		Keys.pressed[i] = false
	}
	buffer.len = 0
}

// 处理一个 SDL 键盘事件(event.Poll 分发)
Handle :: proc(e : ^s3.Event) {
	#partial switch e.type {
	case .KEY_DOWN:
		k := e.key
		sc := int(k.scancode)
		if !k.repeat {
			Keys.pressed[sc] = true
		}
		Keys.held[sc] = true
		seq, n := translateKey(k)
		if n > 0 {
			bufferAppend(seq[:n])
		}
	case .KEY_UP:
		Keys.held[int(e.key.scancode)] = false
	case .TEXT_INPUT:
		if e.text.text != nil {
			bufferAppend(transmute([]byte)string(e.text.text))
		}
	}
}

// 取走本帧输入缓冲(文本 + 控制字符/转义序列),供 ConPTY 发送
TakeText :: proc() -> []u8 {
	return buffer.data[:buffer.len]
}

// 清空本帧输入缓冲(如快捷键触发时丢弃其转义序列)
ClearText :: proc() {
	buffer.len = 0
}

bufferAppend :: proc(data : []byte) {
	space := len(buffer.data) - buffer.len
	n := min(space, len(data))
	copy(buffer.data[buffer.len:], data[:n])
	buffer.len += n
}
