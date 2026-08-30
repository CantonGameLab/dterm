// 主题数据:终端默认色 + 16 ANSI 色 + UI 色(唯一实例 current_theme,canvas 唯一写者)。
// CellStyle.fg/bg 存颜色**引用编码**(见下),渲染期 ResolveColor 解码 →
// 主题切换零缓冲污染(解析器零主题依赖),256 色固定公式(16-231 cube/232-255 灰度)。
// 参考:alacritty(269 索引表)/ WT(扁平配色方案)/ kitty(color0-255 + 边框色独立)。
package canvas

// 颜色引用编码(u32,CellStyle.fg/bg):
//   0x00RRGGBB            直接 RGB(SGR 38;2;r;g;b)
//   0x01xxxxxx(低24 = n)  索引色 n:0-15 → theme.ansi[n];16-255 → 固定 cube/灰度
//   0xFFFFFFFF            默认 → theme.fg / theme.bg(SGR 39/49/0)
DEFAULT_COLOR :: u32(0xFFFF_FFFF)

colorRgb :: proc(c : u32) -> u32 {
	return c // 24bit RGB,高字节 = 0
}

colorIndex :: proc(n : int) -> u32 {
	return 0x01_000000 | u32(n & 0xFF_FFFF)
}

// 渲染期解码:颜色引用 → RGB;默认色解析为 default 参数
ResolveColor :: proc(c : u32, default : u32) -> u32 {
	switch c >> 24 {
	case 0x00: // RGB
		return c
	case 0x01: // 索引
		return ansi256ToRgb(int(c & 0xFF_FFFF))
	}
	return default
}

// 256 索引 → RGB:0-15 取主题 ansi;16-231 cube;232-255 灰度(标准公式)
ansi256ToRgb :: proc(n : int) -> u32 {
	if n < 16 {
		return current_theme.ansi[n]
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

// ---------------------------------------------------------------------------
// 主题
// ---------------------------------------------------------------------------
Theme :: struct {
	fg, bg : u32, // 默认前景/背景(SGR 39/49/0 解析目标)
	cursor : u32, // 光标
	ansi : [16]u32, // SGR 索引 0..15:0-7 普通,8-15 亮(顺序 = WT/alacritty/kitty)
	frame : u32, // 分割条(原树节点 frame_color,主题化后节点回纯结构)
	focus_border : u32, // 焦点窗口边框(kitty active_border 对应物)
	fps_bg, fps_fg : u32, // 右上角 FPS tag
	tab_bar_bg : u32, // 底部页签条背景(非激活区)
	tab_fg : u32, // 非激活页签文字
	tab_active_bg : u32, // 激活页签底(默认 = 主题 bg:WT 式"背景延伸进激活页签")
	tab_active_fg : u32, // 激活页签文字(默认 = 主题 fg)
	tab_hover_bg : u32, // 页签悬停底
}

// 默认主题(现行配色)
DEFAULT_THEME := Theme {
	fg = 0xDCDCDC,
	bg = 0x1E1E1E,
	cursor = 0xFFFFFF,
	ansi = {
		0x000000, 0x800000, 0x008000, 0x808000,
		0x000080, 0x800080, 0x008080, 0xC0C0C0,
		0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
		0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
	},
	frame = 0xFFFF00,
	focus_border = 0x4FC3F7,
	fps_bg = 0x101418,
	fps_fg = 0x9FBFD8,
	tab_bar_bg = 0x16161C,
	tab_fg = 0x8A8F98,
	tab_active_bg = 0x1E1E1E, // = bg(WT 式背景延伸)
	tab_active_fg = 0xEAEAEA,
	tab_hover_bg = 0x26262E,
}

current_theme : Theme = DEFAULT_THEME

// Dracula 主题(官方配色):bg #282A36 / fg #F8F8F2,accent 紫 #BD93F9,
// 分割条用 selection 灰紫 #44475A(低调)
DRACULA_THEME := Theme {
	fg = 0xF8F8F2,
	bg = 0x282A36,
	cursor = 0xF8F8F2,
	ansi = {
		0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
		0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
		0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
		0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
	},
	frame = 0x44475A,
	focus_border = 0xBD93F9,
	fps_bg = 0x21222C,
	fps_fg = 0x6272A4,
	tab_bar_bg = 0x21222C,
	tab_fg = 0x6272A4,
	tab_active_bg = 0x282A36, // 激活页签 = 主题 bg(背景延伸)
	tab_active_fg = 0xF8F8F2,
	tab_hover_bg = 0x383A4E,
}

// 切换主题:下一帧渲染全部按新表解码(缓冲内容零重写)
SetTheme :: proc(t : Theme) {
	current_theme = t
}

// 查询当前主题(定制项统一命名:Set<域>/Get<域>)
GetTheme :: proc() -> Theme {
	return current_theme
}
