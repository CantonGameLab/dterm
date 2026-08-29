// 场景绘制:只读遍历窗口树,把每个 leaf 节点的 Console 画到屏幕。
// 消费现有模型(窗口树 / Console / TermBuffer / font),零数据写回。
package render

import cv "../canvas"
import fnt "../font"
import mem "../memory"
import s3 "vendor:sdl3"
import "core:fmt"
import "core:time"

// 每帧绘制入口:只读遍历窗口树(主题经 cv.ThemeGet 只读消费)
DrawFrame :: proc() {
	drawWalk(cv.WindowTreeRoot())
	drawFocusBorder() // 焦点描边:画在所有内容与分割条之上
	drawFps() // 右上角 FPS tag(观测数据,渲染层自身统计)
	// 终端内容先上屏(flush 攒的 quad),否则 nano vulg 会画在终端之下
	FlushBatch()
	// UI 悬浮层(nanovg):在终端内容之上绘制控件
	if cv.CommandBarVisible() {
		UiBegin(screen_w, screen_h) // 需要物理像素尺寸
		drawCommandBar()
		UiEnd()
	}
}

// ---------------------------------------------------------------------------
// FPS tag(右上角):渲染层统计自身帧率,每 0.5s 刷新一次显示值
// ---------------------------------------------------------------------------
fps_font : mem.Handle // render.Init 加载;失败 = 不显示
fps_start : time.Time
fps_frames : int
fps_value : f32

// 行连体 shaping 复用缓冲(单线程渲染;resize 只会首次扩容,之后零分配)
draw_shaped : [dynamic]u16
draw_orig : [dynamic]u16

drawFps :: proc() {
	theme := cv.ThemeGet()
	fps_frames += 1
	if fps_start == {} {
		fps_start = time.now()
	}
	elapsed := time.duration_seconds(time.since(fps_start))
	if elapsed >= 0.5 {
		fps_value = f32(fps_frames) / f32(elapsed)
		fps_frames = 0
		fps_start = time.now()
	}
	if fps_value <= 0 {
		return // 第一窗口期未满:不画
	}
	m := fnt.GetMetrics(fps_font)
	if m.cell_width <= 0 || m.cell_height <= 0 {
		return
	}
	text := fmt.tprintf("%.0f fps", fps_value)
	w := f32(len(text)) * m.cell_width
	x, y := screen_w - w - 12, f32(10)
	DrawRect(x - 6, y - 2, w + 12, m.cell_height + 4, theme.fps_bg)
	DrawText(fps_font, text, x, y + m.ascent, theme.fps_fg)
}

// 焦点窗口边框高亮:焦点 leaf 矩形内侧描边(覆盖内容边缘,不动分割条)。
FOCUS_BORDER_WIDTH :: f32(1.0)

drawFocusBorder :: proc() {
	theme := cv.ThemeGet()
	focus := cv.GetFocus()
	if focus.id == 0 {
		return
	}
	t := cv.NodeContentTransform(focus)
	if t.width <= 0 || t.height <= 0 {
		return
	}
	d := FOCUS_BORDER_WIDTH
	c := theme.focus_border
	DrawRect(t.position_x, t.position_y, t.width, d, c) // 上
	DrawRect(t.position_x, t.position_y + t.height - d, t.width, d, c) // 下
	DrawRect(t.position_x, t.position_y, d, t.height, c) // 左
	DrawRect(t.position_x + t.width - d, t.position_y, d, t.height, c) // 右
}

// 悬浮控制台:遍历焦点窗口的 iterm 工具层,取 .CommandBar 可见条目
// 按 iterm 锚定几何绘制(nanovg 抗锯齿圆角长条)。
drawCommandBar :: proc() {
	theme := cv.ThemeGet()
	focus := cv.GetFocus()
	if focus.id == 0 {
		return
	}
	win := cv.NodeWindow(focus)
	if win == nil {
		return
	}
	index := -1
	for i in 0 ..< len(win.iterms) {
		if win.iterms[i].tool_type == cv.ToolType.CommandBar && win.iterms[i].visible {
			index = i
			break
		}
	}
	if index < 0 {
		return
	}
	t := cv.ItermAbsoluteTransform(focus, index)
	bar := cv.GetCommandBar(focus)
	if bar == nil {
		return
	}
	text := string(bar.input[:bar.len])
	// 控制台配色:不透明、与终端深底明显区分。
	// 背景 = 终端 fg(浅),文字 = 终端 bg(深)—— 高对比反色,悬浮清晰。
	bar_fg := theme.fg
	bar_text := theme.bg
	UiDrawCommandBar(t.position_x, t.position_y, t.width, t.height,
		text, bar.cursor, bar_fg, bar_text, 1.0)
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

drawWalk :: proc(node_h : mem.Handle) {
	node := cv.GetWindowTreeNode(node_h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		// 先画子树(背景被 frame 覆盖),再画分割条
		drawWalk(node.left_son_id)
		drawWalk(node.right_son_id)
		drawFrame(node_h)
		return
	}
	win := cv.NodeWindow(node_h)
	if win != nil {
		drawConsole(node_h) // 内部按 console 句柄判定,无 console 直返
	}
}

// 分割条:内部节点按 split_type 画一条 frame 宽度的色条(颜色读主题)
drawFrame :: proc(node_h : mem.Handle) {
	theme := cv.ThemeGet()
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
		DrawRect(left.position_x + left.width, node.position_y, fw, node.height, theme.frame)
	case .UpDown:
		// 横条:紧贴左(上)子下边界
		DrawRect(node.position_x, left.position_y + left.height, node.width, fw, theme.frame)
	}
}

