// 场景绘制:只读遍历窗口树,把每个 leaf 节点的 Console 画到屏幕。
// 消费现有模型(窗口树 / Console / TermBuffer / font),零数据写回。
package render

import cv "../canvas"
import fnt "../font"
import mem "../memory"

// 默认配色(DEFAULT_COLOR 的解析目标)
Theme :: struct {
	fg     : u32, // 默认前景 0xRRGGBB
	bg     : u32, // 默认背景
	cursor : u32, // 光标色
}

// 每帧绘制入口:只读遍历窗口树
DrawFrame :: proc(theme : Theme) {
	drawWalk(cv.WindowTreeRoot(), theme)
	// 终端内容先上屏(flush 攒的 quad),否则 nano vulg 会画在终端之下
	FlushBatch()
	// UI 悬浮层(nanovg):在终端内容之上绘制控件
	if cv.CommandBarVisible() {
		UiBegin(screen_w, screen_h) // 需要物理像素尺寸
		drawCommandBar(theme)
		UiEnd()
	}
}

// 悬浮控制台:nanovg 抗锯齿圆角长条,锚定焦点 window 右上角。
drawCommandBar :: proc(theme : Theme) {
	focus := cv.GetFocus()
	if focus.id == 0 {
		return
	}
	node := cv.GetWindowTreeNode(focus)
	if node == nil {
		return
	}
	bar := cv.GetCommandBar()
	text := string(bar.input[:bar.len])
	// 控制台配色:不透明、与终端深底明显区分。
	// 背景 = 终端 fg(浅),文字 = 终端 bg(深)—— 高对比反色,悬浮清晰。
	bar_fg := theme.fg
	bar_text := theme.bg
	UiDrawCommandBar(node.position_x, node.position_y, node.width, node.height, text, bar_fg, bar_text, 1.0)
}

// 颜色混合:a 向 b 偏移 t(0..1),0xRRGGBB
mixColor :: proc(a, b : u32, t : f32) -> u32 {
	ar := f32(a >> 16 & 0xFF)
	ag := f32(a >> 8 & 0xFF)
	ab := f32(a & 0xFF)
	br := f32(b >> 16 & 0xFF)
	bg := f32(b >> 8 & 0xFF)
	bb := f32(b & 0xFF)
	cr := u32(ar + (br - ar) * t)
	cg := u32(ag + (bg - ag) * t)
	cb := u32(ab + (bb - ab) * t)
	return cr << 16 | cg << 8 | cb
}

drawWalk :: proc(node_h : mem.Handle, theme : Theme) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		// 先画子树(背景被 frame 覆盖),再画分割条
		drawWalk(node.left_son_id, theme)
		drawWalk(node.right_son_id, theme)
		drawFrame(node_h)
		return
	}
	win := cv.NodeWindow(node_h)
	if win != nil && win.console_id.id != 0 {
		drawConsole(node_h, theme)
	}
}

// 分割条:内部节点按 split_type 画一条 frame 宽度的色条
drawFrame :: proc(node_h : mem.Handle) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	fw := f32(node.frame_width)
	if fw <= 0 {
		return
	}
	left := cv.GetWindowTreeNode(node.left_son_id)
	if left == nil {
		return
	}
	switch node.split_type {
	case .LeftRight:
		// 竖条:紧贴左子右边界
		DrawRect(left.position_x + left.width, node.position_y, fw, node.height, node.frame_color)
	case .UpDown:
		// 横条:紧贴左(上)子下边界
		DrawRect(node.position_x, left.position_y + left.height, node.width, fw, node.frame_color)
	}
}

