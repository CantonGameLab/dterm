package canvas

import ct "../conpty"
import "core:fmt"

// VT 解析器:字节流 → 状态机 → 操作 Console。
// 每帧 UpdateConsole(id) 拉取 ConPTY 输出并喂给解析器;VtState 嵌在 Console.vt。

VtStateKind :: enum u8 {
	Normal,
	Esc,
	Csi,
	Osc,
	OscEsc,
}

VtState :: struct {
	state : VtStateKind,
	params : [16]int,
	param_count : int,
	private : bool, // CSI '?' 前缀

	utf8_pending : [4]u8, // 未收完的 UTF-8 分片
	utf8_pending_len : int,

	style : CellStyle,
	saved_cursor_row, saved_cursor_col : u16,
	scroll_top, scroll_bottom : u16,
	autowrap : bool,
	cursor_visible : bool,
	alt_term_buffer_id : u32, // 0 = 未创建
}

update_scratch : [64 * 1024]byte // 主循环单线程,包级复用

UpdateConsole :: proc(id : u32) {
	console := GetConsole(id)
	if console == nil {
		return
	}
	data := ct.GetReadWriteData(id)
	if data == nil {
		return
	}
	n := ct.RingPop(data, update_scratch[:])
	if n <= 0 {
		return
	}
	vtFeed(id, update_scratch[:n])
}

vtFeed :: proc(console_id : u32, data : []byte) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	vt := &console.vt
	for b in data {
		switch vt.state {
		case .Normal:
			if vt.utf8_pending_len > 0 { // 收完分片再打印
				vt.utf8_pending[vt.utf8_pending_len] = b
				vt.utf8_pending_len += 1
				if vt.utf8_pending_len >= vtUtf8Len(vt.utf8_pending[0]) {
					vtPrint(console_id, vtDecodeRune(vt.utf8_pending[:]))
					vt.utf8_pending_len = 0
				}
				continue
			}
			switch {
			case b == 0x1B:
				vt.state = .Esc
			case b < 0x20 || b == 0x7F:
				vtHandleC0(console_id, b)
			case b < 0x80:
				vtPrint(console_id, rune(b))
			case b >= 0xC0:
				vt.utf8_pending[0] = b
				vt.utf8_pending_len = 1
			case: // 游离续字节,丢弃
			}

		case .Esc:
			switch b {
			case '[':
				vt.state = .Csi
				vt.param_count = 1
				vt.params[0] = 0
				vt.private = false
			case ']':
				vt.state = .Osc
			case '7': // DECSC
				vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
				vt.state = .Normal
			case '8': // DECRC
				console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
				vt.state = .Normal
			case 'P', 'X', '^', '_': // DCS/APC/PM,忽略到 ST
				vt.state = .Osc
			case:
				vt.state = .Normal
			}

		case .Csi:
			switch {
			case b == '?':
				vt.private = true
			case b >= '0' && b <= '9':
				if vt.param_count == 0 {
					vt.param_count = 1
					vt.params[0] = 0
				}
				vt.params[vt.param_count - 1] = vt.params[vt.param_count - 1] * 10 + int(b - '0')
			case b == ';' || b == ':':
				vt.param_count += 1
				if vt.param_count < len(vt.params) {
					vt.params[vt.param_count - 1] = 0
				}
			case b >= 0x40 && b <= 0x7E:
				vtCsiDispatch(console_id, b)
				vt.state = .Normal
			case:
				vt.state = .Normal
			}

		case .Osc:
			if b == 0x07 {
				vt.state = .Normal
			} else if b == 0x1B {
				vt.state = .OscEsc
			}

		case .OscEsc:
			vt.state = b == '\\' ? .Normal : .Osc
		}
	}
}

// ---------------------------------------------------------------------------
// C0
// ---------------------------------------------------------------------------

vtHandleC0 :: proc(console_id : u32, b : u8) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	switch b {
	case 0x07: // BEL,忽略
	case 0x08: // BS,左移不删字符
		if console.cursor_col > 0 {
			console.cursor_col -= 1
		}
	case 0x09: // TAB,下一 8 列停靠位
		col := (int(console.cursor_col) / 8 + 1) * 8
		console.cursor_col = min(u16(col), console.cols - 1)
	case 0x0A, 0x0B, 0x0C: // LF/VT/FF
		vtLf(console_id)
	case 0x0D: // CR
		console.cursor_col = 0
	}
}

vtLf :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if console.cursor_row < console.vt.scroll_bottom {
		console.cursor_row += 1
		return
	}
	vtScrollUp(console_id)
}

// 滚动区上移一行。全屏:行数组尾部增长,顶行滚进历史;
// 局部:顶行丢弃,底行补空行。
vtScrollUp :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	top, bottom := int(console.vt.scroll_top), int(console.vt.scroll_bottom)
	if top == 0 && bottom == int(console.rows) - 1 {
		append(&tb.lines, Line{})
		console.cursor_row += 1
		trimScrollback(console_id)
		return
	}
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[top].cells)
	remove_range(&tb.lines, top, top + 1)
	insertLine(&tb.lines, bottom)
}

