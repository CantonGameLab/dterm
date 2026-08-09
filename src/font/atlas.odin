// 图集管理：stbtt Pack 上下文、GL R8 纹理、增量上传、满时扩容重打包。
//
// 布局可确定性重放：
//   stb 的矩形打包（stbrp）在相同初始状态 + 相同批次矩形序列下必然产出相同布局。
//   因此磁盘缓存加载时无需重新光栅化：把存储的矩形按原批次顺序 PackRects 一遍，
//   包器状态即可与像素内容保持一致，后续惰性新增的字符绝不会覆盖已有字形。
package font

import stbtt "vendor:stb/truetype"
import stbrp "vendor:stb/rect_pack"
import gl "vendor:OpenGL"
import "core:c"

// 字形间 padding：防止双线性采样串色
ATLAS_PADDING :: 1

// 图集尺寸（像素），满时按 2 倍扩容
ATLAS_INITIAL_SIZE :: 1024
ATLAS_MAX_SIZE     :: 4096

// 超采样：2x 可显著改善小字号边缘，代价是 4 倍图集内存。
// 修改后旧的磁盘缓存会自动失效（key 不匹配）。
OVER_SAMPLE_X :: 1
OVER_SAMPLE_Y :: 1

Atlas :: struct {
	texture_id: u32,
	width:      u32,
	height:     u32,
	pixels:     []byte, // CPU 侧副本：扩容重打包与磁盘缓存需要
	ctx:        stbtt.pack_context,
}

// atlas_create 创建 Pack 上下文与 GL 纹理（内部调用后需自行填充/上传像素）。
atlas_create :: proc(f: ^Font, width, height: u32) -> bool {
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
	atlas_upload_full(a)
	return true
}

// atlas_destroy 释放 GL 纹理、Pack 上下文与像素缓冲。
atlas_destroy :: proc(a: ^Atlas) {
	if a.texture_id != 0 {
		gl.DeleteTextures(1, &a.texture_id)
		a.texture_id = 0
	}
	if a.pixels != nil {
		stbtt.PackEnd(&a.ctx)
		delete(a.pixels)
	}
}

// atlas_grow 把图集放大 2 倍并重放所有历史批次。
// 重放后布局与旧图集完全一致（skyline 算法确定性），因此 UV 无需变更。
atlas_grow :: proc(f: ^Font) -> bool {
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

	atlas_replay(f)          // 让包器状态与像素内容一致

	// 图集尺寸变化后，按新尺寸重建所有字形的 UV（像素坐标不变）
	for cp in f.pack_order {
		g := &f.glyphs[cp]
		g.u0 = g.x0 / f32(new_w)
		g.u1 = g.x1 / f32(new_w)
		g.v0 = g.y0 / f32(new_h)
		g.v1 = g.y1 / f32(new_h)
	}

	atlas_upload_full(&f.atlas)
	return true
}

// atlas_replay 按原批次顺序重放打包，使包器占用状态与图集像素一致。
// 重放矩形尺寸 = 存储 rect + padding（与 stb GatherRects 的约定一致）。
atlas_replay :: proc(f: ^Font) {
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

// atlas_upload_full 整张上传图集（创建/扩容/磁盘加载后调用）。
atlas_upload_full :: proc(a: ^Atlas) {
	gl.BindTexture(gl.TEXTURE_2D, a.texture_id)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, c.int(a.width), c.int(a.height), 0, gl.RED, gl.UNSIGNED_BYTE, raw_data(a.pixels))
}

// atlas_upload_rect 增量上传单个字形区域（只传新增部分，不整图重传）。
atlas_upload_rect :: proc(a: ^Atlas, x, y, w, h: u32) {
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

