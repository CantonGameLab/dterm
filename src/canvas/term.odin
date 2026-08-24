package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"
import vp "../vtparse"
import "core:fmt"
import "core:math"

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
	cp : rune, // 0 = 空白格;宽字符续列 = cp 0 + wide true
	using style : CellStyle,
	wide : bool, // 宽字符(占 2 列)或宽字符的续列
}

// 宽字符判定(EAW=W/F 的核心子集,与 nvim/wcwidth 一致)
runeWidth :: proc(cp : rune) -> int {
	switch {
	case cp >= 0x1100 && cp <= 0x115F: return 2 // Hangul Jamo
	case cp >= 0x2E80 && cp <= 0x303E: return 2 // CJK 部首/符号
	case cp >= 0x3041 && cp <= 0x33FF: return 2 // 假名/CJK 兼容
	case cp >= 0x3400 && cp <= 0x4DBF: return 2 // CJK 扩展 A
	case cp >= 0x4E00 && cp <= 0x9FFF: return 2 // CJK 统一
	case cp >= 0xA000 && cp <= 0xA4CF: return 2 // 彝文
	case cp >= 0xAC00 && cp <= 0xD7A3: return 2 // Hangul 音节
	case cp >= 0xF900 && cp <= 0xFAFF: return 2 // CJK 兼容表意
	case cp >= 0xFE30 && cp <= 0xFE4F: return 2 // CJK 兼容形式
	case cp >= 0xFF00 && cp <= 0xFF60: return 2 // 全角 ASCII
	case cp >= 0xFFE0 && cp <= 0xFFE6: return 2 // 全角符号
	case cp >= 0x1F300 && cp <= 0x1F64F: return 2 // emoji
	case cp >= 0x20000 && cp <= 0x2FFFD: return 2 // CJK 扩展 B+
	case cp >= 0x30000 && cp <= 0x3FFFD: return 2
	}
	return 1
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
	// 解析器回调绑定(user_data 存句柄供回调取回)
	vp.Init(&GetConsole(h).vt.parser, vtParserCallback)
	GetConsole(h).vt.parser.user_data = packHandle(h)
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

// 销毁 console 本体:会话(读线程 + ConPTY)+ 视口。
// 本函数不摸窗口层数据;窗口对它的引用由窗口层调用方先经 clearConsoleRefs 断干净。
DestroyConsole :: proc(h : mem.Handle) {
	console := GetConsole(h)
	if console == nil {
		return
	}
	ct.StopReadThread(console.conpty_handle) // 句柄无效 = no-op
	ct.DestroyConpty(console.conpty_handle)
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
	console.vt.wrap_pending = false

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
	if console.vt.deccolm {
		cols = 132 // DECCOLM 132 列模式覆盖布局计算
	}
	applyConsoleSize(console, u16(rows), u16(cols))
	if console.vt.deccolm {
		console.origin_x = t.position_x // 132 列超出窗口:左对齐
	} else {
		console.origin_x = t.position_x + (t.width - f32(cols) * cell_w) * 0.5
	}
	console.origin_y = t.position_y + (t.height - f32(rows) * cell_h) * 0.5
	// 网格起点取整到像素:origin 带 .5 时背景矩形与字形(各自取整)会错位 1px
	console.origin_x = math.round(console.origin_x)
	console.origin_y = math.round(console.origin_y)
	return true
}

// 遍历窗口树,更新每个 leaf 节点绑定的 Console 的布局(尺寸变化时
// Resize ConPTY)并拉取输出。由 main 每帧调用一次;递归属于树结构操作,归 canvas 管理。
ConsoleUpdateTree :: proc(node_h : mem.Handle) {
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		ConsoleUpdateTree(node.left_son_id)
		ConsoleUpdateTree(node.right_son_id)
		return
	}
	win := NodeWindow(node_h)
	if win == nil || GetConsole(win.console_id) == nil {
		return
	}
	console_h := win.console_id
	console := GetConsole(console_h)
	if console == nil {
		return
	}

	//检测Console 是否需要resize
	t := NodeContentTransform(node_h)
	m := fnt.GetMetrics(console.font_id)

	old_rows, old_cols := console.rows, console.cols
	ConsoleUpdateLayout(console_h, t, m.cell_width, m.cell_height)
	if console.rows != old_rows || console.cols != old_cols {
		ct.Resize(console.conpty_handle, console.cols, console.rows)
	}

	//通过vtparser自动更新Console
	UpdateConsole(console_h)
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

// 折行一次:光标下移/滚动,列归 0。调用方保证 pending 语义由自己处理
vtWrapOnce :: proc(console_h : mem.Handle) {
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
		for len(tb.lines) <= int(console.cursor_row) {
			append(&tb.lines, Line{})
		}
	} else {
		vtScrollUp(console_h)
	}
	tb.lines[console.cursor_row].wrapped = true
	console.cursor_col = 0
}

// 落格 → 前进 → 最后一列置 wrap-pending(下一字符才折行)→ 滚动区上移
ConsoleWriteRune :: proc(console_h : mem.Handle, cp : rune, style : CellStyle) -> bool {
	console := GetConsole(console_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	// wrap-pending:上一字符写满最后一列,本字符先折行再落格
	if console.vt.wrap_pending {
		console.vt.wrap_pending = false
		if console.vt.autowrap {
			vtWrapOnce(console_h)
		} else {
			console.cursor_col = console.cols - 1
		}
	}
	row, col := int(console.cursor_row), int(console.cursor_col)
	when VT_DEBUG {
		vtDbg(console_h, fmt.tprintf("WRITE '%c' at %d,%d", cp, row, col))
	}

	w := runeWidth(cp)
	// 宽字符放不下当前列(只剩 1 列):先折行再写(xterm 语义)
	if w == 2 && col + w > int(console.cols) {
		vtWrapOnce(console_h)
		row, col = int(console.cursor_row), int(console.cursor_col)
	}
	for len(tb.lines) <= row {
		append(&tb.lines, Line{})
	}
	line := &tb.lines[row]
	for len(line.cells) <= col + w - 1 {
		append(&line.cells, Cell { style = { fg = DEFAULT_COLOR, bg = DEFAULT_COLOR } })
	}
	line.cells[col] = Cell { cp = cp, style = style, wide = w == 2 }
	if w == 2 {
		line.cells[col + 1] = Cell { style = style, wide = true } // 续列继承样式(背景)
	}

	console.cursor_col += u16(w)
	if console.cursor_col >= console.cols {
		// 写满最后一列:光标停最后一列,置 pending,等下一字符决定折行
		console.cursor_col = console.cols - 1
		console.vt.wrap_pending = console.vt.autowrap
	}
	return true
}