vtScrollDown :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	top, bottom := int(console.vt.scroll_top), int(console.vt.scroll_bottom)
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[bottom].cells)
	remove_range(&tb.lines, bottom, bottom + 1)
	insertLine(&tb.lines, top)
}

// core:slice 无 insert 的替代实现
insertLine :: proc(lines : ^[dynamic]Line, index : int) {
	append(lines, Line{})
	copy(lines[index + 1:], lines[index:len(lines) - 1])
	lines[index] = Line{}
}

// 只在全屏滚动路径调用;裁掉最老行
trimScrollback :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	max_lines := int(console.rows) + MAX_SCROLLBACK_LINES
	if len(tb.lines) <= max_lines + TRIM_SLACK {
		return
	}
	cut := len(tb.lines) - max_lines
	for i in 0 ..< cut {
		delete(tb.lines[i].cells)
	}
	remove_range(&tb.lines, 0, cut)
	console.cursor_row -= u16(cut)
	console.vt.scroll_top, console.vt.scroll_bottom = 0, console.rows - 1
}

vtPrint :: proc(console_id : u32, cp : rune) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	ConsoleWriteRune(console_id, cp, console.vt.style)
}

vtUtf8Len :: proc(b : u8) -> int {
	switch {
	case b < 0x80: return 1
	case b < 0xE0: return 2
	case b < 0xF0: return 3
	case b < 0xF8: return 4
	}
	return 0
}

vtDecodeRune :: proc(bytes : []u8) -> rune {
	b := bytes
	switch len(b) {
	case 1: return rune(b[0])
	case 2: return rune(b[0] & 0x1F) << 6 | rune(b[1] & 0x3F)
	case 3: return rune(b[0] & 0x0F) << 12 | rune(b[1] & 0x3F) << 6 | rune(b[2] & 0x3F)
	case 4: return rune(b[0] & 0x07) << 18 | rune(b[1] & 0x3F) << 12 | rune(b[2] & 0x3F) << 6 | rune(b[3] & 0x3F)
	}
	return 0
}

// ---------------------------------------------------------------------------
// CSI
// ---------------------------------------------------------------------------

vtCsiDispatch :: proc(console_id : u32, final : u8) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	vt := &console.vt
	p0 := vt.params[0]
	p1 := 0
	if vt.param_count > 1 {
		p1 = vt.params[1]
	}

	switch final {
	case 'A': // CUU
		n := max(1, p0)
		console.cursor_row = u16(max(int(console.vt.scroll_top), int(console.cursor_row) - n))
	case 'B': // CUD
		n := max(1, p0)
		console.cursor_row = u16(min(int(console.vt.scroll_bottom), int(console.cursor_row) + n))
	case 'C': // CUF
		n := max(1, p0)
		console.cursor_col = u16(min(int(console.cols) - 1, int(console.cursor_col) + n))
	case 'D': // CUB
		n := max(1, p0)
		console.cursor_col = u16(max(0, int(console.cursor_col) - n))
	case 'H', 'f': // CUP(1-based)
		row := clamp(p0 - 1, int(console.vt.scroll_top), int(console.vt.scroll_bottom))
		col := clamp(p1 - 1, 0, int(console.cols) - 1)
		console.cursor_row, console.cursor_col = u16(row), u16(col)
	case 'G': // CHA
		console.cursor_col = u16(clamp(p0 - 1, 0, int(console.cols) - 1))
	case 'J': // ED
		vtEraseInDisplay(console_id, p0)
	case 'K': // EL
		vtEraseInLine(console_id, p0)
	case 'm': // SGR
		vtSgr(console_id)
	case 'h', 'l': // DEC 模式
		vtSetMode(console_id, final == 'h')
	case 'r': // 滚动区
		top := clamp(p0 - 1, 0, int(console.rows) - 1)
		bottom := int(console.rows) - 1
		if p1 > 0 {
			bottom = clamp(p1 - 1, 0, int(console.rows) - 1)
		}
		vt.scroll_top, vt.scroll_bottom = u16(min(top, bottom)), u16(max(top, bottom))
	case 's': // 存光标
		vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
	case 'u': // 取光标
		console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
	case 'S': // SU
		for i in 0 ..< max(1, p0) {
			vtScrollUp(console_id)
		}
	case 'T': // SD
		for i in 0 ..< max(1, p0) {
			vtScrollDown(console_id)
		}
	case 'n': // DSR
		if p0 == 6 {
			vtReplyCursor(console_id)
		}
	}
}

vtSetMode :: proc(console_id : u32, set : bool) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	vt := &console.vt
	if !vt.private {
		return
	}
	switch vt.params[0] {
	case 7:
		vt.autowrap = set
	case 25:
		vt.cursor_visible = set
	case 1049:
		vtAltScreen(console_id, set)
	case 2026: // 同步输出,全量重建天然满足
	}
}

