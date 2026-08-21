// 场景绘制:只读遍历窗口树,把每个 Console iterm 画到屏幕。
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
}

drawWalk :: proc(node_h : mem.Handle, theme : Theme) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		drawWalk(node.left_son_id, theme)
		drawWalk(node.right_son_id, theme)
		return
	}
	for i in 0 ..< len(node.iterms) {
		if node.iterms[i].type == cv.ItermType.Console {
			drawConsole(node_h, i, theme)
		}
	}
}

drawConsole :: proc(node_h : mem.Handle, iterm_index : int, theme : Theme) {
	it := cv.ItermGet(node_h, iterm_index)
	if it == nil {
		return
	}
	console := cv.GetConsole(it.console_id)
	if console == nil {
		return
	}
	m := fnt.GetMetrics(console.font_id)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	t := cv.ItermAbsoluteTransform(node_h, iterm_index)

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

	// 块状光标:先画光标块,再用底色重绘该格字形保持可见
	if console.vt.cursor_visible {
		cr := int(console.cursor_row) - visible_top
		if cr >= 0 && cr < int(console.rows) {
			cx := console.origin_x + f32(console.cursor_col) * m.cell_width
			cy := console.origin_y + f32(cr) * m.cell_height
			DrawRect(cx, cy, m.cell_width, m.cell_height, theme.cursor)
			line_idx := visible_top + cr
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