drawConsole :: proc(node_h : mem.Handle) {
	theme := cv.ThemeGet()
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
	m := fnt.GetMetrics(win.font_id)
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
	visible_top, _ := cv.ConsoleViewportTop(win.console_id)

	// 行连体 shaping 缓冲:模块级复用(零分配),逐行 resize 复用
	for r in 0 ..< int(console.rows) {
		line_idx := visible_top + r
		if line_idx >= len(tb.lines) {
			break
		}
		line := &tb.lines[line_idx]
		col_limit := min(int(console.cols), len(line.cells))

		// 逐行连体 shaping:cell cp → 主字体 glyph id,ShapeLine 原地替换
		// 输出与输入一一对应,替换后的 id 用 GetGlyphById 绘制
		resize(&draw_shaped, col_limit)
		resize(&draw_orig, col_limit)
		for c in 0 ..< col_limit {
			g := fnt.GlyphIndex(win.font_id, line.cells[c].cp)
			draw_orig[c] = g
			draw_shaped[c] = g
		}
		fnt.ShapeLine(win.font_id, &draw_shaped)

		// 连体合并(未来 type4)会缩短数组;绘制按缩短后的长度截断
		draw_limit := min(col_limit, len(draw_shaped))
		// 两遍绘制:先全部背景,再全部字形。
		// 连体字形位图会溢出到相邻格(如 --- 的 32px 连体),若逐格"背景+字形"交替,
		// 后格的背景矩形会盖住前格连体字形的溢出部分(高亮选中行尤其明显)。
		for c in 0 ..< draw_limit {
			cell := line.cells[c]
			bg := cv.ResolveColor(cell.bg, theme.bg)
			if cell.reverse {
				bg = cv.ResolveColor(cell.fg, theme.fg)
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
			fg := cv.ResolveColor(cell.fg, theme.fg)
			if cell.reverse {
				fg = cv.ResolveColor(cell.bg, theme.bg)
			}
			gid := draw_shaped[c]
			drawCellGlyph(win.font_id, cell.cp, gid, draw_orig[c], cx, cy + m.ascent, fg, cell.bold)
		}
	}

	// 光标(DECSCUSR):0/1 块(闪烁) 2 块 3/4 下划线 5/6 竖线。
	// 闪烁样式按 500ms 相位亮/灭;块状先画块再用底色重绘字形,条形不遮字形无需重绘。
	if console.vt.cursor_visible && cursorBlinkOn(console.vt.cursor_style) {
		cr := int(console.cursor_row) - visible_top
		if cr >= 0 && cr < int(console.rows) {
			cx := console.origin_x + f32(console.cursor_col) * m.cell_width
			cy := console.origin_y + f32(cr) * m.cell_height
			style := console.vt.cursor_style
			switch {
			case style == 3 || style == 4: // 下划线:贴格底
				uh := max(2.0, m.cell_height * 0.08)
				DrawRect(cx, cy + m.cell_height - uh, m.cell_width, uh, theme.cursor)
			case style == 5 || style == 6: // 竖线:贴格左边缘,1px
				DrawRect(cx, cy, 1.0, m.cell_height, theme.cursor)
			case: // 0/1/2:块;停在宽字符首格时画 2 格宽(覆盖续列)
				cw := m.cell_width
				line_idx := visible_top + cr
				if line_idx < len(tb.lines) {
					line := &tb.lines[line_idx]
					if int(console.cursor_col) < len(line.cells) {
						cell := line.cells[int(console.cursor_col)]
						if cell.cp != 0 && cell.wide {
							cw = m.cell_width * 2
						}
					}
				}
				DrawRect(cx, cy, cw, m.cell_height, theme.cursor)
				if line_idx < len(tb.lines) {
					line := &tb.lines[line_idx]
					if int(console.cursor_col) < len(line.cells) {
						cell := line.cells[int(console.cursor_col)]
						if cell.cp != 0 {
							// 粗体字符同样双描重绘(否则光标块下残留 1px 粗体边)
							drawCellGlyph(win.font_id, cell.cp, 0, 0, cx, cy + m.ascent, theme.bg, cell.bold)
						}
					}
				}
			}
		}
	}
}

// 画一个字符字形:(x, y) = 基线。粗体 = 合成加粗:同字形向右 1px 双描
// (alpha 叠加变实;不依赖字体的真粗体字形,任意字体立即生效)。
// gid != 0 且是连体替换结果时按替换字形绘制,否则查普通字形;gid=0 = 强制普通路径。
drawCellGlyph :: proc(font_h : mem.Handle, cp : rune, gid, orig_gid : u16, x, y : f32, color : u32, bold : bool) {
	if gid != 0 && gid != orig_gid {
		if bold {
			DrawGlyphById(font_h, gid, x + 1, y, color)
		}
		DrawGlyphById(font_h, gid, x, y, color)
		return
	}
	if bold {
		DrawRune(font_h, cp, x + 1, y, color)
	}
	DrawRune(font_h, cp, x, y, color)
}

// DECSCUSR 闪烁样式(Ps=1/3/5):500ms 亮、500ms 灭
cursorBlinkOn :: proc(style : u8) -> bool {
	if style != 1 && style != 3 && style != 5 {
		return true
	}
	return (s3.GetTicks() / 500) % 2 == 0
}
