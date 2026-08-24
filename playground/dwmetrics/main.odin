// DWrite 字体度量实证:DWRITE_FONT_METRICS(WT 的唯一度量来源)vs hhea vs OS/2 usWin*/typo*。
// 用 DWriteCreateFactory + COM vtable 手调,打印各字体原始表值与 DWrite 值,确认差异来源。
package main

import stbtt "vendor:stb/truetype"
import "core:fmt"
import "core:os"
import "core:c"
import "core:math"
import "core:mem"
import "core:sys/windows"

// ---------------------------------------------------------------------------
// DWrite 最小 COM 绑定(手写 vtable 调用)
// ---------------------------------------------------------------------------

HRESULT :: i32
BOOL :: i32

DWRITE_FACTORY_TYPE :: enum i32 { SHARED = 0, ISOLATED = 1 }
DWRITE_FONT_WEIGHT :: i32
DWRITE_FONT_STRETCH :: i32
DWRITE_FONT_STYLE :: i32

DWRITE_FONT_METRICS :: struct {
	designUnitsPerEm : u16,
	ascent : u16,
	descent : u16,
	lineGap : i16,
	capHeight : u16,
	xHeight : u16,
	underlinePosition : i16,
	underlineThickness : u16,
	strikethroughPosition : i16,
	strikethroughThickness : i16,
}

DWRITE_GLYPH_METRICS :: struct {
	leftSideBearing : i32,
	advanceWidth : u32,
	rightSideBearing : i32,
	topSideBearing : i32,
	advanceHeight : u32,
	bottomSideBearing : i32,
	verticalOriginY : i32,
}

foreign import dwrite "system:dwrite.lib"

foreign dwrite {
	DWriteCreateFactory :: proc(factoryType : DWRITE_FACTORY_TYPE, iid : ^windows.IID, factory : ^rawptr) -> HRESULT ---
}

vt :: proc(obj : rawptr) -> ^[^]rawptr {
	return cast(^[^]rawptr)obj
}

// COM 调用别名(每接口各自索引,照 dwrite.h 顺序)
query_interface :: proc(obj : rawptr, iid : ^windows.IID, out : ^rawptr) -> HRESULT {
	return (cast(proc "system" (self : rawptr, iid : ^windows.IID, out : ^rawptr) -> HRESULT)vt(obj)[0])(obj, iid, out)
}
idw_factory_get_system_font_collection :: proc(obj : rawptr, out : ^rawptr, check : BOOL) -> HRESULT {
	return (cast(proc "system" (self : rawptr, out : ^rawptr, check : BOOL) -> HRESULT)vt(obj)[3])(obj, out, check)
}
idw_collection_find_family_name :: proc(obj : rawptr, name : ^u16, index : ^u32, exists : ^BOOL) -> HRESULT {
	return (cast(proc "system" (self : rawptr, name : ^u16, index : ^u32, exists : ^BOOL) -> HRESULT)vt(obj)[5])(obj, name, index, exists)
}
idw_collection_get_font_family :: proc(obj : rawptr, index : u32, out : ^rawptr) -> HRESULT {
	return (cast(proc "system" (self : rawptr, index : u32, out : ^rawptr) -> HRESULT)vt(obj)[4])(obj, index, out)
}
idw_family_get_first_matching :: proc(obj : rawptr, weight : DWRITE_FONT_WEIGHT, stretch : DWRITE_FONT_STRETCH, style : DWRITE_FONT_STYLE, out : ^rawptr) -> HRESULT {
	return (cast(proc "system" (self : rawptr, weight : DWRITE_FONT_WEIGHT, stretch : DWRITE_FONT_STRETCH, style : DWRITE_FONT_STYLE, out : ^rawptr) -> HRESULT)vt(obj)[7])(obj, weight, stretch, style, out)
}
idw_font_get_metrics :: proc(obj : rawptr, out : ^DWRITE_FONT_METRICS) -> HRESULT {
	return (cast(proc "system" (self : rawptr, out : ^DWRITE_FONT_METRICS) -> HRESULT)vt(obj)[7])(obj, out)
}
idw_font_create_face :: proc(obj : rawptr, out : ^rawptr) -> HRESULT {
	return (cast(proc "system" (self : rawptr, out : ^rawptr) -> HRESULT)vt(obj)[13])(obj, out)
}
idw_face_get_metrics :: proc(obj : rawptr, out : ^DWRITE_FONT_METRICS) -> HRESULT {
	return (cast(proc "system" (self : rawptr, out : ^DWRITE_FONT_METRICS) -> HRESULT)vt(obj)[8])(obj, out)
}
idw_face_get_glyph_indices :: proc(obj : rawptr, cps : ^u16, count : u32, glyphs : ^u16) -> HRESULT {
	return (cast(proc "system" (self : rawptr, cps : ^u16, count : u32, glyphs : ^u16) -> HRESULT)vt(obj)[11])(obj, cps, count, glyphs)
}
idw_face_get_design_glyph_metrics :: proc(obj : rawptr, glyphs : ^u16, count : u32, out : ^DWRITE_GLYPH_METRICS, is_sideways : BOOL) -> HRESULT {
	return (cast(proc "system" (self : rawptr, glyphs : ^u16, count : u32, out : ^DWRITE_GLYPH_METRICS, is_sideways : BOOL) -> HRESULT)vt(obj)[10])(obj, glyphs, count, out, is_sideways)
}

