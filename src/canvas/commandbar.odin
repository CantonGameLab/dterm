// 命令栏数据(全局单例,集成在底部页签条右侧):输入缓冲 + 光标编辑状态。
// 单一实例:一次只服务"执行动作"(命令以焦点/目标窗口执行);可见性 = 全局开关
// (F2 切换);渲染在 render/scene(条内输入框),输入状态机(esc 序列)在本模块。
package canvas

import "core:fmt"

// 编辑状态(唯一实例);渲染显示窗口按光标动态切窗口,不落存储
MAX_CMD_INPUT :: 512

CommandBar :: struct {
	input : [MAX_CMD_INPUT]u8, // 输入缓冲
	len : int, // 已输入字节数
	cursor : int, // 光标位置(字节,0..len;插入点)
}

command_bar : CommandBar
command_bar_visible : bool

// 切换命令栏(全局):开 = 清空编辑状态
ToggleCommandBar :: proc() -> bool {
	command_bar_visible = !command_bar_visible
	if command_bar_visible {
		clearBar(&command_bar)
	}
	return true
}

CommandBarVisible :: proc() -> bool {
	return command_bar_visible
}

// 命令栏编辑状态(渲染/编辑直接操作字段)
GetCommandBar :: proc() -> ^CommandBar {
	return &command_bar
}

clearBar :: proc(bar : ^CommandBar) {
	bar.len = 0
	bar.cursor = 0
}

// 在光标处插入字节(0 = 光标前插入)
CommandBarInsert :: proc(data : []byte) {
	bar := &command_bar
	for b in data {
		if bar.len >= len(bar.input) {
			break
		}
		// 光标后字符右移
		for i := bar.len; i > bar.cursor; i -= 1 {
			bar.input[i] = bar.input[i - 1]
		}
		bar.input[bar.cursor] = b
		bar.cursor += 1
		bar.len += 1
	}
}

// 退格:删光标前一个字符
CommandBarBackspace :: proc() {
	bar := &command_bar
	if bar.cursor > 0 {
		for i := bar.cursor - 1; i < bar.len - 1; i += 1 {
			bar.input[i] = bar.input[i + 1]
		}
		bar.cursor -= 1
		bar.len -= 1
	}
}

// Delete:删光标后一个字符
CommandBarDelete :: proc() {
	bar := &command_bar
	if bar.cursor < bar.len {
		for i := bar.cursor; i < bar.len - 1; i += 1 {
			bar.input[i] = bar.input[i + 1]
		}
		bar.len -= 1
	}
}

// 光标左右移动(1 = 右,-1 = 左)
CommandBarCursorMove :: proc(dir : int) {
	bar := &command_bar
	bar.cursor = clamp(bar.cursor + dir, 0, bar.len)
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
	bar := &command_bar
	is_space :: proc(b : u8) -> bool {
		return b == ' ' || b == '\t'
	}
	c := bar.cursor
	if dir > 0 {
		// 右移:跳过当前词和中间空白,停在下一词首
		for c < bar.len && is_space(bar.input[c]) {
			c += 1
		}
		for c < bar.len && !is_space(bar.input[c]) {
			c += 1
		}
		bar.cursor = c
	} else {
		// 左移:跳过前词和前空白,停在前一非空白后(或 0)
		if c > 0 {
			// 跳过光标前空白
			c -= 1
			for c > 0 && is_space(bar.input[c - 1]) {
				c -= 1
			}
			// 跳到词首
			for c > 0 && !is_space(bar.input[c - 1]) {
				c -= 1
			}
		}
		bar.cursor = c
	}
}

// 取走输入并清空(执行后调用)
CommandBarTake :: proc() -> string {
	s := string(command_bar.input[:command_bar.len])
	clearBar(&command_bar)
	return s
}

// ---------------------------------------------------------------------------
// 编辑输入状态机(bar 可见时的模态输入;原在 main,迁入使 canvas 自管)
// ---------------------------------------------------------------------------

// 转义序列解析状态:0 = 无;1 = 已见 ESC;2 = 已见 ESC [;
// 3 = ESC [ 3 ~(Delete);4 = ESC [ 1;(Ctrl 前缀);5 = ESC [ 1;5(Ctrl+键)
esc_state : int

// bar 可见时消费输入字节(逐字节,含转义序列键)
commandBarFeed :: proc(data : []byte) {
	for b in data {
		cmdBarKey(b)
	}
	// 本帧结束仍停在"已见 ESC":说明是孤立 ESC 键(无后续序列字节)→ 关闭命令栏。
	// 方向键/Ctrl 组合的 ESC 序列同帧完整到达,不会滞留。
	if esc_state == 1 {
		esc_state = 0
		ToggleCommandBar()
		CommandBarTake() // 丢弃未完成输入
	}
}

// 单字节:
//   回车          :执行命令
//   裸 ESC(ESC [ 之外的 ESC):关闭命令栏
//   ESC [ A/B/C/D :上/下/右/左(←→ 移动光标)
//   ESC [ H/F     :Home/End
//   ESC [ 1;5 D / 1;5 C:Ctrl+Left / Ctrl+Right(按词移动)
//   退格          :删光标前;Delete(ESC [ 3 ~):删光标后
//   可打印字符    :光标处插入
//   其他控制字符  :丢弃
cmdBarKey :: proc(b : u8) {
	switch esc_state {
	case 1: // 已见 ESC
		if b == '[' {
			esc_state = 2
			return
		}
		// 裸 ESC(非 CSI 序列)= 关闭命令栏
		esc_state = 0
		ToggleCommandBar()
		CommandBarTake() // 丢弃未完成输入
		return
	case 2: // 已见 ESC [ → 识别最终字节
		esc_state = 0
		switch b {
		case 'A', 'B': // 上/下:暂不支持(单行输入),忽略
			return
		case 'C': // 右
			CommandBarCursorMove(1)
			return
		case 'D': // 左
			CommandBarCursorMove(-1)
			return
		case 'H': // Home
			CommandBarHome()
			return
		case 'F': // End
			CommandBarEnd()
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
			CommandBarDelete()
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
			CommandBarWordMove(1)
		case 'D': // Ctrl+Left:按词左移
			esc_state = 0
			CommandBarWordMove(-1)
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
		CommandBarBackspace()
	case b < 0x20: // 其他控制字符丢弃
		return
	case:
		single : [1]u8 = { b }
		CommandBarInsert(single[:])
	}
}

// 取走命令栏输入并执行。
// 成功:关闭命令栏;失败:保持打开 + 回显错误,便于修正。
execCmdBar :: proc() {
	cmd := CommandBarTake()
	if len(cmd) > 0 {
		// 命令栏是专用命令框,无 ':' 前缀
		if ExecuteCommandString(cmd) {
			ToggleCommandBar()
		} else {
			// 失败:回显错误提示,命令栏保持打开
			fmt.eprintln("CMD FAILED:", cmd)
			err := "<cmd error>"
			CommandBarInsert(transmute([]u8)err)
		}
	} else {
		ToggleCommandBar()
	}
}
