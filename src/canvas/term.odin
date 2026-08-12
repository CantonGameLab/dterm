package canvas

import ct "../conpty"

// 双层屏幕模型:
//   内容层 TermBuffer:一"页"的所有行(含滚动历史)。
//   视口层 Console:行列、光标、登记/激活的页、滚动偏移、VT 状态。
//   Console 与 ConptyContext 同 id 同步;函数间传递一律用 id,内部自查槽位。
//   渲染契约:visible_top = max(0, len(lines) - rows - scroll_offset)
//            屏幕第 r 行 ↔ lines[visible_top + r];光标屏幕位置 = cursor_row - visible_top

// 0xFFFFFFFF = 渲染时查主题色
DEFAULT_COLOR :: 0xFFFF_FFFF

CellStyle :: struct {
	fg, bg : u32,
	bold, italic, underline, reverse : bool,
}

Cell :: struct {
	cp : rune, // 0 = 空白格
	using style : CellStyle,
}

Line :: struct {
	cells : [dynamic]Cell,
	wrapped : bool, // 由上一行折行而来,翻历史时按它拼回逻辑行
}

// ---------------------------------------------------------------------------
// TermBuffer
// ---------------------------------------------------------------------------

MAX_TERM_BUFFER_SLOTS :: 64
MAX_SCROLLBACK_LINES :: 10000
TRIM_SLACK :: 512 // 超上限这么多行才裁,避免频繁搬行

TermBuffer :: struct {
	lines : [dynamic]Line, // nil = 空槽
}

// id 约定:count 从 1 起,id 0 永不分配 → 0 = 空/null
term_buffers_count : u32 = 1
term_buffers : [MAX_TERM_BUFFER_SLOTS]TermBuffer

CreateTermBuffer :: proc() -> (id : u32, ok : bool) {
	for i in 1 ..< MAX_TERM_BUFFER_SLOTS {
		if term_buffers[i].lines != nil {
			continue
		}
		term_buffers[i].lines = make([dynamic]Line)
		if u32(i) + 1 > term_buffers_count {
			term_buffers_count = u32(i) + 1
		}
		return u32(i), true
	}
	return 0, false
}

GetTermBuffer :: proc(id : u32) -> ^TermBuffer {
	if id == 0 || id >= MAX_TERM_BUFFER_SLOTS {
		return nil
	}
	if term_buffers[id].lines == nil {
		return nil
	}
	return &term_buffers[id]
}

TermBufferLineCount :: proc(id : u32) -> int {
	tb := GetTermBuffer(id)
	if tb == nil {
		return 0
	}
	return len(tb.lines)
}

DestroyTermBuffer :: proc(id : u32) {
	tb := GetTermBuffer(id)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	delete(tb.lines)
	tb^ = {}
}

// 清空全部行(1049h 进交替屏时)
TermBufferClear :: proc(id : u32) {
	tb := GetTermBuffer(id)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	clear(&tb.lines)
}

// ---------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------

MAX_CONSOLE_SLOTS :: 32
MAX_BUFFERS_PER_CONSOLE :: 8

Console :: struct {
	rows, cols : u16,
	cursor_row, cursor_col : u16, // 指向 active buffer 的物理行

	vt : VtState,

	term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]u32, // ids[0] = 主屏
	term_buffer_count : u32,
	active_term_buffer_id : u32, // 当前渲染/写入的页;0 = 未登记

	scroll_offset : u32, // 距底部翻页行数;0 = 跟随底部
}

consoles_count : u32 = 1
consoles : [MAX_CONSOLE_SLOTS]Console // rows == 0 = 空槽

// 槽位 id 必须等于 conpty 槽位 id;自动建主屏 TermBuffer
CreateConsole :: proc(rows, cols : u16, conpty_id : u32) -> (id : u32, ok : bool) {
	if rows == 0 || cols == 0 {
		return 0, false
	}
	if conpty_id == 0 || conpty_id >= MAX_CONSOLE_SLOTS {
		return 0, false
	}
	if consoles[conpty_id].rows != 0 {
		return 0, false
	}
	if ct.GetConptyContext(conpty_id) == nil {
		return 0, false
	}
	tb_id, tb_ok := CreateTermBuffer()
	if !tb_ok {
		return 0, false
	}
	consoles[conpty_id] = Console {
		rows = rows,
		cols = cols,
	}
	consoles[conpty_id].vt = VtState {
		autowrap = true,
		cursor_visible = true,
		scroll_bottom = rows - 1,
		style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR },
	}
	ConsoleAttachTermBuffer(conpty_id, tb_id)
	if conpty_id + 1 > consoles_count {
		consoles_count = conpty_id + 1
	}
	return conpty_id, true
}

