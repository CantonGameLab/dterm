// 图集管理:stbtt Pack 上下文 + GL R8 纹理,满时 2 倍扩容。
// 布局可确定性重放(skyline 打包确定性):磁盘缓存加载时按原批次重放
// PackRects,包器状态即与像素一致,后续新增字形不会覆盖已有字形。
package font

import stbtt "vendor:stb/truetype"
import stbrp "vendor:stb/rect_pack"
import gl "vendor:OpenGL"
import "core:c"

// 字形间 padding,防双线性采样串色
ATLAS_PADDING :: 1

ATLAS_INITIAL_SIZE :: 1024
ATLAS_MAX_SIZE     :: 4096

// 2x 超采样改善小字号边缘,代价 4 倍图集内存;改动后磁盘缓存自动失效
OVER_SAMPLE_X :: 1
OVER_SAMPLE_Y :: 1

Atlas :: struct {
	texture_id: u32,
	width:      u32,
	height:     u32,
	pixels:     []byte, // CPU 侧副本:扩容重打包与磁盘缓存需要
	ctx:        stbtt.pack_context,
}

atlasCreate :: proc(f: ^Font, width, height: u32) -> bool {
	a := &f.atlas
	a.width = width
	a.height = height
	a.pixels = make([]byte, width * height)
	if !stbtt.PackBegin(&a.ctx, raw_data(a.pixels), c.int(width), c.int(height), 0, ATLAS_PADDING, nil) {
		delete(a.pixels)
		return false
	}
	stbtt.PackSetOversampling(&a.ctx, OVER_SAMPLE_X, OVER_SAMPLE_Y)
	stbtt.PackSetSkipMissingCodepoints(&a.ctx, true)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.GenTextures(1, &a.texture_id)
	gl.BindTexture(gl.TEXTURE_2D, a.texture_id)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	atlasUploadFull(a)
	return true
}

atlasDestroy :: proc(a: ^Atlas) {
	if a.texture_id != 0 {
		gl.DeleteTextures(1, &a.texture_id)
		a.texture_id = 0
	}
	if a.pixels != nil {
		stbtt.PackEnd(&a.ctx)
		delete(a.pixels)
	}
}

// 满则放大 2 倍,重放历史批次;布局确定性,UV 按新尺寸重建
atlasGrow :: proc(f: ^Font) -> bool {
	old := f.atlas
	new_w := old.width * 2
	new_h := old.height * 2
	if new_w > ATLAS_MAX_SIZE || new_h > ATLAS_MAX_SIZE {
		return false
	}

	new_pixels := make([]byte, new_w * new_h)
	ctx: stbtt.pack_context
	if !stbtt.PackBegin(&ctx, raw_data(new_pixels), c.int(new_w), c.int(new_h), 0, ATLAS_PADDING, nil) {
		delete(new_pixels)
		return false
	}
	stbtt.PackSetOversampling(&ctx, OVER_SAMPLE_X, OVER_SAMPLE_Y)
	stbtt.PackSetSkipMissingCodepoints(&ctx, true)

	copy(new_pixels, old.pixels)
	stbtt.PackEnd(&old.ctx)
	delete(old.pixels)

	f.atlas.width = new_w
	f.atlas.height = new_h
	f.atlas.pixels = new_pixels
	f.atlas.ctx = ctx

	atlasReplay(f)

	for cp in f.pack_order {
		g := &f.glyphs[cp]
		g.u0 = g.x0 / f32(new_w)
		g.u1 = g.x1 / f32(new_w)
		g.v0 = g.y0 / f32(new_h)
		g.v1 = g.y1 / f32(new_h)
	}

	atlasUploadFull(&f.atlas)
	return true
}

// 按原批次顺序重放打包,使包器占用与图集像素一致。
// 重放矩形尺寸 = 存储 rect + padding(与 GatherRects 约定一致)。
atlasReplay :: proc(f: ^Font) {
	order := f.pack_order
	i := 0
	for i < len(order) {
		batch := f.glyphs[order[i]].batch
		j := i + 1
		for j < len(order) && f.glyphs[order[j]].batch == batch {
			j += 1
		}
		n := j - i
		rects := make([]stbrp.Rect, n)
		for k in 0 ..< n {
			g := f.glyphs[order[i + k]]
			rects[k] = stbrp.Rect {
				w = stbrp.Coord(c.int(g.x1 - g.x0) + ATLAS_PADDING),
				h = stbrp.Coord(c.int(g.y1 - g.y0) + ATLAS_PADDING),
			}
		}
		stbtt.PackFontRangesPackRects(&f.atlas.ctx, raw_data(rects), c.int(n))
		delete(rects)
		i = j
	}
}

atlasUploadFull :: proc(a: ^Atlas) {
	gl.BindTexture(gl.TEXTURE_2D, a.texture_id)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, c.int(a.width), c.int(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels))
}

atlasUploadRect :: proc(a: ^Atlas, x, y, w, h: u32) {
	if w == 0 || h == 0 {
		return
	}
	gl.BindTexture(gl.TEXTURE_2D, a.texture_id)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	start := uint(x) + uint(y) * uint(a.width)
	gl.TexSubImage2D(
		gl.TEXTURE_2D,
		0,
		c.int(x),
		c.int(y),
		c.int(w),
		c.int(h),
		gl.RED,
		gl.UNSIGNED_BYTE,
		raw_data(a.pixels[start:start + uint(w) * uint(h)]),
	)
}
