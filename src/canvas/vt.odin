package canvas

import ct "../conpty"
import mem "../memory"
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
	private : u8,      // CSI 私用标记:0=无 1='?'(DEC) 2='>'(xterm) 3=其他
	intermediate : u8, // CSI 中间字节(0x20-0x2F,最后一次),0=无

	utf8_pending : [4]u8, // 未收完的 UTF-8 分片
	utf8_pending_len : int,

	esc_pending : bool, // ESC ( ) * + # % 后:下一字节是参数,直接消费

	style : CellStyle,
	saved_cursor_row, saved_cursor_col : u16,
	scroll_top, scroll_bottom : u16,
	autowrap : bool,
	cursor_visible : bool,
	cursor_style : u8,     // DECSCUSR:0=默认 1=闪烁块 2=稳态块 3=闪烁下划线 4=稳态下划线 5=闪烁竖线 6=稳态竖线
	alt_term_buffer_id : mem.Handle, // 0 = 未创建
	mouse_mode : u8,       // 0=关 1=1000 2=1002 3=1003
	sgr_mouse : bool,      // 1006
	focus_events : bool,   // 1004
	bracketed_paste : bool, // 2004
	modify_other_keys : u8, // 0/1/2
}

update_scratch : [64 * 1024]byte // 主循环单线程,包级复用

// DA2 应答里的终端版本号
DA2_VERSION :: 100

UpdateConsole :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	data := ct.GetReadWriteData(console.conpty_handle)
	if data == nil {
		return
	}
	n := ct.RingPop(data, update_scratch[:])
	if n <= 0 {
		return
	}
	vtFeed(console_h, update_scratch[:n])
}

vtFeed :: proc(console_h : mem.Handle, data : []byte) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	for b in data {
		switch vt.state {
		case .Normal:
			if vt.esc_pending { // 消费 ESC ( ) * + # % 后的参数字节
				vt.esc_pending = false
				continue
			}
			if vt.utf8_pending_len > 0 { // 收完分片再打印
				vt.utf8_pending[vt.utf8_pending_len] = b
				vt.utf8_pending_len += 1
				if vt.utf8_pending_len >= vtUtf8Len(vt.utf8_pending[0]) {
					vtPrint(console_h, vtDecodeRune(vt.utf8_pending[:vt.utf8_pending_len]))
					vt.utf8_pending_len = 0
				}
				continue
			}
			switch {
			case b == 0x1B:
				vt.state = .Esc
			case b < 0x20 || b == 0x7F:
				vtHandleC0(console_h, b)
			case b < 0x80:
				vtPrint(console_h, rune(b))
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
				vt.private = 0
				vt.intermediate = 0
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
			case '(', ')', '*', '+', '#', '%': // 字符集/属性/编码选择:下一字节是参数
				vt.esc_pending = true
				vt.state = .Normal
			case '=': // DECKPAM 应用小键盘
				vt.state = .Normal
			case '>': // DECKPNM 数字小键盘
				vt.state = .Normal
			case 'D': // IND 索引(下移)
				vtLf(console_h)
				vt.state = .Normal
			case 'E': // NEL 下一行
				console.cursor_col = 0
				vtLf(console_h)
				vt.state = .Normal
			case 'M': // RI 反索引(上移)
				vtReverseIndex(console_h)
				vt.state = .Normal
			case 'c': // RIS 复位
				vtReset(console_h)
				vt.state = .Normal
			case 'N', 'O': // SS2/SS3 单移位,忽略
				vt.state = .Normal
			case:
				vt.state = .Normal
			}

		case .Csi:
			switch {
			case b == '?':
				vt.private = 1
			case b == '>':
				vt.private = 2
			case b == '<':
				vt.private = 3
			case b >= 0x20 && b <= 0x2F: // 中间字节($ SP ! " 等)
				vt.intermediate = b
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
				vtCsiDispatch(console_h, b)
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

vtHandleC0 :: proc(console_h : mem.Handle, b : u8) {
	console := GetConsole(console_h)
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
		vtLf(console_h)
	case 0x0D: // CR
		console.cursor_col = 0
	}
}

vtLf :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	if int(console.cursor_row) - screenBase(console, tb) < int(console.vt.scroll_bottom) {
		console.cursor_row += 1
		return
	}
	vtScrollUp(console_h)
}

// 滚动区上移一行。全屏:行数组尾部增长,顶行滚进历史;
// 局部:顶行丢弃,底行补空行。
vtScrollUp :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
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
		trimScrollback(console_h)
		return
	}
	for len(tb.lines) <= bottom {
		append(&tb.lines, Line{})
	}
	delete(tb.lines[top].cells)
	remove_range(&tb.lines, top, top + 1)
	insertLine(&tb.lines, bottom)
}