GetConsole :: proc(id : u32) -> ^Console {
	if id == 0 || id >= MAX_CONSOLE_SLOTS {
		return nil
	}
	if consoles[id].rows == 0 {
		return nil
	}
	return &consoles[id]
}

ConsoleActiveTermBuffer :: proc(console_id : u32) -> u32 {
	console := GetConsole(console_id)
	if console == nil {
		return 0
	}
	return console.active_term_buffer_id
}

// ConPTY 侧由 conpty 包负责,这里只释放视口
DestroyConsole :: proc(id : u32) {
	console := GetConsole(id)
	if console == nil {
		return
	}
	for i in 0 ..< int(console.term_buffer_count) {
		DestroyTermBuffer(console.term_buffer_ids[i])
	}
	console^ = {}
}

// ---------------------------------------------------------------------------
// Console 操作
// ---------------------------------------------------------------------------

// 登记一个 TermBuffer 并设为当前渲染目标;重复登记只切换不新增
ConsoleAttachTermBuffer :: proc(console_id, term_buffer_id : u32) -> bool {
	console := GetConsole(console_id)
	if console == nil {
		return false
	}
	if GetTermBuffer(term_buffer_id) == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_id {
			console.active_term_buffer_id = term_buffer_id
			return true
		}
	}
	if console.term_buffer_count >= MAX_BUFFERS_PER_CONSOLE {
		return false
	}
	console.term_buffer_ids[console.term_buffer_count] = term_buffer_id
	console.term_buffer_count += 1
	console.active_term_buffer_id = term_buffer_id
	return true
}

// 在已登记的 TermBuffer 间切换(1049 交替屏);未登记的 id 拒绝
ConsoleActivateTermBuffer :: proc(console_id, term_buffer_id : u32) -> bool {
	console := GetConsole(console_id)
	if console == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_id {
			console.active_term_buffer_id = term_buffer_id
			return true
		}
	}
	return false
}

// Resize 时先改 ConPTY 再改这里;已有行不截断
ConsoleSetSize :: proc(console_id : u32, rows, cols : u16) -> bool {
	console := GetConsole(console_id)
	if console == nil || rows == 0 || cols == 0 {
		return false
	}
	console.rows, console.cols = rows, cols
	console.cursor_row = min(console.cursor_row, rows - 1)
	console.cursor_col = min(console.cursor_col, cols - 1)
	console.vt.scroll_bottom = rows - 1
	return true
}

ConsoleSetCursor :: proc(console_id : u32, row, col : u16) -> bool {
	console := GetConsole(console_id)
	if console == nil {
		return false
	}
	console.cursor_row = min(row, console.rows - 1)
	console.cursor_col = min(col, console.cols - 1)
	return true
}

ConsoleSetScrollOffset :: proc(console_id : u32, offset : u32) -> bool {
	console := GetConsole(console_id)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	max_offset := max(0, len(tb.lines) - int(console.rows))
	console.scroll_offset = min(u32(max_offset), offset)
	return true
}

// ---------------------------------------------------------------------------
// 写路径
// ---------------------------------------------------------------------------

// 落格 → 前进 → 行尾折行(autowrap 关则停在最后一列)→ 滚动区上移
ConsoleWriteRune :: proc(console_id : u32, cp : rune, style : CellStyle) -> bool {
	console := GetConsole(console_id)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	row, col := int(console.cursor_row), int(console.cursor_col)

	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
	for len(line.cells) <= col {
		append(&line.cells, Cell{})
	}
	line.cells[col] = Cell { cp = cp, style = style }

	console.cursor_col += 1
	if console.cursor_col >= console.cols {
		console.cursor_col = 0
		if console.vt.autowrap {
			if console.cursor_row < console.vt.scroll_bottom {
				console.cursor_row += 1
				for len(tb.lines) <= int(console.cursor_row) {
					append(&tb.lines, Line{})
				}
			} else {
				vtScrollUp(console_id)
			}
			tb.lines[console.cursor_row].wrapped = true
		} else {
			console.cursor_col = console.cols - 1
		}
	}
	return true
}
