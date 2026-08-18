package canvas

import ct "../conpty"
import mem "../memory"

// 双层屏幕模型:
//   内容层 TermBuffer:一"页"的所有行(含滚动历史)。
//   视口层 Console:行列、光标、登记/激活的页、滚动偏移、VT 状态。
//   Console 与 ConptyContext 通过 conpty_handle 绑定;函数间传递一律用 Handle,内部自查槽位。
//   渲染契约:visible_top = max(0, len(lines) - rows - tb.scroll_offset) // scroll_offset 随 buffer
//            屏幕第 r 行 ↔ lines[visible_top + r];光标屏幕位置 = cursor_row - visible_top
//            第 r 行第 c 列格子左上角像素 = (origin_x + c*cell_w, origin_y + r*cell_h);cell 来自 font 度量

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
	lines : [dynamic]Line,
	scroll_offset : u32,
}

term_buffers : mem.GenArray(MAX_TERM_BUFFER_SLOTS, TermBuffer)

CreateTermBuffer :: proc() -> (h : mem.Handle, ok : bool) {
	lines := make([dynamic]Line)
	append(&lines, Line{}) // 占位首行
	h = mem.Alloc(&term_buffers, TermBuffer { lines = lines })
	if h.id == 0 {
		delete(lines)
		return {}, false
	}
	return h, true
}

GetTermBuffer :: proc(h : mem.Handle) -> ^TermBuffer {
	return mem.Get(&term_buffers, h)
}

TermBufferLineCount :: proc(h : mem.Handle) -> int {
	tb := GetTermBuffer(h)
	if tb == nil {
		return 0
	}
	return len(tb.lines)
}

DestroyTermBuffer :: proc(h : mem.Handle) {
	tb := GetTermBuffer(h)
	if tb == nil {
		return
	}
	for &line in tb.lines {
		delete(line.cells)
	}
	delete(tb.lines)
	mem.Free(&term_buffers, h)
}

// 清空全部行(1049h 进交替屏时)
TermBufferClear :: proc(h : mem.Handle) {
	tb := GetTermBuffer(h)
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
	origin_x, origin_y : f32, // 居中后网格左上角(iterm 坐标空间);每帧由 ConsoleUpdateLayout 重算
	cursor_row, cursor_col : u16, // 指向 active buffer 的物理行

	vt : VtState,

	term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle, // ids[0] = 主屏
	term_buffer_count : u32,
	active_term_buffer_id : mem.Handle, // 当前渲染/写入的页;0 = 未登记

	conpty_handle : mem.Handle, // 绑定的 ConPTY

	font_id : mem.Handle, // 布局取度量、渲染取图集;0 = 未设
	font_size : f32, // 创建时的目标字号
}

consoles : mem.GenArray(MAX_CONSOLE_SLOTS, Console)

// 自动建主屏 TermBuffer;绑定 conpty_handle
CreateConsole :: proc(rows, cols : u16, conpty_handle : mem.Handle) -> (h : mem.Handle, ok : bool) {
	if rows == 0 || cols == 0 {
		return {}, false
	}
	if ct.GetConptyContext(conpty_handle) == nil {
		return {}, false
	}
	tb_h, tb_ok := CreateTermBuffer()
	if !tb_ok {
		return {}, false
	}
	console := Console {
		rows = rows,
		cols = cols,
		conpty_handle = conpty_handle,
	}
	console.vt = VtState {
		autowrap = true,
		cursor_visible = true,
		scroll_bottom = rows - 1,
		style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR },
	}
	h = mem.Alloc(&consoles, console)
	if h.id == 0 {
		DestroyTermBuffer(tb_h)
		return {}, false
	}
	if !ConsoleAttachTermBuffer(h, tb_h) {
		DestroyTermBuffer(tb_h)
		mem.Free(&consoles, h)
		return {}, false
	}
	return h, true
}

GetConsole :: proc(h : mem.Handle) -> ^Console {
	return mem.Get(&consoles, h)
}

ConsoleActiveTermBuffer :: proc(console_h : mem.Handle) -> mem.Handle {
	console := GetConsole(console_h)
	if console == nil {
		return {}
	}
	return console.active_term_buffer_id
}

// ConPTY 侧由 conpty 包负责,这里只释放视口
DestroyConsole :: proc(h : mem.Handle) {
	console := GetConsole(h)
	if console == nil {
		return
	}
	for i in 0 ..< int(console.term_buffer_count) {
		DestroyTermBuffer(console.term_buffer_ids[i])
	}
	mem.Free(&consoles, h)
}

// ---------------------------------------------------------------------------
// Console 操作
// ---------------------------------------------------------------------------

