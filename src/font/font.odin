// 字体系统:rune → 可渲染字形(灰度位图入 GL 图集 + 度量)。
// 对外 5 个函数:LoadFont / DestroyFont / GetGlyph / GetMetrics / GetAtlasTexture。
// 懒光栅化:字形首次用到才 stbtt 渲染,入图集缓存;主字体缺字自动走中文 fallback(同一图集)。
// 槽位数组 + id 句柄:count 从 1 起,id 0 = 空;跨层一律传 Handle,GetFont(h) 拿指针。
package font

import stbtt "vendor:stb/truetype"
import gl "vendor:OpenGL"
import win "core:sys/windows"
import "core:c"
import "core:fmt"
import "core:os"
import "core:math"
import "core:strings"
import mem "../memory"

// ---------------------------------------------------------------------------
// 对外数据
// ---------------------------------------------------------------------------

// 渲染层每字符拿一次:UV + 度量,凑 quad 用
Glyph :: struct {
	advance : f32, // 前进宽(像素)
	bitmap_w, bitmap_h : f32, // 位图内容尺寸(不含边距)
	xoff, yoff : f32, // 位图左上角相对基线原点的偏移
	uv0_x, uv0_y, uv1_x, uv1_y : f32, // 图集内内容区 UV(与 quad 尺寸一致)
}

Metrics :: struct {
	cell_width : f32, // 等宽格宽
	cell_height : f32, // 行高
	ascent : f32, // 基线相对格顶的偏移
}

// ---------------------------------------------------------------------------
// 内部数据
// ---------------------------------------------------------------------------

// 字体表容量 = 路径数 × 字号档数(同 path+size 复用,共享不销毁)。
// 8 槽只够 7 档字号,AdjustFontSize 几次就撞顶;32 档 ≈ 单字体 26→181(步长 5),
// 来回调整有回退复用;撞顶即调档失败,LoadFont 打日志。
MAX_FONT_SLOTS :: 32
MAX_FACES :: 2 // 0 = 主字体,1 = 中文 fallback,共用图集
ATLAS_PAD :: 1 // 位图四周留 1px,防线性采样串色
ATLAS_START :: 1024
ATLAS_MAX :: 4096
SLOT_LOAD_FACTOR :: 0.75
SHAPE_CACHE_SLOTS :: 128 // 行 shape 缓存槽(轮转)

// ttc 里取第 0 个字体
FALLBACK_FONTS :: []string {
	`C:\Windows\Fonts\msyh.ttc`,
	`C:\Windows\Fonts\simhei.ttf`,
	`C:\Windows\Fonts\simsun.ttc`,
	`C:\Windows\Fonts\Deng.ttf`,
}

Face :: struct {
	data : []byte, // 字体文件内容;stbtt 表指针引用它,必须保活
	info : stbtt.fontinfo,
	scale : f32, // ScaleForPixelHeight(size)
	sfnt_off : int, // sfnt 目录偏移(TTC 非 0),表定位用
}

// 字形缓存条目(哈希表,线性探测)
GlyphSlot :: struct {
	cp : rune, // 0 = 无 cp(可能是 gid 槽)
	gid : u16, // 连体字形(内部 id);0 = 无。空槽 = cp==0 && gid==0
	face_index : u8, // 重光栅化时按它选 face
	w, h : u16, // 位图内容尺寸
	xoff, yoff : f32,
	advance : f32,
	u0, v0, u1, v1 : f32,
}

// 行式分配:字形沿 cur_x 排,行满换行
Atlas :: struct {
	texture : u32, // GL_R8 灰度
	pixels : []u8,
	width, height : u32,
	cur_x, cur_y, row_height : u32,
}

// 行 shape 缓存条目:输入 glyph 序列哈希 → 输出序列。
// 行内容不变则命中,跳过 GSUB 规则匹配(与字形缓存同理)。
ShapeCacheSlot :: struct {
	hash : u64, // 输入序列 FNV-1a;0 = 空槽
	len : u16,
	glyphs : [dynamic]u16, // 输出序列(连体替换后)
}

Font :: struct {
	faces : [MAX_FACES]Face,
	face_count : u32,
	gsub : Gsub, // 主字体 GSUB 连体规则;无连体时 lookup_order 为空,ShapeLine 空转
	antialias : u8, // 光栅化超采样倍数 1-3;相对静止,LoadFont 时一次设定
	cell_width, cell_height : f32,
	ascent : f32,
	path : string, // 加载路径(去重键:同 path+size 复用,不重复加载)
	size : f32, // 字号(去重键)
	slots : [dynamic]GlyphSlot,
	slot_count : u32,
	atlas : Atlas,
	shape_cache : [SHAPE_CACHE_SLOTS]ShapeCacheSlot, // 轮转覆盖
	shape_cache_next : u32,
}

