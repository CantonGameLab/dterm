// 悬浮控制台数据:CommandBar(可见性 + 输入缓冲 + 编辑光标 + 视图偏移)。
// 编辑操作(插入/删除/移动/取走);渲染在 render/uilayer,输入状态机在 main。
package canvas

import mem "../memory"

// 悬浮控制台:命令输入框,锚定焦点 window 右上角。
// 输入缓冲:行超宽时横向滚动(翻页),不折行;光标在缓冲内可自由移动。
MAX_CMD_INPUT :: 512

CommandBar :: struct {
	visible : bool,
	input : [MAX_CMD_INPUT]u8, // 输入缓冲
	len : int, // 已输入字节数
	cursor : int, // 光标位置(字节,0..len;插入点)
	view_offset : int, // 横向滚动视口起点(字节),跟随光标
}

command_bar : CommandBar

// 切换控制台可见性
ToggleCommandBar :: proc() {
	command_bar.visible = !command_bar.visible
	if command_bar.visible {
		command_bar.len = 0
		command_bar.cursor = 0
		command_bar.view_offset = 0
	}
}

CommandBarVisible :: proc() -> bool {
	return command_bar.visible
}

// 在光标处插入字节(0 = 光标前插入)
CommandBarInsert :: proc(data : []byte) {
	for b in data {
		if command_bar.len >= len(command_bar.input) {
			break
		}
		// 光标后字符右移
		for i := command_bar.len; i > command_bar.cursor; i -= 1 {
			command_bar.input[i] = command_bar.input[i - 1]
		}
		command_bar.input[command_bar.cursor] = b
		command_bar.cursor += 1
		command_bar.len += 1
	}
}

// 退格:删光标前一个字符
CommandBarBackspace :: proc() {
	if command_bar.cursor <= 0 {
		return
	}
	for i := command_bar.cursor - 1; i < command_bar.len - 1; i += 1 {
		command_bar.input[i] = command_bar.input[i + 1]
	}
	command_bar.cursor -= 1
	command_bar.len -= 1
}

// Delete:删光标后一个字符
CommandBarDelete :: proc() {
	if command_bar.cursor >= command_bar.len {
		return
	}
	for i := command_bar.cursor; i < command_bar.len - 1; i += 1 {
		command_bar.input[i] = command_bar.input[i + 1]
	}
	command_bar.len -= 1
}

// 光标左右移动(1 = 右,-1 = 左)
CommandBarCursorMove :: proc(dir : int) {
	command_bar.cursor = clamp(command_bar.cursor + dir, 0, command_bar.len)
}

// 光标移动到行首/行尾
CommandBarHome :: proc() {
	command_bar.cursor = 0
}

CommandBarEnd :: proc() {
	command_bar.cursor = command_bar.len
}

// 按词左右移动(跳过空白到下一个词边界)
CommandBarWordMove :: proc(dir : int) {
	is_space :: proc(b : u8) -> bool {
		return b == ' ' || b == '\t'
	}
	c := command_bar.cursor
	if dir > 0 {
		// 右移:跳过当前词和中间空白,停在下一词首
		for c < command_bar.len && is_space(command_bar.input[c]) {
			c += 1
		}
		for c < command_bar.len && !is_space(command_bar.input[c]) {
			c += 1
		}
		command_bar.cursor = c
	} else {
		// 左移:跳过前词和前空白,停在前一非空白后(或 0)
		if c > 0 {
			// 跳过光标前空白
			c -= 1
			for c > 0 && is_space(command_bar.input[c - 1]) {
				c -= 1
			}
			// 跳到词首
			for c > 0 && !is_space(command_bar.input[c - 1]) {
				c -= 1
			}
		}
		command_bar.cursor = c
	}
}

// 取走输入并清空(执行后调用)
CommandBarTake :: proc() -> string {
	s := string(command_bar.input[:command_bar.len])
	command_bar.len = 0
	command_bar.cursor = 0
	command_bar.view_offset = 0
	return s
}

// 返回输入缓冲指针(渲染层读取绘制)
GetCommandBar :: proc() -> ^CommandBar {
	return &command_bar
}