// 登记一个 TermBuffer 并设为当前渲染目标;重复登记只切换不新增
ConsoleAttachTermBuffer :: proc(console_h, term_buffer_h : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	if GetTermBuffer(term_buffer_h) == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_h {
			console.active_term_buffer_id = term_buffer_h
			return true
		}
	}
	if console.term_buffer_count >= MAX_BUFFERS_PER_CONSOLE {
		return false
	}
	console.term_buffer_ids[console.term_buffer_count] = term_buffer_h
	console.term_buffer_count += 1
	console.active_term_buffer_id = term_buffer_h
	return true
}

// 在已登记的 TermBuffer 间切换(1049 交替屏);未登记的 id 拒绝
ConsoleActivateTermBuffer :: proc(console_h, term_buffer_h : mem.Handle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	for i in 0 ..< int(console.term_buffer_count) {
		if console.term_buffer_ids[i] == term_buffer_h {
			console.active_term_buffer_id = term_buffer_h
			return true
		}
	}
	return false
}

// 改网格尺寸的副作用:cursor_col/滚动区下限 clamp + scroll_offset 锚定补偿。
// 锚定规则(同 alacritty):贴底保持贴底,滚动中保持视口内容(visible_top)不动。
// 注意:cursor_row 是物理行索引(指向 lines,可 > rows),不能按屏幕行 clamp。
applyConsoleSize :: proc(console : ^Console, rows, cols : u16) {
	tb := GetTermBuffer(console.active_term_buffer_id)
	visible_top_before := 0
	if tb != nil {
		visible_top_before = max(0, len(tb.lines) - int(console.rows) - int(tb.scroll_offset))
	}

	console.rows, console.cols = rows, cols
	console.cursor_col = min(console.cursor_col, cols - 1)
	console.vt.scroll_bottom = rows - 1

	// 滚动中:反推 scroll_offset 使 visible_top 不变(内容不被拽走)
	if tb != nil && tb.scroll_offset != 0 {
		max_scroll := max(0, len(tb.lines) - int(rows))
		s := len(tb.lines) - int(rows) - visible_top_before
		tb.scroll_offset = u32(max(0, min(s, max_scroll)))
	}
}

// Resize 时先改 ConPTY 再改这里;已有行不截断
ConsoleSetSize :: proc(console_h : mem.Handle, rows, cols : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil || rows == 0 || cols == 0 {
		return false
	}
	applyConsoleSize(console, rows, cols)
	return true
}

// iterm 几何变化时由渲染层每帧调用(transform 现算不存):
// 取整出 cols/rows,网格在 iterm 内居中;cols/rows 变化后 ConPTY 尺寸由调用方联动
ConsoleUpdateLayout :: proc(console_h : mem.Handle, t : Transform, cell_w, cell_h : f32) -> bool {
	console := GetConsole(console_h)
	if console == nil || cell_w <= 0 || cell_h <= 0 {
		return false
	}
	rows := max(1, int(t.height / cell_h))
	cols := max(1, int(t.width / cell_w))
	applyConsoleSize(console, u16(rows), u16(cols))
	console.origin_x = t.position_x + (t.width - f32(cols) * cell_w) * 0.5
	console.origin_y = t.position_y + (t.height - f32(rows) * cell_h) * 0.5
	return true
}

ConsoleSetCursor :: proc(console_h : mem.Handle, row, col : u16) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	console.cursor_row = min(row, console.rows - 1)
	console.cursor_col = min(col, console.cols - 1)
	return true
}

ConsoleSetScrollOffset :: proc(console_h : mem.Handle, offset : u32) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	max_offset := max(0, len(tb.lines) - int(console.rows))
	tb.scroll_offset = min(u32(max_offset), offset)
	return true
}

// ---------------------------------------------------------------------------
// 写路径
// ---------------------------------------------------------------------------

// 当前屏幕(底部 rows 行)在 lines 里的物理起始行;len <= rows 时为 0(顶部锚定)
screenBase :: proc(console : ^Console, tb : ^TermBuffer) -> int {
	return max(0, len(tb.lines) - int(console.rows))
}

// 落格 → 前进 → 行尾折行(autowrap 关则停在最后一列)→ 滚动区上移
ConsoleWriteRune :: proc(console_h : mem.Handle, cp : rune, style : CellStyle) -> bool {
	console := GetConsole(console_h)
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
			if int(console.cursor_row) - screenBase(console, tb) < int(console.vt.scroll_bottom) {
				console.cursor_row += 1
				for len(tb.lines) <= int(console.cursor_row) {
					append(&tb.lines, Line{})
				}
			} else {
				vtScrollUp(console_h)
			}
			tb.lines[console.cursor_row].wrapped = true
		} else {
			console.cursor_col = console.cols - 1
		}
	}
	return true
}
