// 字体系统:rune → 可渲染字形(灰度位图入 GL 图集 + 度量)。
// 对外 5 个函数:LoadFont / DestroyFont / GetGlyph / GetMetrics / GetAtlasTexture。
// 懒光栅化:字形首次用到才 stbtt 渲染,入图集缓存;主字体缺字自动走中文 fallback(同一图集)。
// 槽位数组 + id 句柄:count 从 1 起,id 0 = 空;跨层一律传 Handle,GetFont(h) 拿指针。
package font

import stbtt "vendor:stb/truetype"
import gl "vendor:OpenGL"
import "core:c"
import "core:os"
import "core:math"
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

MAX_FONT_SLOTS :: 8
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

GetFont :: proc(h : mem.Handle) -> ^Font {
	return mem.Get(&fonts, h)
}

// antialias:光栅化超采样倍数(1 = 整数网格,2 = 2x2 超采样)。
// 默认 1:oversample=2 的 subpixel 相位(-0.25)会让同一笔画在不同字形里
// 灰度分布不同(横线粗细/明暗不一);整数光栅化所有字形一致。
LoadFont :: proc(path : string, size : f32, antialias : u8 = 1) -> (h : mem.Handle, ok : bool) {
	if size <= 0 {
		return {}, false
	}
	font := Font { antialias = max(1, min(3, antialias)) }
	font.slots = make([dynamic]GlyphSlot, 64) // 哈希桶,装 0.75 后翻倍
	face, fok := faceLoad(path, size)
	if !fok {
		delete(font.slots)
		return {}, false
	}
	font.faces[0] = face
	font.face_count = 1

	// 主字体无 CJK 字形 → 附系统中文字体
	if stbtt.FindGlyphIndex(&font.faces[0].info, '你') == 0 {
		for fb_path in FALLBACK_FONTS {
			if fb, ffok := faceLoad(fb_path, size); ffok {
				font.faces[1] = fb
				font.face_count = 2
				break
			}
		}
	}

	// 主字体 GSUB(连体规则);解析失败 = 无连体,ShapeLine 空转
	font.gsub = ParseGsub(font.faces[0].data)

	// 格子度量:同字号下各 face 同 scale,取主 face
	f := &font.faces[0]
	ascent, descent, line_gap : c.int
	stbtt.GetFontVMetrics(&f.info, &ascent, &descent, &line_gap)
	font.cell_height = math.ceil((f32(ascent) - f32(descent) + f32(line_gap)) * f.scale)
	font.ascent = f32(ascent) * f.scale
	advance : c.int
	stbtt.GetCodepointHMetrics(&f.info, 'M', &advance, nil)
	font.cell_width = math.ceil(f32(advance) * f.scale)

	atlasInit(&font.atlas)

	h = mem.Alloc(&fonts, font)
	if h.id == 0 {
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
	face := Face { data = data }
	offset := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0) // ttc 取第 0 个
	if offset < 0 || !stbtt.InitFont(&face.info, cast([^]byte)raw_data(data), offset) {
		delete(data)
		return {}, false
	}
	face.scale = stbtt.ScaleForPixelHeight(&face.info, size)
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