fonts : mem.GenArray(MAX_FONT_SLOTS, Font)

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

// 规范化字体名:去尾部 "(TrueType)"/"(OpenType)"/"(All res)" 等注记,忽略空格/连字符/下划线,大写。
// 使 "FiraCodeNerdFontMono" 与显示名 "FiraCode Nerd Font Mono (TrueType)" 互相命中。
// 结果写入调用方缓冲(Odin 的 string([]byte) 是零拷贝 cast,不能返回栈上缓冲)。
normalizeFontName :: proc(s : string, buf : []byte) -> string {
	n := 0
	end := len(s)
	if end > 0 && s[end - 1] == ')' {
		for i := end - 1; i >= 0; i -= 1 {
			if s[i] == '(' {
				end = i
				break
			}
		}
	}
	for i in 0 ..< end {
		c := s[i]
		switch c {
		case ' ', '-', '_':
			continue
		}
		if n >= len(buf) - 1 {
			break
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		buf[n] = c
		n += 1
	}
	return string(buf[:n])
}

// 字体内 name 表的 family(1)/fullname(4) 名,规范化后输出到 out(权威显示名:
// 注册表值名如 "FiraCode Nerd Font Mono Reg" 是安装器缩写,字体文件内才是用户所见名)。
faceFamilyName :: proc(f : ^Face, out : []byte) -> string {
	tmp : [160]byte
	combos := [?][3]c.int{{3, 1, 0x409}, {3, 1, 0}, {1, 0, 0}} // (platform, encoding, language)
	name_ids := [?]c.int{1, 4}
	for combo in combos {
		for name_id in name_ids {
			length : c.int
			p := stbtt.GetFontNameString(&f.info, &length, stbtt.PLATFORM_ID(combo[0]), combo[1], combo[2], name_id)
			if p == nil || length <= 0 {
				continue
			}
			raw := (cast([^]u8)p)[:int(length)]
			m := 0 // UTF-16BE → ASCII(字体名是拉丁字符,直接取低字节)
			for i := 0; i + 1 < int(length); i += 2 {
				if m >= len(tmp) {
					break
				}
				tmp[m] = raw[i + 1]
				m += 1
			}
			if m == 0 {
				continue
			}
			if r := normalizeFontName(string(tmp[:m]), out); len(r) > 0 {
				return r
			}
		}
	}
	return ""
}

// 打开字体文件读 family 名(轻量:只取 info,读完即弃)
faceFamilyNameFromPath :: proc(path : string, out : []byte) -> string {
	f, ok := faceLoad(path, 12)
	if !ok {
		return ""
	}
	defer delete(f.data)
	return faceFamilyName(&f, out)
}

// 注册表字体名 → 文件路径:HKLM\...\CurrentVersion\Fonts 的值名 = 显示名,值 = 文件名/路径。
// Windows 的"字体名"(如 FiraCode Nerd Font Mono)与文件名(FiraCodeNerdFontMono-Regular.ttf)
// 关系无规则,注册表是唯一可靠映射。匹配顺序:
//   1. 前缀命中(注册表名可能带权重缩写 Reg/Ret 等)→ 用文件内 family 名校验(输入即用户所见名)
//   2. 精确命中 → 文件内 family 校验通过即返回;否则作为兜底
// 命中返回堆分配路径(调用方释放)。
registryFontPath :: proc(input : string) -> (path : string, ok : bool) {
	key : win.HKEY
	sub := win.utf8_to_wstring(`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`)
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, sub, 0, win.KEY_READ, &key) != 0 {
		return "", false
	}
	defer win.RegCloseKey(key)

	target_buf : [256]byte
	target := normalizeFontName(input, target_buf[:])

	exact_file : string
	exact_ok := false

	Cand :: struct {
		full : string,
		prefer : bool, // regular 档(非粗/斜/细);同 family 多字重优先
	}
	cands : [dynamic]Cand
	defer delete(cands) // 元素 full 是堆字符串,由下方清理;delete 只在返回路径释放

	disp_buf : [128]u8
	d_buf : [256]byte
	name_buf : [512]u16
	data_buf : [1024]u8
	for idx : u32 = 0; ; idx += 1 {
		name_len := u32(len(name_buf))
		data_len := u32(len(data_buf))
		if win.RegEnumValueW(key, idx, &name_buf[0], &name_len, nil, nil, cast(^win.BYTE)&data_buf[0], &data_len) != 0 {
			break
		}
		disp := win.utf16_to_utf8_buf(disp_buf[:], name_buf[:name_len])
		d := normalizeFontName(disp, d_buf[:])
		is_exact := d == target
		is_pref := strings.has_prefix(d, target)
		if !is_exact && !is_pref {
			continue
		}
		// 值 = REG_SZ(UTF-16,含尾部 NUL),手动拷贝避免对齐问题
		n16 := int(data_len) / 2
		if n16 > 0 && data_buf[n16 * 2 - 2] == 0 && data_buf[n16 * 2 - 1] == 0 {
			n16 -= 1
		}
		ws := make([]u16, n16, context.temp_allocator)
		for i in 0 ..< n16 {
			ws[i] = u16(data_buf[i * 2]) | u16(data_buf[i * 2 + 1]) << 8
		}
		file, _ := win.utf16_to_utf8_alloc(ws, context.temp_allocator)
		full := file
		if !strings.contains(file, "\\") && !strings.contains(file, "/") {
			full = strings.concatenate({SYSTEM_FONT_DIR, file})
		}
		if is_exact {
			exact_file = strings.clone(full)
			exact_ok = true
		}
		// 文件内 family 名是最终权威(注册表名可能带权重缩写 Reg/Ret 等)
		fam_buf : [256]byte
		if fam := faceFamilyNameFromPath(full, fam_buf[:]); fam == target {
			prefer := !strings.contains(d, "BOLD") &&
				!strings.contains(d, "LIGHT") &&
				!strings.contains(d, "ITALIC") &&
				!strings.contains(d, "MEDIUM") &&
				!strings.contains(d, "MED") &&
				!strings.contains(d, "SEMI") &&
				!strings.contains(d, "SEMB") &&
				!strings.contains(d, "BLACK")
			append(&cands, Cand { full = strings.clone(full), prefer = prefer })
		}
	}
	// 候选选择:regular 档优先,否则第一个
	if len(cands) > 0 {
		sel := 0
		for i in 0 ..< len(cands) {
			if cands[i].prefer {
				sel = i
				break
			}
		}
		ret := cands[sel].full
		for i in 0 ..< len(cands) {
			if i != sel {
				delete(cands[i].full)
			}
		}
		return ret, true
	}
	if exact_ok {
		return exact_file, true
	}
	return "", false
}