vtScrollDown :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
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

// RI:光标上移一行;在滚动区顶则向下滚动
vtReverseIndex :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := screenBase(console, tb)
	if int(console.cursor_row) - base > int(console.vt.scroll_top) {
		console.cursor_row -= 1
		return
	}
	vtScrollDown(console_h)
}

// RIS:复位终端(清屏 + 重置样式/滚动区/光标)
vtReset :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	TermBufferClear(console.active_term_buffer_id)
	console.vt.style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR }
	console.vt.scroll_top = 0
	console.vt.scroll_bottom = console.rows - 1
	console.vt.autowrap = true
	console.cursor_row, console.cursor_col = 0, 0
}

// core:slice 无 insert 的替代实现
insertLine :: proc(lines : ^[dynamic]Line, index : int) {
	append(lines, Line{})
	copy(lines[index + 1:], lines[index:len(lines) - 1])
	lines[index] = Line{}
}

// 只在全屏滚动路径调用;裁掉最老行
trimScrollback :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
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

vtPrint :: proc(console_h : mem.Handle, cp : rune) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ConsoleWriteRune(console_h, cp, console.vt.style)
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

vtCsiDispatch :: proc(console_h : mem.Handle, final : u8) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	tb := GetTermBuffer(console.active_term_buffer_id)
	base := 0
	if tb != nil {
		base = screenBase(console, tb)
	}
	p0 := vt.params[0]
	p1 := 0
	if vt.param_count > 1 {
		p1 = vt.params[1]
	}

	switch final {
	case 'A': // CUU
		n := max(1, p0)
		screen_row := int(console.cursor_row) - base
		screen_row = max(int(console.vt.scroll_top), screen_row - n)
		console.cursor_row = u16(base + screen_row)
	case 'B': // CUD
		n := max(1, p0)
		screen_row := int(console.cursor_row) - base
		screen_row = min(int(console.vt.scroll_bottom), screen_row + n)
		console.cursor_row = u16(base + screen_row)
	case 'C': // CUF
		n := max(1, p0)
		console.cursor_col = u16(min(int(console.cols) - 1, int(console.cursor_col) + n))
	case 'D': // CUB
		n := max(1, p0)
		console.cursor_col = u16(max(0, int(console.cursor_col) - n))
	case 'H', 'f': // CUP(1-based)
		row := base + clamp(p0 - 1, int(console.vt.scroll_top), int(console.vt.scroll_bottom))
		col := clamp(p1 - 1, 0, int(console.cols) - 1)
		console.cursor_row, console.cursor_col = u16(row), u16(col)
	case 'G': // CHA
		console.cursor_col = u16(clamp(p0 - 1, 0, int(console.cols) - 1))
	case 'J': // ED
		vtEraseInDisplay(console_h, p0)
	case 'K': // EL
		vtEraseInLine(console_h, p0)
	case 'm': // SGR;xterm 私用 '>' 是 modifyOtherKeys
		if vt.private == 2 {
			vt.modify_other_keys = u8(p1) // CSI > 4;Nm,N=0/1/2
		} else {
			vtSgr(console_h)
		}
	case 'h', 'l': // DEC 模式
		vtSetMode(console_h, final == 'h')
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
			vtScrollUp(console_h)
		}
	case 'T': // SD
		for i in 0 ..< max(1, p0) {
			vtScrollDown(console_h)
		}
	case 'n': // DSR
		if p0 == 6 {
			vtReplyCursor(console_h)
		} else if p0 == 5 {
			vtReplyOk(console_h) // 设备状态正常
		}
	case 'c': // DA 设备属性
		if vt.private == 2 {
			vtReplyDa2(console_h)
		} else {
			vtReplyDa1(console_h)
		}
	case 'p': // DECRQM 模式查询(带 $ 中间字节)
		if vt.intermediate == '$' {
			vtReplyDecrqm(console_h, p0)
		}
	case 'q': // DECSCUSR 光标形状(带 SP 中间字节)
		if vt.intermediate == ' ' {
			vt.cursor_style = u8(clamp(p0, 0, 6))
		}
	case 'X': // ECH 擦除 n 字符
		vtEraseChars(console_h, max(1, p0))
	case 'P': // DCH 删除 n 字符(左侧补)
		vtDeleteChars(console_h, max(1, p0))
	case '@': // ICH 插入 n 空白字符(右侧挤出)
		vtInsertChars(console_h, max(1, p0))
	case 'L': // IL 光标处插入 n 空行
		vtInsertLines(console_h, max(1, p0))
	case 'M': // DL 删除光标处 n 行
		vtDeleteLines(console_h, max(1, p0))
	case 'd': // VPA 行绝对定位
		console.cursor_row = u16(base + clamp(p0 - 1, 0, int(console.rows) - 1))
	case '`': // HPA 列绝对定位
		console.cursor_col = u16(clamp(p0 - 1, 0, int(console.cols) - 1))
	case 'e': // VPR 行相对下移
		console.cursor_row = u16(min(base + int(console.vt.scroll_bottom), int(console.cursor_row) + max(1, p0)))
	case 'a': // HPR 列相对右移
		console.cursor_col = u16(min(int(console.cols) - 1, int(console.cursor_col) + max(1, p0)))
	}
}

