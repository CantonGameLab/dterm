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
	cp : rune, // 0 = 空槽
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

Font :: struct {
	faces : [MAX_FACES]Face,
	face_count : u32,
	antialias : u8, // 光栅化超采样倍数 1-3;相对静止,LoadFont 时一次设定
	cell_width, cell_height : f32,
	ascent : f32,
	slots : [dynamic]GlyphSlot,
	slot_count : u32,
	atlas : Atlas,
}

fonts : mem.GenArray(MAX_FONT_SLOTS, Font)

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

GetFont :: proc(h : mem.Handle) -> ^Font {
	return mem.Get(&fonts, h)
}

// antialias:光栅化超采样倍数(1 = 关,2 = 2x2 超采样);相对静止,启动时一次设定
LoadFont :: proc(path : string, size : f32, antialias : u8 = 2) -> (h : mem.Handle, ok : bool) {
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
	if GetFont(h) == nil {
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
		if slot.cp == cp {
			return slot
		}
		if slot.cp == 0 {
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
	i := int(uint(slot.cp) % uint(len(font.slots)))
	for {
		s := &font.slots[i]
		if s.cp == 0 {
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
		if slot.cp == 0 {
			continue
		}
		i := int(uint(slot.cp) % uint(len(font.slots)))
		for {
			s := &font.slots[i]
			if s.cp == 0 {
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
	return Glyph {
		advance = slot.advance,
		bitmap_w = f32(slot.w),
		bitmap_h = f32(slot.h),
		xoff = slot.xoff - ATLAS_PAD, // 位图内容区在 quad 里的位置 = 像素偏移 - 边距
		yoff = slot.yoff - ATLAS_PAD,
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

glyphRasterize :: proc(font_h : mem.Handle, cp : rune) -> bool {
	font := GetFont(font_h)
	if font == nil {
		return false
	}
	face_idx, ok := glyphFaceIndex(font_h, cp)
	if !ok {
		return false
	}
	face := &font.faces[face_idx]

	x0, y0, x1, y1 : c.int
	stbtt.GetCodepointBitmapBox(&face.info, cp, face.scale, face.scale, &x0, &y0, &x1, &y1)
	w := x1 - x0
	h := y1 - y0
	if w == 0 || h == 0 {
		return false // 空白字形(空格等):不入图集,渲染层跳过
	}
	advance : c.int
	stbtt.GetCodepointHMetrics(&face.info, cp, &advance, nil)

	x, y, alloc_ok := atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
	if !alloc_ok {
		atlasGrow(font_h) // 图集满 → 扩容并重放全部缓存字形
		x, y, alloc_ok = atlasAlloc(&font.atlas, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)
		if !alloc_ok {
			return false
		}
	}
	// 位图直接画入图集 buffer(带 pad),零中间拷贝;超采样抗锯齿 + 亚像素偏移对齐像素边界
	sub_x, sub_y : f32
	row_start := int(y + ATLAS_PAD) * int(font.atlas.width) + int(x + ATLAS_PAD)
	stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&font.atlas.pixels[row_start], w, h, c.int(font.atlas.width), face.scale, face.scale, 0, 0, b32(font.antialias), b32(font.antialias), &sub_x, &sub_y, cp)
	atlasUpload(&font.atlas, x, y, u32(w) + 2 * ATLAS_PAD, u32(h) + 2 * ATLAS_PAD)

	return slotInsert(font_h, GlyphSlot {
		cp = cp,
		face_index = u8(face_idx),
		w = u16(w), h = u16(h),
		xoff = f32(x0) + sub_x, yoff = f32(y0) + sub_y,
		advance = f32(advance) * face.scale,
		u0 = f32(x + ATLAS_PAD) / f32(font.atlas.width),
		v0 = f32(y + ATLAS_PAD) / f32(font.atlas.height),
		u1 = f32(x + ATLAS_PAD + u32(w)) / f32(font.atlas.width),
		v1 = f32(y + ATLAS_PAD + u32(h)) / f32(font.atlas.height),
	})
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
		if slot.cp == 0 {
			continue
		}
		face := &font.faces[slot.face_index]
		x, y, ok := atlasAlloc(a, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
		if !ok {
			break // 翻倍后仍有空间,分配失败即后续全失败
		}
		row_start := int(y + ATLAS_PAD) * int(a.width) + int(x + ATLAS_PAD)
		sub_x, sub_y : f32
		stbtt.MakeCodepointBitmapSubpixelPrefilter(&face.info, cast([^]byte)&a.pixels[row_start], c.int(slot.w), c.int(slot.h), c.int(a.width), face.scale, face.scale, 0, 0, b32(font.antialias), b32(font.antialias), &sub_x, &sub_y, slot.cp)
		slot.u0 = f32(x + ATLAS_PAD) / f32(a.width)
		slot.v0 = f32(y + ATLAS_PAD) / f32(a.height)
		slot.u1 = f32(x + ATLAS_PAD + u32(slot.w)) / f32(a.width)
		slot.v1 = f32(y + ATLAS_PAD + u32(slot.h)) / f32(a.height)
		atlasUpload(a, x, y, u32(slot.w) + 2 * ATLAS_PAD, u32(slot.h) + 2 * ATLAS_PAD)
	}
	delete(old)
}