// ---------------------------------------------------------------------------
// 字体文件表解析(hhea / OS/2 / head)
// ---------------------------------------------------------------------------

u16at :: proc(data : []u8, off : int) -> u16 {
	return u16(data[off]) << 8 | u16(data[off + 1])
}
u32at :: proc(data : []u8, off : int) -> u32 {
	return u32(data[off]) << 24 | u32(data[off + 1]) << 16 | u32(data[off + 2]) << 8 | u32(data[off + 3])
}
i16at :: proc(data : []u8, off : int) -> i16 {
	return i16(u16at(data, off))
}

// 找表:返回表数据起始偏移
tableOffset :: proc(data : []u8, tag : string) -> int {
	n := int(u16at(data, 4))
	base := 12
	for i in 0 ..< n {
		rec := base + i * 16
		if string(data[rec:rec + 4]) == tag {
			return int(u32at(data, rec + 8))
		}
	}
	return -1
}

try_name :: proc(data : []u8, name : string) -> (u16, u16, i16) {
	// 返回 (unitsPerEm, win/typo 随便占位 0,0) —— 实际调用方在下面分别读
	_ = tableOffset(data, name)
	return 0, 0, 0
}

// 打印某个字体文件的全部表值
dump_file :: proc(fpath : string) {
	data, err := os.read_entire_file_from_path(fpath, context.allocator)
	if err != nil {
		fmt.eprintln("read fail:", fpath)
		return
	}
	defer delete(data)

	units_per_em := u16at(data, tableOffset(data, "head") + 18)
	hh := tableOffset(data, "hhea")
	os2 := tableOffset(data, "OS/2")
	fmt.printf("-- %s --\n", fpath)
	fmt.printf("  unitsPerEm=%d\n", units_per_em)
	fmt.printf("  hhea     asc=%d desc=%d lineGap=%d\n",
		i16at(data, hh + 4), i16at(data, hh + 6), i16at(data, hh + 8))
	if os2 >= 0 {
		fmt.printf("  OS/2     winAsc=%d winDesc=%d typoAsc=%d typoDesc=%d typoLg=%d fsSelection=%04x\n",
			u16at(data, os2 + 74), u16at(data, os2 + 76),
			i16at(data, os2 + 68), i16at(data, os2 + 70), i16at(data, os2 + 72),
			u16at(data, os2 + 62))
	} else {
		fmt.println("  OS/2     <absent>")
	}

	// stbtt 视角(hhea)
	info := stbtt.fontinfo{}
	off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	if off >= 0 {
		stbtt.InitFont(&info, cast([^]byte)raw_data(data), off)
		a, d, lg : c.int
		stbtt.GetFontVMetrics(&info, &a, &d, &lg)
		adv : c.int
		stbtt.GetCodepointHMetrics(&info, '0', &adv, nil)
		fmt.printf("  stbtt    asc=%d desc=%d lineGap=%d '0'adv=%d(units) scale@22px=%f\n",
			a, d, lg, adv, stbtt.ScaleForPixelHeight(&info, 22))
	}
}

// ---------------------------------------------------------------------------
// DWrite 侧
// ---------------------------------------------------------------------------

IID_IDWriteFactory := windows.IID {
	Data1 = 0xb859ee5a, Data2 = 0xd838, Data3 = 0x4b5b,
	Data4 = {0xa2, 0xe5, 0x1a, 0xdc, 0x1d, 0x2e, 0x2a, 0x65},
}