vtSetMode :: proc(console_h : mem.Handle, set : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	if vt.private != 1 { // 仅 '?' DEC 私用模式
		return
	}
	switch vt.params[0] {
	case 7:
		vt.autowrap = set
	case 25:
		vt.cursor_visible = set
	case 1000:
		vt.mouse_mode = set ? 1 : 0
	case 1002:
		vt.mouse_mode = set ? 2 : 0
	case 1003:
		vt.mouse_mode = set ? 3 : 0
	case 1006:
		vt.sgr_mouse = set
	case 1004:
		vt.focus_events = set
	case 2004:
		vt.bracketed_paste = set
	case 1049:
		vtAltScreen(console_h, set)
	case 2026: // 同步输出,全量重建天然满足
	}
}

// 进:存光标 + 切到交替屏(新建空页);出:切回主屏 + 销毁交替页 + 取光标
vtAltScreen :: proc(console_h : mem.Handle, enter : bool) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	vt := &console.vt
	if enter {
		vt.saved_cursor_row, vt.saved_cursor_col = console.cursor_row, console.cursor_col
		alt := vt.alt_term_buffer_id
		if alt.id == 0 {
			alt, _ = CreateTermBuffer()
			ConsoleAttachTermBuffer(console_h, alt)
			vt.alt_term_buffer_id = alt
		} else {
			ConsoleActivateTermBuffer(console_h, alt)
		}
		TermBufferClear(alt)
		console.cursor_row, console.cursor_col = 0, 0
	} else {
		alt := vt.alt_term_buffer_id
		if console.term_buffer_count > 0 {
			ConsoleActivateTermBuffer(console_h, console.term_buffer_ids[0])
		}
		if alt.id != 0 {
			DestroyTermBuffer(alt)
			vt.alt_term_buffer_id = {}
		}
		console.cursor_row, console.cursor_col = vt.saved_cursor_row, vt.saved_cursor_col
	}
}

// mode:0 到行尾 / 1 到行首 / 2 整行
vtEraseInLine :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
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
vtEraseInDisplay :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	switch mode {
	case 0:
		vtEraseInLine(console_h, 0)
		for row in int(console.cursor_row) + 1 ..< len(tb.lines) {
			vtClearLineAll(console_h, row)
		}
	case 1:
		for row in 0 ..< int(console.cursor_row) {
			vtClearLineAll(console_h, row)
		}
		vtEraseInLine(console_h, 1)
	case 2:
		start := max(0, len(tb.lines) - int(console.rows))
		for row in start ..< len(tb.lines) {
			vtClearLineAll(console_h, row)
		}
	case 3:
		TermBufferClear(console.active_term_buffer_id)
	}
}

vtClearLineAll :: proc(console_h : mem.Handle, row : int) {
	console := GetConsole(console_h)
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

// ECH:从光标起擦除 n 个字符(不清空行)
vtEraseChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	row := int(console.cursor_row)
	if row >= len(tb.lines) {
		return
	}
	line := &tb.lines[row]
	start := int(console.cursor_col)
	end := min(start + n, len(line.cells))
	for i in start ..< end {
		line.cells[i] = {}
	}
}

