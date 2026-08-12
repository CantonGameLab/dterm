// 缓存层:内存文件缓存(同一字体只读一次磁盘)+ 磁盘光栅化缓存(cache/fonts/)。
// key = fnv64a(路径 + mtime + 大小 + 采样尺寸),字体改动后自然 miss。
package font

import "core:c"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

CACHE_MAGIC   :: 0x43544644 // "DTFC"
CACHE_VERSION :: 1

CacheHeader :: struct {
	magic:       u32,
	version:     u32,
	path_hash:   u64, // == Font.cache_key,校验用
	pixel_size:  f32,
	oversample:  u32, // OVER_SAMPLE_X | OVER_SAMPLE_Y << 16
	atlas_w:     u32,
	atlas_h:     u32,
	glyph_count: u32,
	pixels_len:  u32,
}

CacheEntry :: struct {
	codepoint:   u32,
	glyph_index: i32,
	x0, y0, x1, y1: u16, // 图集内像素矩形(含 padding)
	xoff, yoff: f32,     // 位图偏移
	xoff2, yoff2: f32,   // 位图右下角
	advance:     f32,
	batch:       u32, // 打包批次号(布局重放用)
}

// ---- 进程内文件字节缓存 ----
file_cache: map[string][]byte

// ---- 缓存目录 ----
cache_dir: string

SetCacheDir :: proc(dir: string) {
	cache_dir = strings.clone(dir)
}

GetCacheDir :: proc() -> string {
	if cache_dir != "" {
		return cache_dir
	}
	if exe, err := os.get_executable_path(context.allocator); err == nil {
		cache_dir = fmt.tprintf("%s/cache/fonts", os.dir(exe))
	} else {
		cache_dir = "cache/fonts"
	}
	return cache_dir
}

CacheKeyOf :: proc(f: ^Font, file_size: i64, mtime: time.Time) -> u64 {
	h := hash.fnv64a(transmute([]byte)f.path)
	m := mtime
	sz := file_size
	h = hash.fnv64a(mem.ptr_to_bytes(&m), h)
	h = hash.fnv64a(mem.ptr_to_bytes(&sz), h)
	h = hash.fnv64a(mem.ptr_to_bytes(&f.size), h)
	return h
}

CacheFilePath :: proc(key: u64) -> string {
	return fmt.tprintf("%s/font_%016x.dtfc", GetCacheDir(), key)
}

// 内存记忆化:同一路径只读一次磁盘
GetFontData :: proc(path: string) -> ([]byte, bool) {
	if data, ok := file_cache[path]; ok {
		return data, true
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil, false
	}
	file_cache[path] = data
	return data, true
}

SaveFontCache :: proc(font: ^Font) -> bool {
	if font.cache_key == 0 || !font.dirty {
		return true
	}
	dir := GetCacheDir()
	if os.make_directory_all(dir) != nil {
		return false
	}

	entry_count := len(font.pack_order)
	entry_bytes := entry_count * size_of(CacheEntry)
	n := size_of(CacheHeader) + entry_bytes + len(font.atlas.pixels)
	buf := make([]byte, n)
	defer delete(buf)

	hdr := (^CacheHeader)(raw_data(buf))
	hdr.magic = CACHE_MAGIC
	hdr.version = CACHE_VERSION
	hdr.path_hash = font.cache_key
	hdr.pixel_size = font.size
	hdr.oversample = OVER_SAMPLE_X | OVER_SAMPLE_Y << 16
	hdr.atlas_w = font.atlas.width
	hdr.atlas_h = font.atlas.height
	hdr.glyph_count = u32(entry_count)
	hdr.pixels_len = u32(len(font.atlas.pixels))

	entries := mem.slice_ptr(
		cast(^CacheEntry)(uintptr(raw_data(buf)) + size_of(CacheHeader)),
		entry_count,
	)
	for cp, i in font.pack_order {
		g := font.glyphs[cp]
		entries[i] = CacheEntry {
			codepoint   = u32(cp),
			glyph_index = g.glyph_index,
			x0          = u16(g.x0),
			y0          = u16(g.y0),
			x1          = u16(g.x1),
			y1          = u16(g.y1),
			xoff        = g.bearing_x,
			yoff        = g.bearing_y,
			xoff2       = g.bearing_x + g.width,
			yoff2       = g.bearing_y + g.height,
			advance     = g.advance,
			batch       = g.batch,
		}
	}
	copy(buf[size_of(CacheHeader) + entry_bytes:], font.atlas.pixels)

	if os.write_entire_file(CacheFilePath(font.cache_key), buf) != nil {
		return false
	}
	font.dirty = false
	return true
}

// 命中磁盘缓存:零光栅化恢复图集 + 字形表 + 包器状态
TryLoadDiskCache :: proc(f: ^Font) -> bool {
	if f.cache_key == 0 {
		return false
	}
	raw, err := os.read_entire_file(CacheFilePath(f.cache_key), context.allocator)
	if err != nil {
		return false
	}
	defer delete(raw)

	if len(raw) < size_of(CacheHeader) {
		return false
	}
	hdr := (^CacheHeader)(raw_data(raw))^
	if hdr.magic != CACHE_MAGIC || hdr.version != CACHE_VERSION {
		return false
	}
	if hdr.path_hash != f.cache_key {
		return false
	}
	if hdr.pixel_size != f.size {
		return false
	}
	if hdr.oversample != OVER_SAMPLE_X | OVER_SAMPLE_Y << 16 {
		return false
	}
	if hdr.glyph_count == 0 {
		return false
	}
	entry_bytes := int(hdr.glyph_count) * size_of(CacheEntry)
	if size_of(CacheHeader) + entry_bytes + int(hdr.pixels_len) != len(raw) {
		return false
	}
	if hdr.atlas_w == 0 || hdr.atlas_h == 0 || hdr.atlas_w * hdr.atlas_h != hdr.pixels_len {
		return false
	}

	atlasCreate(f, hdr.atlas_w, hdr.atlas_h) // PackBegin 清零缓冲,随后恢复像素
	copy(f.atlas.pixels, raw[size_of(CacheHeader) + entry_bytes:])

	entries := mem.slice_ptr(
		cast(^CacheEntry)(uintptr(raw_data(raw)) + size_of(CacheHeader)),
		int(hdr.glyph_count),
	)

	f.glyphs = make(map[rune]Glyph, int(hdr.glyph_count))
	max_batch: u32
	for e in entries {
		cp := rune(e.codepoint)
		g := Glyph {
			codepoint   = cp,
			glyph_index = e.glyph_index,
			u0          = f32(e.x0) / f32(hdr.atlas_w),
			v0          = f32(e.y0) / f32(hdr.atlas_h),
			u1          = f32(e.x1) / f32(hdr.atlas_w),
			v1          = f32(e.y1) / f32(hdr.atlas_h),
			x0          = f32(e.x0),
			y0          = f32(e.y0),
			x1          = f32(e.x1),
			y1          = f32(e.y1),
			bearing_x   = e.xoff,
			bearing_y   = e.yoff,
			width       = e.xoff2 - e.xoff,
			height      = e.yoff2 - e.yoff,
			advance     = e.advance,
			batch       = e.batch,
		}
		g.empty = g.width == 0 || g.height == 0
		f.glyphs[cp] = g
		append(&f.pack_order, cp)
		max_batch = max(max_batch, e.batch)
	}
	f.next_batch = max_batch + 1
	f.from_cache = true
	f.dirty = false

	atlasReplay(f)
	atlasUploadFull(&f.atlas)
	return true
}
