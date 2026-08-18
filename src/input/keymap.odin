// 键位映射:物理键/组合键 → 字节序列(写 ConPTY)。
// 只处理控制字符与特殊键;可打印字符交给 TEXT_INPUT(经 IME/Shift)。
package input

import s3 "vendor:sdl3"

// 最长序列:F12 = ESC [ 24 ~ 共 6 字节
MAX_KEY_SEQ :: 8

// 返回序列与长度;n=0 表示无可打印序列(交给 TEXT_INPUT)
translateKey :: proc(k : s3.KeyboardEvent) -> (seq : [MAX_KEY_SEQ]u8, n : int) {
	// 特殊键(按 scancode,布局无关)
	#partial switch k.scancode {
	case .RETURN:
		seq[0] = '\r'
		return seq, 1
	case .BACKSPACE:
		seq[0] = 0x7F // DEL(cmd 退格)
		return seq, 1
	case .TAB:
		seq[0] = '\t'
		return seq, 1
	case .ESCAPE:
		seq[0] = 0x1B
		return seq, 1
	case .UP:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'A'
		return seq, 3
	case .DOWN:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'B'
		return seq, 3
	case .RIGHT:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'C'
		return seq, 3
	case .LEFT:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'D'
		return seq, 3
	case .HOME:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'H'
		return seq, 3
	case .END:
		seq[0], seq[1], seq[2] = 0x1B, '[', 'F'
		return seq, 3
	case .PAGEUP:
		seq[0], seq[1], seq[2], seq[3] = 0x1B, '[', '5', '~'
		return seq, 4
	case .PAGEDOWN:
		seq[0], seq[1], seq[2], seq[3] = 0x1B, '[', '6', '~'
		return seq, 4
	case .INSERT:
		seq[0], seq[1], seq[2], seq[3] = 0x1B, '[', '2', '~'
		return seq, 4
	case .DELETE:
		seq[0], seq[1], seq[2], seq[3] = 0x1B, '[', '3', '~'
		return seq, 4
	case .F1:
		seq[0], seq[1], seq[2] = 0x1B, 'O', 'P'
		return seq, 3
	case .F2:
		seq[0], seq[1], seq[2] = 0x1B, 'O', 'Q'
		return seq, 3
	case .F3:
		seq[0], seq[1], seq[2] = 0x1B, 'O', 'R'
		return seq, 3
	case .F4:
		seq[0], seq[1], seq[2] = 0x1B, 'O', 'S'
		return seq, 3
	case .F5:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '1', '5', '~'
		return seq, 5
	case .F6:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '1', '7', '~'
		return seq, 5
	case .F7:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '1', '8', '~'
		return seq, 5
	case .F8:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '1', '9', '~'
		return seq, 5
	case .F9:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '2', '0', '~'
		return seq, 5
	case .F10:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '2', '1', '~'
		return seq, 5
	case .F11:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '2', '3', '~'
		return seq, 5
	case .F12:
		seq[0], seq[1], seq[2], seq[3], seq[4] = 0x1B, '[', '2', '4', '~'
		return seq, 5
	}

	// Ctrl+字母 / Ctrl+[\]^_ → 控制字符(C-c 等;TEXT_INPUT 不含控制字符)
	if k.mod & s3.KMOD_CTRL != {} {
		key := u32(k.key)
		if key >= 0x41 && key <= 0x5F || key >= 0x61 && key <= 0x7A {
			seq[0] = u8(key & 0x1F)
			return seq, 1
		}
	}

	// Alt+字母 → ESC+字母(meta)
	if k.mod & s3.KMOD_ALT != {} {
		key := u32(k.key)
		if key >= 0x41 && key <= 0x5A || key >= 0x61 && key <= 0x7A {
			seq[0], seq[1] = 0x1B, u8(key)
			return seq, 2
		}
	}

	return seq, 0
}
