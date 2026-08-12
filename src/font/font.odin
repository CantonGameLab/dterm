// 字体模块:stb/truetype 光栅化 + 图集管理。
// LoadFont(path, size) 创建/复用实例;GetGlyph 惰性光栅化;
// 命中磁盘缓存(cache/fonts/)时零光栅化。需 GL 上下文就绪后调用。
package font

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

Glyph :: struct {
	codepoint:   rune,
	glyph_index: c.int,

	u0, v0, u1, v1: f32, // 图集 UV(0..1,直接采样)
	x0, y0, x1, y1: f32, // 图集内像素矩形(含 1px padding)
	bearing_x, bearing_y: f32, // 位图相对笔位置的偏移(像素,Y 向下)
	width, height: f32,
	advance: f32,

	empty: bool, // 无位图内容,仅 advance 有效
	batch: u32, // 打包批次号(磁盘缓存重放用)
}

Metrics :: struct {
	ascent:      f32,
	descent:     f32,
	line_gap:    f32,
	line_height: f32, // ascent - descent + line_gap
	scale:       f32,
}

Font :: struct {
	path:       string,
	size:       f32,
	cache_key:  u64,
	from_cache: bool, // 本次命中磁盘缓存

	data: []byte, // 文件缓存,不拥有
	info: stbtt.fontinfo,
	metrics: Metrics,

	atlas: Atlas,
	glyphs: map[rune]Glyph,
	pack_order: [dynamic]rune, // 打包顺序(磁盘缓存重放依据)
	next_batch: u32,
	dirty: bool, // 有新增字形尚未写盘
	ref_count: int,
}

font_registry: map[string]^Font

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

// 创建或复用实例;nil = 字体文件无法读取/解析
LoadFont :: proc(path: string, size: f32) -> ^Font {
	if size <= 0 {
		return nil
	}
	abs := path
	if a, err := os.get_absolute_path(path, context.allocator); err == nil {
		abs = a
	}
	key := fontKey(abs, size)
	if f, ok := font_registry[key]; ok {
		f.ref_count += 1
		return f
	}

	f := new(Font)
	f.path = strings.clone(abs)
	f.size = size

	data, ok := GetFontData(abs)
	if !ok || len(data) == 0 {
		delete(f.path)
		free(f)
		return nil
	}
	f.data = data
	// TTC 集合字体(如 msyh.ttc)需先取第一个字体的真实偏移
	offset := stbtt.GetFontOffsetForIndex(raw_data(f.data), 0)
	if offset < 0 || !stbtt.InitFont(&f.info, raw_data(f.data), offset) {
		delete(f.path)
		free(f)
		return nil
	}

	ascent, descent, line_gap: c.int
	stbtt.GetFontVMetrics(&f.info, &ascent, &descent, &line_gap)
	scale := stbtt.ScaleForPixelHeight(&f.info, size)
	f.metrics = Metrics {
		ascent      = f32(ascent) * scale,
		descent     = f32(descent) * scale,
		line_gap    = f32(line_gap) * scale,
		line_height = (f32(ascent) - f32(descent) + f32(line_gap)) * scale,
		scale       = scale,
	}

	// 文件指纹 -> 缓存 key(字体文件变更后自动失效)
	if info, err := os.stat(abs, context.allocator); err == nil {
		f.cache_key = CacheKeyOf(f, info.size, info.modification_time)
	}

	if !TryLoadDiskCache(f) {
		if !atlasCreate(f, ATLAS_INITIAL_SIZE, ATLAS_INITIAL_SIZE) {
			delete(f.path)
			free(f)
			return nil
		}
		f.glyphs = make(map[rune]Glyph)
	}

	font_registry[key] = f
	return f
}