// 解析字体输入:优先当作系统字体名(系统目录 + .ttf/.otf/.ttc),找到返回完整路径;
// 否则原样返回(按完整路径处理)。
// 命中系统字体时返回堆分配字符串(调用方负责 release),未命中返回 path_or_name(借用)。
resolveFontPath :: proc(path_or_name : string) -> (path : string, is_alloc : bool) {
	// 已含盘符/路径分隔符:视为完整路径,直接返回
	if strings.contains(path_or_name, "\\") || strings.contains(path_or_name, "/") {
		return path_or_name, false
	}
	// 系统字体名:拼 目录 + name + .ttf / .otf / .ttc
	exts : [3]string = {".ttf", ".otf", ".ttc"}
	candidate_buf : [512]u8
	for ext in exts {
		n := 0
		for c in SYSTEM_FONT_DIR {
			if n >= len(candidate_buf) - 8 {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		for c in path_or_name {
			if n >= len(candidate_buf) - 8 {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		for c in ext {
			if n >= len(candidate_buf) {
				break
			}
			candidate_buf[n] = byte(c)
			n += 1
		}
		candidate := string(candidate_buf[:n])
		if os.exists(candidate) {
			return strings.clone(candidate), true // 堆分配:栈缓冲出函数即失效
		}
	}
	// 系统目录里没有:显示名 → 注册表映射(如 "FiraCode Nerd Font Mono" → FiraCodeNerdFontMono-Regular.ttf)
	if p, ok := registryFontPath(path_or_name); ok {
		return p, true
	}
	// 都没有:原样返回(当作完整路径)
	return path_or_name, false
}

GetFont :: proc(h : mem.Handle) -> ^Font {
	return mem.Get(&fonts, h)
}

// 查询字号/路径(user API 改大小用;句柄无效返回 0/"")
FontSize :: proc(h : mem.Handle) -> f32 {
	font := GetFont(h)
	if font == nil {
		return 0
	}
	return font.size
}

FontPath :: proc(h : mem.Handle) -> string {
	font := GetFont(h)
	if font == nil {
		return ""
	}
	return font.path
}

// ---------------------------------------------------------------------------
// 字体度量:DWrite(Windows Terminal)兼容语义
// ---------------------------------------------------------------------------

u16be :: proc(data : []byte, off : int) -> u16 {
	return u16(data[off]) << 8 | u16(data[off + 1])
}
i16be :: proc(data : []byte, off : int) -> i16 {
	return i16(u16be(data, off))
}
u32be :: proc(data : []byte, off : int) -> u32 {
	return u32(data[off]) << 24 | u32(data[off + 1]) << 16 | u32(data[off + 2]) << 8 | u32(data[off + 3])
}

// sfnt 目录表定位(base = 目录起始,TTC 需 face 实际偏移)
sfntTableOffset :: proc(data : []byte, base : int, tag : string) -> int {
	n := int(u16be(data, base + 4))
	for i in 0 ..< n {
		rec := base + 12 + i * 16
		if string(data[rec:rec + 4]) == tag {
			return int(u32be(data, rec + 8))
		}
	}
	return -1
}

// OS/2 表可选度量(fsSelection bit7 = USE_TYPO_METRICS,见 OpenType spec)
OS2_USE_TYPO_METRICS :: 0x0080

// 与 DirectWrite IDWriteFontFace::GetMetrics 同语义(参考 Wine 的 dwrite 兼容实现):
//   1. fsSelection 置 USE_TYPO_METRICS 且 OS/2 v1+ → sTypoAscender/sTypoDescender/sTypoLineGap
//   2. 否则有 OS/2 → usWinAscent/usWinDescent(为全角/重音留白),lineGap 取 hhea
//   3. 无 OS/2 → hhea
// 返回设计单位;desc 归一为**正数**(hhea/typo 的 desc 是负 i16,DWrite 报正值)。
// 注意:lineGap **不参与格高**。WPF GlyphTypeface(DWrite 引擎)实测:
//   CascadiaCode/Mono 格高=2380 单位(1900+480),consola 格高=2398(usWin 1884+514),
//   lineGap(350)被忽略;基线=ascent 原值。DWrite 行高语义 = asc+desc。
faceMetrics :: proc(f : ^Face) -> (asc, desc, lg : f32) {
	a, d, l : c.int
	stbtt.GetFontVMetrics(&f.info, &a, &d, &l)
	asc, desc, lg = f32(a), f32(-d), 0
	os2 := sfntTableOffset(f.data, f.sfnt_off, "OS/2")
	if os2 < 0 {
		return
	}
	if u16be(f.data, os2) >= 1 {
		sel := u16be(f.data, os2 + 62)
		if sel & OS2_USE_TYPO_METRICS != 0 {
			asc = f32(i16be(f.data, os2 + 68))
			desc = f32(-i16be(f.data, os2 + 70))
			return
		}
	}
	asc = f32(u16be(f.data, os2 + 74))
	desc = f32(u16be(f.data, os2 + 76)) // usWin desc 本身为正
	return
}

// WT(AtlasEngine)公式:cell = round(advanceHeight);baseline = round(ascent + (lineGap + cell - advanceHeight)/2)
// advanceHeight = asc + desc + lg。字形位置由此唯一决定,不再做字形 box 居中。
cellAndBaseline :: proc(f : ^Face) -> (cell_h, baseline : f32) {
	asc, desc, lg := faceMetrics(f)
	s := f.scale
	adv_h := (asc + desc + lg) * s
	cell_h = math.round(adv_h)
	baseline = math.round(asc * s + (lg * s + cell_h - adv_h) * 0.5)
	return
}

// 系统字体目录(Windows)
SYSTEM_FONT_DIR :: "C:\\Windows\\Fonts\\"

// antialias:光栅化超采样倍数(1 = 整数网格,2 = 2x2 超采样)。
// 默认 1:oversample=2 的 subpixel 相位(-0.25)会让同一笔画在不同字形里
// 灰度分布不同(横线粗细/明暗不一);整数光栅化所有字形一致。
// 输入 path_or_name:优先当作字体名去系统目录找(`${SYSTEM_FONT_DIR}name.ttf/.otf/.ttc`),
// 找不到再当作完整路径加载。
// 去重:同 (path, size) 直接返回已有字体(字体全局共享,不重复加载/不随窗口销毁)。
LoadFont :: proc(path_or_name : string, size : f32, antialias : u8 = 1) -> (h : mem.Handle, ok : bool) {
	if size <= 0 {
		return {}, false
	}
	// 解析:先按系统字体名找,再按完整路径
	path, path_alloc := resolveFontPath(path_or_name)

	// 同 path+size 复用已加载的字体(跨窗口共享)
	for i in 1 ..< MAX_FONT_SLOTS {
		if mem.Alive(&fonts, i) && fonts.data[i].path == path && fonts.data[i].size == size {
			if path_alloc {
				delete(path) // 堆分配副本,未入字体则释放
			}
			return mem.Handle { id = u32(i), generation = fonts.generations[i] }, true
		}
	}
	font := Font { antialias = max(1, min(3, antialias)) }
	font.slots = make([dynamic]GlyphSlot, 64) // 哈希桶,装 0.75 后翻倍
	face, fok := faceLoad(path, size)
	if !fok {
		fmt.eprintln("LoadFont: faceLoad failed:", path, size)
		delete(font.slots)
		if path_alloc {
			delete(path)
		}
		return {}, false
	}
	font.faces[0] = face
	font.face_count = 1

	// 主字体无 CJK 字形 → 附系统中文字体
	if stbtt.FindGlyphIndex(&font.faces[0].info, '你') == 0 {
		// fallback 按主字体 em 像素尺寸对齐,保证同字号下汉字与拉丁字形等大。
		// 主字体 em 像素 = scale × unitsPerEm;unitsPerEm = 1 / ScaleForMappingEmToPixels(info, 1.0)
		main_em_px := font.faces[0].scale / stbtt.ScaleForMappingEmToPixels(&font.faces[0].info, 1.0)
		for fb_path in FALLBACK_FONTS {
			if fb, ffok := faceLoadFallback(fb_path, main_em_px); ffok {
				font.faces[1] = fb
				font.face_count = 2
				break
			}
		}
	}

	// 主字体 GSUB(连体规则);解析失败 = 无连体,ShapeLine 空转
	font.gsub = ParseGsub(font.faces[0].data)

	// 格子度量:与 WT(AtlasEngine)同公式——表选择(USW/TYPO)由 faceMetrics 决定,
	// cell = round((asc+desc+lg)*scale),baseline = round(asc*s + (lg*s + cell - advH)/2)。
	// 弃用字形 box 居中(与 WT 不一致,正是 consola 偏上根源)。
	f := &font.faces[0]
	cell_h, base := cellAndBaseline(f)
	font.cell_height = cell_h
	font.ascent = base
	advance : c.int
	stbtt.GetCodepointHMetrics(&f.info, 'M', &advance, nil)
	font.cell_width = math.ceil(f32(advance) * f.scale)

	atlasInit(&font.atlas)

	// 去重键:path_alloc 时所有权直接转移(不 clone),否则 clone
	// Font 生命周期与程序一致(不随窗口销毁)
	if path_alloc {
		font.path = path
	} else {
		font.path = strings.clone(path)
	}
	font.size = size

	h = mem.Alloc(&fonts, font)
	if h.id == 0 {
		fmt.eprintln("LoadFont: font table full:", path, size)
		fontFree(&font)
		return {}, false
	}
	return h, true
}

DestroyFont :: proc(h : mem.Handle) {
	font := GetFont(h)
	if font == nil {
		return
	}
	fontFree(font)
	mem.Free(&fonts, h)
}

// 字体表是否已满(再 Alloc 会失败)
FontTableFull :: proc() -> bool {
	return fonts.count >= MAX_FONT_SLOTS - 1
}

// 表满回收:按引用集(used)清掉第一个未被使用的字体槽;
// 全部在用返回 false。used 由调用方(引用者)扫描提供,font 包只认列表。
EvictUnused :: proc(used : []mem.Handle) -> bool {
	for i in 1 ..< MAX_FONT_SLOTS {
		if !mem.Alive(&fonts, i) {
			continue
		}
		h := mem.Handle { id = u32(i), generation = fonts.generations[i] }
		in_use := false
		for &u in used {
			if u == h {
				in_use = true
				break
			}
		}
		if !in_use {
			DestroyFont(h)
			return true
		}
	}
	return false
}

// 查字形:缓存命中直接返回;未命中则光栅化入图集。false = 所有 face 都无此字形
GetGlyph :: proc(h : mem.Handle, cp : rune) -> (Glyph, bool) {
	font := GetFont(h)
	if font == nil {
		return {}, false
	}
	if slot := slotFind(h, cp); slot != nil {
		return glyphFromSlot(slot), true
	}
	if !glyphRasterize(h, cp) {
		return {}, false
	}
	slot := slotFind(h, cp)
	if slot == nil {
		return {}, false
	}
	return glyphFromSlot(slot), true
}

GetMetrics :: proc(h : mem.Handle) -> Metrics {
	font := GetFont(h)
	if font == nil {
		return {}
	}
	return Metrics {
		cell_width = font.cell_width,
		cell_height = font.cell_height,
		ascent = font.ascent,
	}
}

// 按内部 glyph id 查字形(连体替换结果);缓存 + 主 face 光栅化
GetGlyphById :: proc(h : mem.Handle, gid : u16) -> (Glyph, bool) {
	font := GetFont(h)
	if font == nil {
		return {}, false
	}
	if slot := slotFindById(h, gid); slot != nil {
		return glyphFromSlot(slot), true
	}
	if !glyphRasterizeById(h, gid) {
		return {}, false
	}
	slot := slotFindById(h, gid)
	if slot == nil {
		return {}, false
	}
	return glyphFromSlot(slot), true
}

// 主字体 glyph id(连体输入);0 = 主字体无此字符(fallback 或不可渲染)
GlyphIndex :: proc(h : mem.Handle, cp : rune) -> u16 {
	font := GetFont(h)
	if font == nil {
		return 0
	}
	return u16(stbtt.FindGlyphIndex(&font.faces[0].info, cp))
}

// 对一行 glyph 序列逐 lookup 应用连体(原地修改;无 GSUB 时为空转)。
// 带缓存:输入序列哈希命中直接复制上次结果,跳过规则匹配。
// 无长度上限:超长行同样受益,行内普通字符(独立单位)由 ShapeGlyphs
// 的 active 预扫跳过,缓存只按行哈希区分。
ShapeLine :: proc(h : mem.Handle, glyphs : ^[dynamic]u16) {
	font := GetFont(h)
	if font == nil || len(font.gsub.lookup_order) == 0 {
		return
	}
	n := len(glyphs)
	hash := fnv1a(glyphs[:])
	for i in 0 ..< SHAPE_CACHE_SLOTS {
		slot := &font.shape_cache[i]
		if slot.hash == hash && int(slot.len) == n {
			resize(glyphs, int(slot.len))
			copy(glyphs[:], slot.glyphs[:])
			return
		}
	}
	// 未命中:shape 后入缓存(轮转覆盖)
	ShapeGlyphs(&font.gsub, glyphs)
	idx := int(font.shape_cache_next) % SHAPE_CACHE_SLOTS
	font.shape_cache_next += 1
	slot := &font.shape_cache[idx]
	clear(&slot.glyphs)
	append(&slot.glyphs, ..glyphs[:])
	slot.hash = hash
	slot.len = u16(len(glyphs))
}

fnv1a :: proc(glyphs : []u16) -> u64 {
	h : u64 = 14695981039346656037
	for g in glyphs {
		h = (h ~ u64(g)) * 1099511628211
	}
	return h
}

GetAtlasTexture :: proc(h : mem.Handle) -> u32 {
	font := GetFont(h)
	if font == nil {
		return 0
	}
	return font.atlas.texture
}

// ---------------------------------------------------------------------------
// face
// ---------------------------------------------------------------------------

faceLoad :: proc(path : string, size : f32) -> (Face, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	offset := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0) // ttc 取第 0 个
	face := Face { data = data, sfnt_off = int(offset) }
	if offset < 0 || !stbtt.InitFont(&face.info, cast([^]byte)raw_data(data), offset) {
		delete(data)
		return {}, false
	}
	face.scale = stbtt.ScaleForPixelHeight(&face.info, size)
	return face, true
}

// fallback 字体加载:按 em 尺寸对齐主字体(scale 传递)。
// 不能用 ScaleForPixelHeight(size):不同字体的 ascent-descent 不同,
// 同参数下雅黑(2703)比 Cascadia(2380)缩得更小 → 汉字偏小。
// 正确做法:fallback 的 em 像素尺寸 = 主字体 em 像素尺寸,两字体字形等大。
faceLoadFallback :: proc(path : string, main_em_px : f32) -> (Face, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	offset := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	face := Face { data = data, sfnt_off = int(offset) }
	if offset < 0 || !stbtt.InitFont(&face.info, cast([^]byte)raw_data(data), offset) {
		delete(data)
		return {}, false
	}
	// ScaleForMappingEmToPixels(info, em_px) = 使 em 盒映射到 em_px 像素的 scale
	face.scale = stbtt.ScaleForMappingEmToPixels(&face.info, main_em_px)
	return face, true
}

// 释放 Font 值持有的资源(槽位释放与创建失败回滚共用)
fontFree :: proc(font : ^Font) {
	DestroyGsub(&font.gsub)
	for &slot in font.shape_cache {
		delete(slot.glyphs)
	}
	for i in 0 ..< int(font.face_count) {
		delete(font.faces[i].data)
	}
	delete(font.slots)
	delete(font.atlas.pixels)
	delete(font.path)
	gl.DeleteTextures(1, &font.atlas.texture)
}

// ---------------------------------------------------------------------------
// 缓存槽(开放寻址,线性探测)
// ---------------------------------------------------------------------------

slotFind :: proc(font_h : mem.Handle, cp : rune) -> ^GlyphSlot {
	font := GetFont(font_h)
	if font == nil {
		return nil
	}
	cap := len(font.slots)
	if cap == 0 {
		return nil
	}
	i := int(uint(cp) % uint(cap))
	for {
		slot := &font.slots[i]
		if slot.cp == cp && slot.gid == 0 {
			return slot
		}
		if slot.cp == 0 && slot.gid == 0 {
			return nil // 空槽终止探测
		}
		i = (i + 1) % cap
	}
}

slotFindById :: proc(font_h : mem.Handle, gid : u16) -> ^GlyphSlot {
	font := GetFont(font_h)
	if font == nil {
		return nil
	}
	cap := len(font.slots)
	if cap == 0 {
		return nil
	}
	i := int(uint(gid) % uint(cap))
	for {
		slot := &font.slots[i]
		if slot.gid == gid {
			return slot
		}
		if slot.cp == 0 && slot.gid == 0 {
			return nil // 空槽终止探测
		}
		i = (i + 1) % cap
	}
}

slotInsert :: proc(font_h : mem.Handle, slot : GlyphSlot) -> bool {
	font := GetFont(font_h)
	if font == nil || len(font.slots) == 0 {
		return false
	}
	if int(font.slot_count) + 1 > int(f32(len(font.slots)) * SLOT_LOAD_FACTOR) {
		if !slotGrow(font_h) {
			return false
		}
	}
	key := uint(slot.cp) if slot.cp != 0 else uint(slot.gid)
	i := int(key % uint(len(font.slots)))
	for {
		s := &font.slots[i]
		if s.cp == 0 && s.gid == 0 {
			s^ = slot
			font.slot_count += 1
			return true
		}
		i = (i + 1) % len(font.slots)
	}
}

slotGrow :: proc(font_h : mem.Handle) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	old := font.slots
	font.slots = make([dynamic]GlyphSlot, len(old) * 2)
	font.slot_count = 0
	for slot in old {
		if slot.cp == 0 && slot.gid == 0 {
			continue
		}
		key := uint(slot.cp) if slot.cp != 0 else uint(slot.gid)
		i := int(key % uint(len(font.slots)))
		for {
			s := &font.slots[i]
			if s.cp == 0 && s.gid == 0 {
				s^ = slot
				font.slot_count += 1
				break
			}
			i = (i + 1) % len(font.slots)
		}
	}
	delete(old)
	return true
}

glyphFromSlot :: proc(slot : ^GlyphSlot) -> Glyph {
	// slot.xoff/yoff = stbtt box 偏移(x0/y0,相对字形原点);
	// UV 已指向图集内容区,quad 只画内容区
	return Glyph {
		advance = slot.advance,
		bitmap_w = f32(slot.w),
		bitmap_h = f32(slot.h),
		xoff = slot.xoff,
		yoff = slot.yoff,
		uv0_x = slot.u0, uv0_y = slot.v0, uv1_x = slot.u1, uv1_y = slot.v1,
	}
}

// ---------------------------------------------------------------------------
// 光栅化
// ---------------------------------------------------------------------------

// 选 face:主字体无此字形(notdef)则 fallback
glyphFaceIndex :: proc(font_h : mem.Handle, cp : rune) -> (index : int, ok : bool) {
	font := GetFont(font_h)
	if font == nil {
		return 0, false
	}
	for i in 0 ..< int(font.face_count) {
		if stbtt.FindGlyphIndex(&font.faces[i].info, cp) != 0 {
			return i, true
		}
	}
	return 0, false
}

// 光栅化公共:1x 分辨率,stbtt 解析覆盖率抗锯齿(每像素按字形覆盖面积算灰度,
// 无需超采样)。oversample=1:不用 subpixel prefilter,避免其相位让同一笔画
// 在不同字形里灰度分布不同(横线粗细/明暗不一,FreeType 靠 hinting 才一致)。
rasterCommon :: proc(font_h : mem.Handle, face : ^Face, cp : rune, gid : c.int) -> (GlyphSlot, bool) {
	font := GetFont(font_h)
	if font == nil {
		return {}, false
	}
	scale := face.scale

	x0, y0, x1, y1 : c.int
	if gid != 0 {
		stbtt.GetGlyphBitmapBox(&face.info, gid, scale, scale, &x0, &y0, &x1, &y1)
	} else {
		stbtt.GetCodepointBitmapBox(&face.info, cp, scale, scale, &x0, &y0, &x1, &y1)
	}
	w := x1 - x0
	h := y1 - y0
	if w == 0 || h == 0 {
		return {}, false // 空白字形(空格等):不入图集
	}
	advance : c.int
	if gid != 0 {
		stbtt.GetGlyphHMetrics(&face.info, gid, &advance, nil)
	} else {
		stbtt.GetCodepointHMetrics(&face.info, cp, &advance, nil)
	}

	x, y, alloc_ok := atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
	if !alloc_ok {
		atlasGrow(font_h) // 图集满 → 扩容并重放全部缓存字形
		x, y, alloc_ok = atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
		if !alloc_ok {
			return {}, false
		}
	}
	// 位图直接画入图集 buffer(带 pad);oversample=1(覆盖率抗锯齿已平滑)
	sub_x, sub_y : f32
	row_start := int(y + ATLAS_PAD) * int(font.atlas.width) + int(x + ATLAS_PAD)
	if gid != 0 {
		stbtt.MakeGlyphBitmapSubpixelPrefilter(&face.info, cast([^]byte)&font.atlas.pixels[row_start], w, h, c.int(font.atlas.width), scale, scale, 0, 0, 1, 1, &sub_x, &sub_y, gid)
	} else {
		stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&font.atlas.pixels[row_start], w, h, c.int(font.atlas.width), scale, scale, 0, 0, true, true, &sub_x, &sub_y, cp)
	}
	atlasUpload(&font.atlas, x, y, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)

	return GlyphSlot {
		w = u16(w), h = u16(h),
		xoff = f32(x0) + sub_x, yoff = f32(y0) + sub_y,
		advance = f32(advance) * scale,
		u0 = f32(x + ATLAS_PAD) / f32(font.atlas.width),
		v0 = f32(y + ATLAS_PAD) / f32(font.atlas.height),
		u1 = f32(x + ATLAS_PAD + u32(w)) / f32(font.atlas.width),
		v1 = f32(y + ATLAS_PAD + u32(h)) / f32(font.atlas.height),
	}, true
}

glyphRasterize :: proc(font_h : mem.Handle, cp : rune) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	face_idx, fok := glyphFaceIndex(font_h, cp)
	if !fok {
		return false
	}
	slot, sok := rasterCommon(font_h, &font.faces[face_idx], cp, 0)
	if !sok {
		return false
	}
	slot.cp = cp
	slot.face_index = u8(face_idx)
	return slotInsert(font_h, slot)
}