dump_dwrite :: proc(name : string, name_w : [^]u16) {
	factory : rawptr
	hr := DWriteCreateFactory(.SHARED, &IID_IDWriteFactory, &factory)
	if hr < 0 || factory == nil {
		fmt.eprintln("factory fail hr=", hr)
		return
	}
	collection : rawptr
	idw_factory_get_system_font_collection(factory, &collection, 0)
	idx : u32
	exists := BOOL(0)
	idw_collection_find_family_name(collection, name_w, &idx, &exists)
	if exists == 0 {
		fmt.printf("  DW family not found: %s\n", name)
		return
	}
	family : rawptr
	idw_collection_get_font_family(collection, idx, &family)
	font : rawptr
	idw_family_get_first_matching(family, 400, 5, 0, &font)
	m : DWRITE_FONT_METRICS
	idw_font_get_metrics(font, &m)
	fmt.printf("  DWrite Font::GetMetrics  upm=%d asc=%d desc=%d lineGap=%d cap=%d xh=%d\n",
		m.designUnitsPerEm, m.ascent, m.descent, m.lineGap, m.capHeight, m.xHeight)
	face : rawptr
	idw_font_create_face(font, &face)
	mf : DWRITE_FONT_METRICS
	idw_face_get_metrics(face, &mf)
	fmt.printf("  DWrite Face::GetMetrics  upm=%d asc=%d desc=%d lineGap=%d cap=%d xh=%d\n",
		mf.designUnitsPerEm, mf.ascent, mf.descent, mf.lineGap, mf.capHeight, mf.xHeight)
	cps : [1]u16 = {'0'}
	g : u16
	idw_face_get_glyph_indices(face, &cps[0], 1, &g)
	gm : DWRITE_GLYPH_METRICS
	idw_face_get_design_glyph_metrics(face, &g, 1, &gm, 0)
	fmt.printf("  DWrite   '0' gid=%d adv=%d LSB=%d\n", g, gm.advanceWidth, gm.leftSideBearing)
}

utf16 :: proc(s : string) -> [^]u16 {
	buf := make([dynamic]u16, len(s) + 1)
	for r, i in s {
		buf[i] = u16(r)
	}
	buf[len(s)] = 0
	return &buf[0]
}

main :: proc() {
	fmt.println("== 表原始值 ==")
	dump_file(`C:\Windows\Fonts\CascadiaCode.ttf`)
	dump_file(`C:\Windows\Fonts\CascadiaMono.ttf`)
	dump_file(`C:\Windows\Fonts\consola.ttf`)
	dump_file(`C:\Windows\Fonts\msyh.ttc`)

	fmt.println("\n== 模拟 WT 度量(新算法) ==")
	simulate(`C:\Windows\Fonts\CascadiaCode.ttf`)
	simulate(`C:\Windows\Fonts\CascadiaMono.ttf`)
	simulate(`C:\Windows\Fonts\consola.ttf`)
	simulate(`C:\Windows\Fonts\msyh.ttc`)

	fmt.println("\n== DWrite 值 ==")
	dump_dwrite("Cascadia Code", utf16("Cascadia Code"))
	dump_dwrite("Cascadia Mono", utf16("Cascadia Mono"))
	dump_dwrite("Consolas", utf16("Consolas"))
	dump_dwrite("Microsoft YaHei", utf16("Microsoft YaHei"))
}

// ---- 模拟 font.odin 的新度量逻辑(表选择 + WT 公式) ----

// faceMetrics + cellAndBaseline 的复刻(与 src/font/font.odin 保持一致)
simulate :: proc(fpath : string) {
	data, err := os.read_entire_file_from_path(fpath, context.allocator)
	if err != nil {
		fmt.eprintln("read fail:", fpath)
		return
	}
	defer delete(data)

	info := stbtt.fontinfo{}
	off := stbtt.GetFontOffsetForIndex(cast([^]byte)raw_data(data), 0)
	if off < 0 {
		return
	}
	stbtt.InitFont(&info, cast([^]byte)raw_data(data), off)
	scale := stbtt.ScaleForPixelHeight(&info, 22)

	a, d, lg : c.int
	stbtt.GetFontVMetrics(&info, &a, &d, &lg)

	// 表选择(lg 不参与格高,DWrite/WPF 实测:consola 2706→2398,无 lineGap)
	sel := "hhea"
	asc := f32(a)
	desc := f32(-d)
	line_gap := f32(0)
	os2 := tableOffset(data, "OS/2")
	if os2 >= 0 {
		ver := u16at(data, os2)
		if ver >= 1 {
			selbits := u16at(data, os2 + 62)
			if selbits & 0x0080 != 0 {
				sel = "typo(USE_TYPO)"
				asc = f32(i16at(data, os2 + 68))
				desc = f32(-i16at(data, os2 + 70))
			} else {
				sel = "usWin"
				asc = f32(u16at(data, os2 + 74))
				desc = f32(u16at(data, os2 + 76))
			}
		}
	}

	// WT 公式
	adv_h := (asc + desc + line_gap) * scale
	cell := math.round(adv_h)
	baseline := math.round(asc*scale + (line_gap*scale + cell - adv_h) * 0.5)

	fmt.printf("-- %s --\n", fpath)
	fmt.printf("  asc=%0.f desc=%.0f lg=%.0f (em: %.4f/%.4f/%.4f) 选择=[%s]\n",
		asc, desc, line_gap, asc/2048, desc/2048, line_gap/2048, sel)
	fmt.printf("  cell=%.0f  baseline=%.0f (%.3f em)  占格: A顶=%.1f%% g底=%.1f%%\n",
		cell, baseline, baseline/cell,
		(baseline-0.92*scale)/cell*100, (baseline+0.234*scale)/cell*100)
}
