// 字体模块：基于 vendor:stb/truetype 的字体光栅化与图集管理。
//
// 用法概览：
//   1. load_font(path, size)  —— 指定字体文件路径 + 采样像素高度，创建字体实例。
//      - 字体文件字节走进程内缓存（同一路径只读一次磁盘，见 cache.odin）。
//      - 若磁盘缓存命中（cache/fonts/ 下已有同 (路径, 尺寸, 文件指纹) 的光栅化结果），
//        直接加载图集像素与字形表，零光栅化开销（font.from_cache == true）。
//   2. get_glyph(font, cp)    —— 查询某个字符的字形信息（UV 坐标、位图尺寸、偏移、前进量）。
//      - 未光栅化过的字符会被惰性打包进图集纹理并上传 GPU。
//   3. 渲染时绑定 get_atlas_texture(font) 返回的纹理，用 Glyph 里的
//      u0,v0,u1,v1 作为 UV 采样，按 bearing/width/height 摆放 quad，advance 推进笔位置。
//   4. destroy_font(font)     —— 若期间有新增字形，自动把光栅化结果写入磁盘缓存。
//
// 注意：本模块会创建 OpenGL 纹理（单通道 R8），必须在 GL 上下文就绪后调用
// （即 render.renderInit() 之后）。
package font

import stbtt "vendor:stb/truetype"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// Glyph 是调用方拿到的字形信息。
// 渲染时直接使用 UV 与度量字段，不涉及任何 stbtt 调用。
Glyph :: struct {
	codepoint:   rune,
	glyph_index: c.int, // stbtt 字形索引（供 kerning 等扩展使用）

	// 图集 UV 坐标（0..1，直接采样）
	u0, v0, u1, v1: f32,
	// 图集内像素矩形（含 1px 左侧/上侧 padding）
	x0, y0, x1, y1: f32,
	// 位图左上角相对笔位置的偏移（像素，Y 向下）
	bearing_x, bearing_y: f32,
	// 位图尺寸（像素）
	width, height: f32,
	// 水平前进量（下一个字符的笔位置偏移）
	advance: f32,

	// 空字形（空格/零宽字符）：无位图内容，仅 advance 有效
	empty: bool,
	// 打包批次号（内部：磁盘缓存重放布局用）
	batch: u32,
}

// Metrics 是字体度量（已按采样尺寸缩放）。
Metrics :: struct {
	ascent:      f32, // 基线以上高度
	descent:     f32, // 基线以下深度（负数）
	line_gap:    f32,
	line_height: f32, // ascent - descent + line_gap
	scale:       f32, // 字体单位 -> 像素 的缩放
}

// Font 是一个 (字体路径, 采样尺寸) 实例。
Font :: struct {
	path:       string, // 绝对路径（模块克隆持有）
	size:       f32,    // 采样像素高度
	cache_key:  u64,    // 磁盘缓存 key（路径+尺寸+文件指纹）
	from_cache: bool,   // 本次加载是否命中磁盘缓存

	data: []byte,       // 字体文件字节（来自文件缓存，不拥有）
	info: stbtt.fontinfo,
	metrics: Metrics,

	atlas: Atlas,
	glyphs: map[rune]Glyph,     // 已光栅化字形表
	pack_order: [dynamic]rune,  // 打包顺序（磁盘缓存重放依据）
	next_batch: u32,            // 下一个批次号
	dirty: bool,                // 有新增字形尚未写盘
	ref_count: int,
}

// font_registry 按 (路径, 尺寸) 复用实例
font_registry: map[string]^Font

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

// load_font 创建（或复用）一个字体实例。
// 返回 nil 表示字体文件无法读取或解析失败。
loadFont :: proc(path: string, size: f32) -> ^Font {
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

	data, ok := get_font_data(abs)
	if !ok || len(data) == 0 {
		delete(f.path)
		free(f)
		return nil
	}
	f.data = data
	// TTC 集合字体（如 msyh.ttc）需要先取第一个字体的真实偏移
	offset := stbtt.GetFontOffsetForIndex(raw_data(f.data), 0)
	if offset < 0 || !stbtt.InitFont(&f.info, raw_data(f.data), offset) {
		delete(f.path)
		free(f)
		return nil
	}

	// 度量（按采样尺寸缩放）
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

	// 文件指纹 -> 磁盘缓存 key（字体文件变更后自动失效）
	if info, err := os.stat(abs, context.allocator); err == nil {
		f.cache_key = cache_key_of(f, info.size, info.modification_time)
	}

	// 磁盘缓存 -> 否则全新图集
	if !try_load_disk_cache(f) {
		if !atlas_create(f, ATLAS_INITIAL_SIZE, ATLAS_INITIAL_SIZE) {
			delete(f.path)
			free(f)
			return nil
		}
		f.glyphs = make(map[rune]Glyph)
	}

	font_registry[key] = f
	return f
}