// 按内部 glyph id 光栅化(连体字形,只属于主 face)
glyphRasterizeById :: proc(font_h : mem.Handle, gid : u16) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	slot, sok := rasterCommon(font_h, &font.faces[0], 0, c.int(gid))
	if !sok {
		return false
	}
	slot.gid = gid
	slot.face_index = 0
	return slotInsert(font_h, slot)
}

// ---------------------------------------------------------------------------
// 图集
// ---------------------------------------------------------------------------

atlasInit :: proc(a : ^Atlas) {
	a.width, a.height = ATLAS_START, ATLAS_START
	a.pixels = make([]u8, a.width * a.height)
	gl.GenTextures(1, &a.texture)
	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, i32(a.width), i32(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels))
}

atlasUpload :: proc(a : ^Atlas, x, y, w, h : u32) {
	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	offset := int(y) * int(a.width) + int(x)
	// 行距 = 图集宽度:子区域在 pixels 里按整行 1024 打包,GL 默认按 w 紧密打包,须显式声明
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, i32(a.width))
	gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(x), i32(y), i32(w), i32(h), gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels[offset:]))
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
}

// 行式分配:当前行放不下则换行,图集放不下返回 false
atlasAlloc :: proc(a : ^Atlas, w, h : u32) -> (x, y : u32, ok : bool) {
	if w > a.width || h > a.height {
		return 0, 0, false
	}
	if a.cur_x + w > a.width {
		a.cur_x = 0
		a.cur_y += a.row_height
		a.row_height = 0
	}
	if a.cur_y + h > a.height {
		return 0, 0, false
	}
	x, y = a.cur_x, a.cur_y
	a.cur_x += w
	a.row_height = max(a.row_height, h)
	return x, y, true
}