drawConsole :: proc(node_h : mem.Handle, theme : Theme) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	win := cv.NodeWindow(node_h)
	if win == nil {
		return
	}
	console := cv.GetConsole(win.console_id)
	if console == nil {
		return
	}
	m := fnt.GetMetrics(console.font_id)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	t := cv.NodeContentTransform(node_h)

	// 打底背景
	DrawRect(t.position_x, t.position_y, t.width, t.height, theme.bg)

	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return
	}
	visible_top := max(0, len(tb.lines) - int(console.rows) - int(tb.scroll_offset))

	// 行连体 shaping 缓冲:按最大列宽一次性分配,逐行复用
	shaped := make([dynamic]u16, int(console.cols))
	orig := make([dynamic]u16, int(console.cols))
	defer delete(shaped)
	defer delete(orig)

	for r in 0 ..< int(console.rows) {
		line_idx := visible_top + r
		if line_idx >= len(tb.lines) {
			break
		}
		line := &tb.lines[line_idx]
		col_limit := min(int(console.cols), len(line.cells))

		// 逐行连体 shaping:cell cp → 主字体 glyph id,ShapeLine 原地替换
		// 输出与输入一一对应,替换后的 id 用 GetGlyphById 绘制
		resize(&shaped, col_limit)
		resize(&orig, col_limit)
		for c in 0 ..< col_limit {
			g := fnt.GlyphIndex(console.font_id, line.cells[c].cp)
			orig[c] = g
			shaped[c] = g
		}
		fnt.ShapeLine(console.font_id, &shaped)

		// 连体合并(未来 type4)会缩短数组;绘制按缩短后的长度截断
		draw_limit := min(col_limit, len(shaped))
		// 两遍绘制:先全部背景,再全部字形。
		// 连体字形位图会溢出到相邻格(如 --- 的 32px 连体),若逐格"背景+字形"交替,
		// 后格的背景矩形会盖住前格连体字形的溢出部分(高亮选中行尤其明显)。
		for c in 0 ..< draw_limit {
			cell := line.cells[c]
			bg := resolveColor(cell.bg, theme.bg)
			if cell.reverse {
				bg = resolveColor(cell.fg, theme.fg)
			}
			if bg != theme.bg {
				cx := console.origin_x + f32(c) * m.cell_width
				cy := console.origin_y + f32(r) * m.cell_height
				DrawRect(cx, cy, m.cell_width, m.cell_height, bg)
			}
		}
		for c in 0 ..< draw_limit {
			cell := line.cells[c]
			if cell.cp == 0 {
				continue // 空白格/宽字符续列:无字形
			}
			cx := console.origin_x + f32(c) * m.cell_width
			cy := console.origin_y + f32(r) * m.cell_height
			fg := resolveColor(cell.fg, theme.fg)
			if cell.reverse {
				fg = resolveColor(cell.bg, theme.bg)
			}
			gid := shaped[c]
			if gid != 0 && gid != orig[c] {
				// 连体替换:画替换字形
				DrawGlyphById(console.font_id, gid, cx, cy + m.ascent, fg)
			} else {
				DrawRune(console.font_id, cell.cp, cx, cy + m.ascent, fg)
			}
		}
	}

	// 块状光标:先画光标块,再用底色重绘该格字形保持可见。
	// 停在宽字符首格时画 2 格宽(覆盖续列)。
	if console.vt.cursor_visible {
		cr := int(console.cursor_row) - visible_top
		if cr >= 0 && cr < int(console.rows) {
			cx := console.origin_x + f32(console.cursor_col) * m.cell_width
			cy := console.origin_y + f32(cr) * m.cell_height
			cw := m.cell_width
			line_idx := visible_top + cr
			if line_idx < len(tb.lines) {
				line := &tb.lines[line_idx]
				if int(console.cursor_col) < len(line.cells) {
					cell := line.cells[int(console.cursor_col)]
					if cell.cp != 0 && cell.wide {
						cw = m.cell_width * 2 // 宽字符首格:光标覆盖两格
					}
				}
			}
			DrawRect(cx, cy, cw, m.cell_height, theme.cursor)
			if line_idx < len(tb.lines) {
				line := &tb.lines[line_idx]
				if int(console.cursor_col) < len(line.cells) {
					cell := line.cells[int(console.cursor_col)]
					if cell.cp != 0 {
						DrawRune(console.font_id, cell.cp, cx, cy + m.ascent, theme.bg)
					}
				}
			}
		}
	}
}

resolveColor :: proc(c, default : u32) -> u32 {
	if c == cv.DEFAULT_COLOR {
		return default
	}
	return c
}