// 进:存光标 + 切到交替屏(新建空页);出:切回主屏 + 销毁交替页 + 取光标
vtAltScreen :: proc(console_id : u32, enter : bool) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	vt := &console.vt
	if enter {
		vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
		alt := vt.alt_term_buffer_id
		if alt == 0 {
			alt, _ = CreateTermBuffer()
			ConsoleAttachTermBuffer(console_id, alt)
			vt.alt_term_buffer_id = alt
		} else {
			ConsoleActivateTermBuffer(console_id, alt)
		}
		TermBufferClear(alt)
		console.cursor_row, console.cursor_col = 0, 0
	} else {
		alt := vt.alt_term_buffer_id
		if console.term_buffer_count > 0 {
			ConsoleActivateTermBuffer(console_id, console.term_buffer_ids[0])
		}
		if alt != 0 {
			DestroyTermBuffer(alt)
			vt.alt_term_buffer_id = 0
		}
		console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
	}
}

// mode:0 到行尾 / 1 到行首 / 2 整行
vtEraseInLine :: proc(console_id : u32, mode : int) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	row := int(console.cursor_row)
	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
	switch mode {
	case 0:
		for col in int(console.cursor_col) ..< len(line.cells) {
			line.cells[col] = {}
		}
	case 1:
		for col in 0 ..= int(console.cursor_col) {
			if col < len(line.cells) {
				line.cells[col] = {}
			}
		}
	case 2:
		for &cell in line.cells {
			cell = {}
		}
	}
}

// mode:0 光标到屏尾 / 1 屏头到光标 / 2 可视区 / 3 全部 + 历史
vtEraseInDisplay :: proc(console_id : u32, mode : int) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	switch mode {
	case 0:
		vtEraseInLine(console_id, 0)
		for row in int(console.cursor_row) + 1 ..< len(tb.lines) {
			vtClearLineAll(console_id, row)
		}
	case 1:
		for row in 0 ..< int(console.cursor_row) {
			vtClearLineAll(console_id, row)
		}
		vtEraseInLine(console_id, 1)
	case 2:
		start := max(0, len(tb.lines) - int(console.rows))
		for row in start ..< len(tb.lines) {
			vtClearLineAll(console_id, row)
		}
	case 3:
		TermBufferClear(console.active_term_buffer_id)
	}
}

vtClearLineAll :: proc(console_id : u32, row : int) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if row < 0 || row >= len(tb.lines) {
		return
	}
	for &cell in tb.lines[row].cells {
		cell = {}
	}
}

// ---------------------------------------------------------------------------
// SGR
// ---------------------------------------------------------------------------

// xterm 标准 16 色
ANSI16 : [16]u32 = {
	0x000000, 0x800000, 0x008000, 0x808000,
	0x000080, 0x800080, 0x008080, 0xC0C0C0,
	0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
	0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
}

vtSgr :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	vt := &console.vt
	style := vt.style
	params := vt.params[:vt.param_count]
	i := 0
	for i < len(params) {
		p := params[i]
		switch p {
		case 0:
			style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR }
		case 1: style.bold = true
		case 3: style.italic = true
		case 4: style.underline = true
		case 7: style.reverse = true
		case 22: style.bold = false
		case 23: style.italic = false
		case 24: style.underline = false
		case 27: style.reverse = false
		case 30 ..= 37: style.fg = ANSI16[p - 30]
		case 38, 48: // 38;5;n / 38;2;r;g;b
			if i + 1 < len(params) {
				mode := params[i + 1]
				if mode == 5 && i + 2 < len(params) {
					color := ansi256ToRgb(params[i + 2])
					if p == 38 { style.fg = color } else { style.bg = color }
					i += 2
				} else if mode == 2 && i + 4 < len(params) {
					color := (u32(params[i + 2]) << 16) | (u32(params[i + 3]) << 8) | u32(params[i + 4])
					if p == 38 { style.fg = color } else { style.bg = color }
					i += 4
				}
			}
		case 39: style.fg = DEFAULT_COLOR
		case 40 ..= 47: style.bg = ANSI16[p - 40]
		case 49: style.bg = DEFAULT_COLOR
		case 90 ..= 97: style.fg = ANSI16[p - 90 + 8]
		case 100 ..= 107: style.bg = ANSI16[p - 100 + 8]
		}
		i += 1
	}
	vt.style = style
}

ansi256ToRgb :: proc(n : int) -> u32 {
	if n < 16 {
		return ANSI16[n]
	}
	if n < 232 {
		n := n - 16
		r := ansiCubeLevel(n / 36)
		g := ansiCubeLevel((n % 36) / 6)
		b := ansiCubeLevel(n % 6)
		return (r << 16) | (g << 8) | b
	}
	v := 8 + (n - 232) * 10
	return u32(v) * 0x010101
}

ansiCubeLevel :: proc(v : int) -> u32 {
	return u32(v == 0 ? 0 : 55 + v * 40)
}

// ESC[row;colR 应答光标位置(程序阻塞等这个)
vtReplyCursor :: proc(console_id : u32) {
	console := GetConsole(console_id)
	if console == nil {
		return
	}
	msg := fmt.tprintf("\x1b[%d;%dR", int(console.cursor_row) + 1, int(console.cursor_col) + 1)
	ct.WriteConptyInput(console_id, transmute([]byte)msg)
}