// destroy_font 释放字体实例。
// 期间若有新增字形（dirty），会自动写入磁盘缓存。
// 同一实例被 load_font 多次引用时需对应多次调用。
destroyFont :: proc(font: ^Font) {
	if font == nil {
		return
	}
	font.ref_count -= 1
	if font.ref_count > 0 {
		return
	}
	saveCache(font)
	atlas_destroy(&font.atlas)
	delete(font.glyphs)
	delete(font.pack_order)
	delete_key(&font_registry, fontKey(font.path, font.size))
	delete(font.path)
	free(font)
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------

// get_glyph 查询字符的字形信息。
// 未光栅化过的字符会被惰性打包进图集并上传 GPU。
// ok == false 表示该字体不含此字符（例如中文字体查询西文缺失字形）。
getGlyph :: proc(font: ^Font, cp: rune) -> (Glyph, bool) {
	if g, ok := font.glyphs[cp]; ok {
		return g, true
	}
	return rasterizeOne(font, cp)
}

getMetrics :: proc(font: ^Font) -> Metrics {
	return font.metrics
}

// get_atlas_texture 返回图集 GL 纹理 ID（渲染时绑定到采样单元）。
getAtlasTexture :: proc(font: ^Font) -> u32 {
	return font.atlas.texture_id
}

// ---------------------------------------------------------------------------
// 预烘培 / 缓存
// ---------------------------------------------------------------------------

// preload_range 一次性把 [first, last] 内字体存在的字符全部光栅化进图集，
// 按 512 字符分块打包，图集满时自动扩容。用于启动时预烘培常用区间
// （如 ASCII 0x20..0x7E、常用 CJK），避免运行期滚动掉帧。
PRELOAD_CHUNK :: 512

preloadRange :: proc(font: ^Font, first, last: rune) {
	if font == nil || first > last {
		return
	}
	// 过滤掉已光栅化（含磁盘缓存加载）以及字体中不存在的字符
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

// save_cache 把当前图集与字形表写入磁盘缓存（cache/fonts/）。
// destroy_font 会自动调用；也可手动调用以便下次启动秒加载。
saveCache :: proc(font: ^Font) -> bool {
	return save_font_cache(font)
}

// ---------------------------------------------------------------------------
// 内部：光栅化
// ---------------------------------------------------------------------------

// rasterize_one 光栅化单个字符（一个打包批次）。
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
		if !atlas_grow(f) {
			return {}, false
		}
	}
	g := glyphFromPackedchar(f, cp, gi, pc, f.next_batch)
	if !g.empty {
		atlas_upload_rect(&f.atlas, u32(pc.x0), u32(pc.y0), u32(pc.x1) - u32(pc.x0), u32(pc.y1) - u32(pc.y0))
	}
	f.glyphs[cp] = g
	append(&f.pack_order, cp)
	f.next_batch += 1
	f.dirty = true
	return g, true
}

// rasterize_range 光栅化一组字符（一个打包批次）。
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
		if !atlas_grow(f) {
			return false
		}
	}
	batch := f.next_batch
	for cp, i in cps {
		gi := stbtt.FindGlyphIndex(&f.info, cp)
		g := glyphFromPackedchar(f, cp, gi, chardata[i], batch)
		if !g.empty {
			pc := chardata[i]
			atlas_upload_rect(&f.atlas, u32(pc.x0), u32(pc.y0), u32(pc.x1) - u32(pc.x0), u32(pc.y1) - u32(pc.y0))
		}
		f.glyphs[cp] = g
		append(&f.pack_order, cp)
	}
	f.next_batch += 1
	f.dirty = true
	return true
}

// glyph_from_packedchar 把 stb 打包结果转换成 Glyph（UV/度量全部展开，渲染零开销）。
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

// font_key 生成实例注册表 key：(路径, 尺寸)。
fontKey :: proc(path: string, size: f32) -> string {
	return fmt.tprintf("%s\x00%g", path, size)
}