// 同一实例被 LoadFont 多次引用时需对应多次调用;dirty 时自动写磁盘缓存
DestroyFont :: proc(font: ^Font) {
	if font == nil {
		return
	}
	font.ref_count -= 1
	if font.ref_count > 0 {
		return
	}
	SaveCache(font)
	atlasDestroy(&font.atlas)
	delete(font.glyphs)
	delete(font.pack_order)
	delete_key(&font_registry, fontKey(font.path, font.size))
	delete(font.path)
	free(font)
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------

// 惰性光栅化进图集;ok == false = 字体不含此字符
GetGlyph :: proc(font: ^Font, cp: rune) -> (Glyph, bool) {
	if g, ok := font.glyphs[cp]; ok {
		return g, true
	}
	return rasterizeOne(font, cp)
}

GetMetrics :: proc(font: ^Font) -> Metrics {
	return font.metrics
}

GetAtlasTexture :: proc(font: ^Font) -> u32 {
	return font.atlas.texture_id
}

// ---------------------------------------------------------------------------
// 预烘培 / 缓存
// ---------------------------------------------------------------------------

PRELOAD_CHUNK :: 512

// 预烘培 [first, last] 内字体存在的字符;图集满时自动扩容
PreloadRange :: proc(font: ^Font, first, last: rune) {
	if font == nil || first > last {
		return
	}
	chars: [dynamic]rune
	defer delete(chars)
	for cp := first; cp <= last; cp += 1 {
		if _, exists := font.glyphs[cp]; exists {
			continue
		}
		if stbtt.FindGlyphIndex(&font.info, cp) != 0 {
			append(&chars, cp)
		}
	}

	chunk: [dynamic]rune
	defer delete(chunk)
	for i := 0; i < len(chars); i += 1 {
		append(&chunk, chars[i])
		if len(chunk) >= PRELOAD_CHUNK {
			if !rasterizeRange(font, chunk[:]) {
				return
			}
			clear(&chunk)
		}
	}
	if len(chunk) > 0 {
		rasterizeRange(font, chunk[:])
	}
}

SaveCache :: proc(font: ^Font) -> bool {
	return SaveFontCache(font)
}

// ---------------------------------------------------------------------------
// 内部:光栅化
// ---------------------------------------------------------------------------

rasterizeOne :: proc(f: ^Font, cp: rune) -> (Glyph, bool) {
	gi := stbtt.FindGlyphIndex(&f.info, cp)
	if gi == 0 {
		return {}, false
	}
	pc: stbtt.packedchar
	for {
		if stbtt.PackFontRange(&f.atlas.ctx, raw_data(f.data), 0, f.size, c.int(cp), 1, &pc) {
			break
		}
		if !atlasGrow(f) {
			return {}, false
		}
	}
	g := glyphFromPackedchar(f, cp, gi, pc, f.next_batch)
	if !g.empty {
		atlasUploadRect(&f.atlas, u32(pc.x0), u32(pc.y0), u32(pc.x1) - u32(pc.x0), u32(pc.y1) - u32(pc.y0))
	}
	f.glyphs[cp] = g
	append(&f.pack_order, cp)
	f.next_batch += 1
	f.dirty = true
	return g, true
}

rasterizeRange :: proc(f: ^Font, cps: []rune) -> bool {
	if len(cps) == 0 {
		return true
	}
	chardata := make([]stbtt.packedchar, len(cps))
	defer delete(chardata)
	range_ := stbtt.pack_range {
		font_size                        = f.size,
		first_unicode_codepoint_in_range = c.int(cps[0]),
		array_of_unicode_codepoints      = raw_data(cps),
		num_chars                        = c.int(len(cps)),
		chardata_for_range               = raw_data(chardata),
	}
	for {
		if stbtt.PackFontRanges(&f.atlas.ctx, raw_data(f.data), 0, &range_, 1) {
			break
		}
		if !atlasGrow(f) {
			return false
		}
	}
	batch := f.next_batch
	for cp, i in cps {
		gi := stbtt.FindGlyphIndex(&f.info, cp)
		g := glyphFromPackedchar(f, cp, gi, chardata[i], batch)
		if !g.empty {
			pc := chardata[i]
			atlasUploadRect(&f.atlas, u32(pc.x0), u32(pc.y0), u32(pc.x1) - u32(pc.x0), u32(pc.y1) - u32(pc.y0))
		}
		f.glyphs[cp] = g
		append(&f.pack_order, cp)
	}
	f.next_batch += 1
	f.dirty = true
	return true
}

glyphFromPackedchar :: proc(f: ^Font, cp: rune, gi: c.int, pc: stbtt.packedchar, batch: u32) -> Glyph {
	quad: stbtt.aligned_quad
	xpos, ypos: f32
	pc_local := pc
	stbtt.GetPackedQuad(&pc_local, c.int(f.atlas.width), c.int(f.atlas.height), 0, &xpos, &ypos, &quad, false)
	g := Glyph {
		codepoint   = cp,
		glyph_index = gi,
		u0          = quad.s0,
		v0          = quad.t0,
		u1          = quad.s1,
		v1          = quad.t1,
		x0          = f32(pc.x0),
		y0          = f32(pc.y0),
		x1          = f32(pc.x1),
		y1          = f32(pc.y1),
		bearing_x   = quad.x0,
		bearing_y   = quad.y0,
		width       = quad.x1 - quad.x0,
		height      = quad.y1 - quad.y0,
		advance     = pc.xadvance,
		batch       = batch,
	}
	g.empty = g.width == 0 || g.height == 0
	return g
}

fontKey :: proc(path: string, size: f32) -> string {
	return fmt.tprintf("%s\x00%g", path, size)
}