// 图集满:尺寸翻倍,重画全部已缓存字形(一次性冷启动成本)
atlasGrow :: proc(font_h : mem.Handle) {
	font := GetFont(font_h)
	if font == nil {
		return
	}
	a := &font.atlas
	if a.width >= ATLAS_MAX {
		return // 到上限,分配失败由上层接受
	}
	new_w, new_h := a.width * 2, a.height * 2
	old := a.pixels
	a.pixels = make([]u8, new_w * new_h) // 全 0
	a.width, a.height = new_w, new_h
	a.cur_x, a.cur_y, a.row_height = 0, 0, 0

	gl.BindTexture(gl.TEXTURE_2D, a.texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, i32(a.width), i32(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, nil)

	for i in 0 ..< len(font.slots) {
		slot := &font.slots[i]
		if slot.cp == 0 && slot.gid == 0 {
			continue
		}
		face := &font.faces[slot.face_index]
		x, y, ok := atlasAlloc(a, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
		if !ok {
			break // 翻倍后仍有空间,分配失败即后续全失败
		}
		row_start := int(y + ATLAS_PAD) * int(a.width) + int(x + ATLAS_PAD)
		sub_x, sub_y : f32
		if slot.gid != 0 {
			stbtt.MakeGlyphBitmapSubpixelPrefilter(&face.info, cast([^]byte)&a.pixels[row_start], c.int(slot.w), c.int(slot.h), c.int(a.width), face.scale, face.scale, 0, 0, 1, 1, &sub_x, &sub_y, c.int(slot.gid))
		} else {
			stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&a.pixels[row_start], c.int(slot.w), c.int(slot.h), c.int(a.width), face.scale, face.scale, 0, 0, true, true, &sub_x, &sub_y, slot.cp)
		}
		slot.u0 = f32(x + ATLAS_PAD) / f32(a.width)
		slot.v0 = f32(y + ATLAS_PAD) / f32(a.height)
		slot.u1 = f32(x + ATLAS_PAD + u32(slot.w)) / f32(a.width)
		slot.v1 = f32(y + ATLAS_PAD + u32(slot.h)) / f32(a.height)
		atlasUpload(a, x, y, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
	}
	delete(old)
}