// DCH:删除光标起 n 字符,右侧左移补空白
vtDeleteChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	row := int(console.cursor_row)
	if row >= len(tb.lines) {
		return
	}
	line := &tb.lines[row]
	col := int(console.cursor_col)
	nn := min(n, len(line.cells) - col)
	remove_range(&line.cells, col, col + nn)
	for i in 0 ..< nn {
		append(&line.cells, Cell{})
	}
}

// ICH:光标处插入 n 空白字符,右侧挤出
vtInsertChars :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
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
	for len(line.cells) < int(console.cols) {
		append(&line.cells, Cell{})
	}
	col := int(console.cursor_col)
	nn := min(n, int(console.cols) - col)
	copy(line.cells[col + nn:], line.cells[col:int(console.cols) - nn])
	for i in col ..< col + nn {
		line.cells[i] = {}
	}
}

// IL:光标处插入 n 空行,滚动区底行被挤出
vtInsertLines :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := screenBase(console, tb)
	row := int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
	for i in 0 ..< n {
		for len(tb.lines) <= bottom {
			append(&tb.lines, Line{})
		}
		if bottom < len(tb.lines) {
			delete(tb.lines[bottom].cells)
			remove_range(&tb.lines, bottom, bottom + 1)
		}
		insertLine(&tb.lines, row)
	}
}

// DL:删除光标处 n 行,滚动区底补空行
vtDeleteLines :: proc(console_h : mem.Handle, n : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	base := screenBase(console, tb)
	row := int(console.cursor_row)
	bottom := base + int(console.vt.scroll_bottom)
	for i in 0 ..< n {
		if row >= len(tb.lines) {
			break
		}
		delete(tb.lines[row].cells)
		remove_range(&tb.lines, row, row + 1)
		insertLine(&tb.lines, bottom)
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

vtSgr :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
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
vtReplyCursor :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	msg := fmt.tprintf("\x1b[%d;%dR", int(console.cursor_row) + 1, int(console.cursor_col) + 1)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

vtReplyOk :: proc(console_h : mem.Handle) { // DSR 5:设备状态正常
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)string("\x1b[0n"))
}

// DA1:CSI c → CSI ? 1;2c(VT100 兼容)
vtReplyDa1 :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)string("\x1b[?1;2c"))
}

// DA2:CSI > Ps c → CSI > 0;{版本};0c(nvim 用它识别终端)
vtReplyDa2 :: proc(console_h : mem.Handle) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	msg := fmt.tprintf("\x1b[>0;%d;0c", DA2_VERSION)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

// DECRQM:CSI ? Ps $ p → CSI ? Ps;Pm $ y(Pm:0=未知 1=置位 2=复位 3=永置 4=永复)
vtReplyDecrqm :: proc(console_h : mem.Handle, mode : int) {
	console := GetConsole(console_h)
	if console == nil {
		return
	}
	state := vtQueryMode(console, mode)
	msg := fmt.tprintf("\x1b[?%d;%d$y", mode, state)
	ct.WriteConptyInput(console.conpty_handle, transmute([]byte)msg)
}

vtQueryMode :: proc(console : ^Console, mode : int) -> int {
	vt := &console.vt
	switch mode {
	case 7:
		return vt.autowrap ? 1 : 2
	case 25:
		return vt.cursor_visible ? 1 : 2
	case 1049:
		return vt.alt_term_buffer_id.id != 0 ? 1 : 2
	case 1000:
		return vt.mouse_mode == 1 ? 1 : 2
	case 1002:
		return vt.mouse_mode == 2 ? 1 : 2
	case 1003:
		return vt.mouse_mode == 3 ? 1 : 2
	case 1006:
		return vt.sgr_mouse ? 1 : 2
	case 1004:
		return vt.focus_events ? 1 : 2
	case 2004:
		return vt.bracketed_paste ? 1 : 2
	}
	return 0 // 未识别
}

// 调试/测试:直接喂字节给解析器,绕过 ConPTY
ConsoleFeed :: proc(console_h : mem.Handle, data : []byte) {
	vtFeed(console_h, data)
}
