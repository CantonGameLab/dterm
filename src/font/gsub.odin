// OpenType GSUB 解析:连体字体(Fira Code/Cascadia 等)的连体规则。
// 覆盖 lookupType 4(LigatureSubst)+ 1(SingleSubst)+ 6(ChainContextSubst Format 1/3);
// Format 2(类上下文)暂不支持。字节流全大端,偏移相对各自表/子表起始。
package font

import stbtt "vendor:stb/truetype"

MAX_LIG_COMPONENTS :: 8 // 连体最大组件数(含首字形)
MAX_SEQ :: 8            // 上下文序列最大长度

// 序列位置:固定 glyph(Format 1)或 coverage 集合(Format 3)
ChainPos :: struct {
	glyph : u16,
	cov   : int, // 相对字体数据的 coverage 偏移;-1 = 用 glyph
}

// 单替换(type 1)
SingleSubst :: struct {
	lookup_idx : int,
	coverage   : [dynamic]u16,
	targets    : [dynamic]u16,
}

// 连体(type 4)
LigRule :: struct {
	components : [MAX_LIG_COMPONENTS - 1]u16,
	comp_count : u8,
	lig_glyph  : u16,
}

LigSet :: struct {
	rules : [dynamic]LigRule, // 组件数降序(最长优先)
}

// 上下文连体(type 6)
ChainRule :: struct {
	lookup      : u16, // 所属 lookup(逐 lookup 应用需过滤)
	back        : [MAX_SEQ]ChainPos,
	back_len    : u8,
	input       : [MAX_SEQ]ChainPos, // 完整输入序列(首 = 索引 glyph)
	input_len   : u8,
	look        : [MAX_SEQ]ChainPos,
	look_len    : u8,
	subs_seq    : [MAX_SEQ]u8,
	subs_lookup : [MAX_SEQ]u16,
	subs_count  : u8,
}

ChainSet :: struct {
	rules : [dynamic]ChainRule,
}

Gsub :: struct {
	// type 4
	lig_coverage : [dynamic]u16,
	lig_sets     : [dynamic]LigSet,
	// type 6
	chain_coverage : [dynamic]u16,
	chain_sets     : [dynamic]ChainSet,
	// type 1(被 type 6 引用,惰性解析)
	subs : [dynamic]SingleSubst,
	// lookup 登记(供 type 6 引用)
	lookup_types : [dynamic]u8,
	lookup_offs  : [dynamic]int,
	lookup_list  : int,
	// 每 lookup 的首 glyph coverage(升序去重):行扫描时不在其中的位置直接跳过,
	// 避免对无关字符遍历规则集
	lookup_covs : [dynamic][dynamic]u16,
	// calt feature 的 lookup 应用顺序(DFLT script)
	lookup_order : [dynamic]u16,
	data         : []u8, // 引用字体数据(Font.face.data 保活)
	rule_total   : int,
	// 参与连体的 glyph 位图(所有 lookup coverage 并集):整行无参与字符时一次扫描跳过
	active_bits : [1024]u64, // 65536 glyph id / 64
	has_active  : bool,
	// active glyph 排序列表 + 每 lookup 标记位图:行内只对 active 位置做 lookup 检查
	active_glyphs : [dynamic]u16,
	lookup_active : [dynamic][dynamic]u64, // 平行 lookup_order;bit i = 覆盖 active_glyphs[i]
	tmp_pos : [dynamic]int, // 行内 active 位置复用缓冲
}

// ---------------------------------------------------------------------------
// 大端读取
// ---------------------------------------------------------------------------

be16 :: #force_inline proc(d : []u8, off : int) -> u16 {
	return u16(d[off]) << 8 | u16(d[off + 1])
}

be32 :: #force_inline proc(d : []u8, off : int) -> u32 {
	return u32(d[off]) << 24 | u32(d[off + 1]) << 16 | u32(d[off + 2]) << 8 | u32(d[off + 3])
}

// ---------------------------------------------------------------------------
// 解析入口
// ---------------------------------------------------------------------------

ParseGsub :: proc(data : []u8) -> Gsub {
	g := Gsub { data = data }
	base := int(stbtt.GetFontOffsetForIndex(cast([^]u8)raw_data(data), 0))
	if base < 0 {
		return g
	}
	num_tables := int(be16(data, base + 4))
	gsub_base := -1
	for i in 0 ..< num_tables {
		rec := base + 12 + i * 16
		if data[rec + 0] == 'G' && data[rec + 1] == 'S' && data[rec + 2] == 'U' && data[rec + 3] == 'B' {
			gsub_base = int(be32(data, rec + 8))
			break
		}
	}
	if gsub_base < 0 {
		return g
	}

	// LookupList(GSUB 头:scriptList +4 / featureList +6 / lookupList +8)
	g.lookup_list = gsub_base + int(be16(data, gsub_base + 8))
	lookup_count := int(be16(data, g.lookup_list))
	reserve(&g.lookup_types, lookup_count)
	reserve(&g.lookup_offs, lookup_count)
	reserve(&g.lookup_covs, lookup_count)
	for i in 0 ..< lookup_count {
		lo := g.lookup_list + int(be16(data, g.lookup_list + 2 + i * 2))
		append(&g.lookup_types, u8(be16(data, lo)))
		append(&g.lookup_offs, lo)
		append(&g.lookup_covs, [dynamic]u16{}) // 占位,展开规则时填充
	}
	for i in 0 ..< lookup_count {
		switch g.lookup_types[i] {
		case 4:
			parseLigLookup(&g, i)
		case 6:
			parseChainLookup(&g, i)
		}
	}
	parseCaltOrder(&g, gsub_base)
	// 参与位图:只统计 calt 应用链里的 lookup coverage(含 type4 首字形),
	// 避免 cv/ss 等其他 feature 的 coverage 让预扫误判
	buildActive(&g)
	return g
}

// 构建 active glyph 集合 + 每 lookup 标记位图 + 全局位图
buildActive :: proc(g : ^Gsub) {
	for li in g.lookup_order {
		for gl in g.lookup_covs[int(li)] {
			if coverageFind(g.active_glyphs[:], gl) < 0 {
				pos := 0
				for pos < len(g.active_glyphs) && g.active_glyphs[pos] < gl {
					pos += 1
				}
				inject_at_u16(&g.active_glyphs, pos, gl)
			}
		}
	}
	for gl in g.lig_coverage {
		if coverageFind(g.active_glyphs[:], gl) < 0 {
			pos := 0
			for pos < len(g.active_glyphs) && g.active_glyphs[pos] < gl {
				pos += 1
			}
			inject_at_u16(&g.active_glyphs, pos, gl)
		}
	}
	g.has_active = len(g.active_glyphs) > 0
	if !g.has_active {
		return
	}
	for gl in g.active_glyphs {
		g.active_bits[gl >> 6] |= u64(1) << u64(gl & 63)
	}
	// 每 lookup 的 active 标记位图(按 lookup_order 顺序)
	for li in g.lookup_order {
		words := (len(g.active_glyphs) + 63) / 64
		marks := make([dynamic]u64, words)
		for gl in g.lookup_covs[int(li)] {
			if ai := coverageFind(g.active_glyphs[:], gl); ai >= 0 {
				marks[ai >> 6] |= u64(1) << u64(ai & 63)
			}
		}
		append(&g.lookup_active, marks)
	}
}

// 解析 DFLT script 的 calt feature lookup 顺序(逐 lookup 应用需按此顺序)
parseCaltOrder :: proc(g : ^Gsub, gsub_base : int) {
	d := g.data
	script_list := gsub_base + int(be16(d, gsub_base + 4))
	script_count := int(be16(d, script_list))
	for s in 0 ..< script_count {
		rec := script_list + 2 + s * 6
		if d[rec + 0] != 'D' || d[rec + 1] != 'F' || d[rec + 2] != 'L' || d[rec + 3] != 'T' {
			continue
		}
		script := script_list + int(be16(d, rec + 4))
		lang_sys_off := int(be16(d, script))
		lang := script + lang_sys_off
		if lang_sys_off == 0 {
			// 无默认语言系统,遍历 LangSysRecord 找 'dflt'
			lang_count := int(be16(d, script + 2))
			lang = -1
			for l in 0 ..< lang_count {
				lrec := script + 4 + l * 6
				if d[lrec + 0] == 'd' && d[lrec + 1] == 'f' && d[lrec + 2] == 'l' && d[lrec + 3] == 't' {
					lang = script + int(be16(d, lrec + 4))
					break
				}
			}
			if lang < 0 {
				return
			}
		}
		feature_count := int(be16(d, lang + 4))
		feature_list := gsub_base + int(be16(d, gsub_base + 6))
		for f in 0 ..< feature_count {
			fi := int(be16(d, lang + 6 + f * 2))
			frec := feature_list + 2 + fi * 6
			if d[frec + 0] == 'c' && d[frec + 1] == 'a' && d[frec + 2] == 'l' && d[frec + 3] == 't' {
				feat := feature_list + int(be16(d, frec + 4))
				lc := int(be16(d, feat + 2))
				for i in 0 ..< lc {
					append(&g.lookup_order, be16(d, feat + 4 + i * 2))
				}
				return
			}
		}
		return
	}
}

DestroyGsub :: proc(g : ^Gsub) {
	delete(g.lig_coverage)
	for &s in g.lig_sets {
		delete(s.rules)
	}
	delete(g.lig_sets)
	delete(g.chain_coverage)
	for &s in g.chain_sets {
		delete(s.rules)
	}
	delete(g.chain_sets)
	for &s in g.subs {
		delete(s.coverage)
		delete(s.targets)
	}
	delete(g.subs)
	for &c in g.lookup_covs {
		delete(c)
	}
	delete(g.lookup_covs)
	for &m in g.lookup_active {
		delete(m)
	}
	delete(g.lookup_active)
	delete(g.active_glyphs)
	delete(g.tmp_pos)
	delete(g.lookup_types)
	delete(g.lookup_offs)
	delete(g.lookup_order)
}

// ---------------------------------------------------------------------------
// type 4:LigatureSubst
// ---------------------------------------------------------------------------

parseLigLookup :: proc(g : ^Gsub, lookup_idx : int) {
	lo := g.lookup_offs[lookup_idx]
	sub_count := int(be16(g.data, lo + 4))
	for j in 0 ..< sub_count {
		parseLigSubtable(g, lo + int(be16(g.data, lo + 6 + j * 2)))
	}
}

parseLigSubtable :: proc(g : ^Gsub, sub : int) {
	if be16(g.data, sub) != 1 {
		return
	}
	cov_off := sub + int(be16(g.data, sub + 2))
	set_count := int(be16(g.data, sub + 4))
	for k in 0 ..< set_count {
		set_off := sub + int(be16(g.data, sub + 6 + k * 2))
		first, ok := coverageGlyphAt(g.data, cov_off, k)
		if !ok {
			continue
		}
		count := int(be16(g.data, set_off))
		si := gsubSetIndex(&g.lig_coverage, &g.lig_sets, first)
		for i in 0 ..< count {
			lig_off := set_off + int(be16(g.data, set_off + 2 + i * 2))
			lig_glyph := be16(g.data, lig_off)
			comp_count := int(be16(g.data, lig_off + 2))
			if comp_count < 2 || comp_count > MAX_LIG_COMPONENTS {
				continue
			}
			rule := LigRule { comp_count = u8(comp_count - 1), lig_glyph = lig_glyph }
			for c in 0 ..< comp_count - 1 {
				rule.components[c] = be16(g.data, lig_off + 4 + c * 2)
			}
			pos := 0
			for pos < len(g.lig_sets[si].rules) && g.lig_sets[si].rules[pos].comp_count > rule.comp_count {
				pos += 1
			}
			inject_at_rules(&g.lig_sets[si].rules, pos, rule)
			g.rule_total += 1
		}
	}
}

// ---------------------------------------------------------------------------
// type 6:ChainContextSubst
// ---------------------------------------------------------------------------

parseChainLookup :: proc(g : ^Gsub, lookup_idx : int) {
	lo := g.lookup_offs[lookup_idx]
	sub_count := int(be16(g.data, lo + 4))
	for j in 0 ..< sub_count {
		sub_off := lo + int(be16(g.data, lo + 6 + j * 2))
		switch be16(g.data, sub_off) {
		case 1:
			parseChainFmt1(g, lookup_idx, sub_off)
		case 3:
			parseChainFmt3(g, lookup_idx, sub_off)
		}
	}
}

// Format 1:首 glyph 在 coverage,规则为显式 glyph 序列
parseChainFmt1 :: proc(g : ^Gsub, lookup_idx : int, sub : int) {
	cov_off := sub + int(be16(g.data, sub + 2))
	set_count := int(be16(g.data, sub + 4))
	for k in 0 ..< set_count {
		set_off := sub + int(be16(g.data, sub + 6 + k * 2))
		first, ok := coverageGlyphAt(g.data, cov_off, k)
		if !ok {
			continue
		}
		si := gsubSetIndexChain(&g.chain_coverage, &g.chain_sets, first)
		lookupCovAdd(g, lookup_idx, first)
		count := int(be16(g.data, set_off))
		for i in 0 ..< count {
			rule_off := set_off + int(be16(g.data, set_off + 2 + i * 2))
			rule := parseChainRuleFmt1(g, rule_off)
			rule.lookup = u16(lookup_idx)
			if rule.input_len >= 1 {
				append(&g.chain_sets[si].rules, rule)
				g.rule_total += 1
			}
		}
	}
}

parseChainRuleFmt1 :: proc(g : ^Gsub, off : int) -> ChainRule {
	rule := ChainRule {}
	pos := off
	back_count := int(be16(g.data, pos))
	pos += 2
	rule.back_len = u8(min(back_count, MAX_SEQ))
	for i in 0 ..< rule.back_len {
		rule.back[i] = ChainPos { glyph = be16(g.data, pos), cov = -1 }
		pos += 2
	}
	if back_count > MAX_SEQ {
		pos += (back_count - MAX_SEQ) * 2
	}
	input_count := int(be16(g.data, pos))
	pos += 2
	rule.input_len = u8(min(input_count, MAX_SEQ))
	rule.input[0] = ChainPos { cov = -1 } // 首由 coverage 索引隐式
	for i in 1 ..< rule.input_len {
		rule.input[i] = ChainPos { glyph = be16(g.data, pos), cov = -1 }
		pos += 2
	}
	// input_count - 1 个数组元素已消费;若截断则跳过剩余
	consumed := max(0, int(rule.input_len) - 1)
	if input_count - 1 > consumed {
		pos += (input_count - 1 - consumed) * 2
	}
	look_count := int(be16(g.data, pos))
	pos += 2
	rule.look_len = u8(min(look_count, MAX_SEQ))
	for i in 0 ..< rule.look_len {
		rule.look[i] = ChainPos { glyph = be16(g.data, pos), cov = -1 }
		pos += 2
	}
	if look_count > MAX_SEQ {
		pos += (look_count - MAX_SEQ) * 2
	}
	subs_count := int(be16(g.data, pos))
	pos += 2
	rule.subs_count = u8(min(subs_count, MAX_SEQ))
	for i in 0 ..< rule.subs_count {
		rule.subs_seq[i] = u8(be16(g.data, pos))
		rule.subs_lookup[i] = be16(g.data, pos + 2)
		pos += 4
	}
	return rule
}

// Format 3:回溯/输入/前瞻均为 coverage 集合。
// 以输入序列首 coverage 的每个 glyph 为索引展开规则,序列位置存 coverage 偏移。
parseChainFmt3 :: proc(g : ^Gsub, lookup_idx : int, sub : int) {
	pos := sub + 2
	back_count := int(be16(g.data, pos))
	pos += 2
	back_covs := make([]int, max(back_count, 1))
	defer delete(back_covs)
	for i in 0 ..< back_count {
		back_covs[i] = sub + int(be16(g.data, pos))
		pos += 2
	}
	input_count := int(be16(g.data, pos))
	pos += 2
	input_covs := make([]int, max(input_count, 1))
	defer delete(input_covs)
	for i in 0 ..< input_count {
		input_covs[i] = sub + int(be16(g.data, pos))
		pos += 2
	}
	look_count := int(be16(g.data, pos))
	pos += 2
	look_covs := make([]int, max(look_count, 1))
	defer delete(look_covs)
	for i in 0 ..< look_count {
		look_covs[i] = sub + int(be16(g.data, pos))
		pos += 2
	}
	subs_count := int(be16(g.data, pos))
	pos += 2
	if input_count == 0 {
		return
	}

	// 以 input_covs[0] 的每个 glyph 为索引,展开一条规则
	firsts, ok := coverageAll(g.data, input_covs[0])
	if !ok {
		return
	}
	for f, _ in firsts {
		first := u16(f)
		si := gsubSetIndexChain(&g.chain_coverage, &g.chain_sets, first)
		lookupCovAdd(g, lookup_idx, first)
		rule := ChainRule {
			lookup     = u16(lookup_idx),
			back_len   = u8(min(back_count, MAX_SEQ)),
			input_len  = u8(min(input_count, MAX_SEQ)),
			look_len   = u8(min(look_count, MAX_SEQ)),
			subs_count = u8(min(subs_count, MAX_SEQ)),
		}
		for i in 0 ..< rule.back_len {
			rule.back[i] = ChainPos { cov = back_covs[i] }
		}
		rule.input[0] = ChainPos { cov = -1 } // 首 = 索引 glyph 本身
		for i in 1 ..< rule.input_len {
			rule.input[i] = ChainPos { cov = input_covs[i] }
		}
		for i in 0 ..< rule.look_len {
			rule.look[i] = ChainPos { cov = look_covs[i] }
		}
		subs_pos := pos
		for i in 0 ..< rule.subs_count {
			rule.subs_seq[i] = u8(be16(g.data, subs_pos))
			rule.subs_lookup[i] = be16(g.data, subs_pos + 2)
			subs_pos += 4
		}
		append(&g.chain_sets[si].rules, rule)
		g.rule_total += 1
	}
}

// ---------------------------------------------------------------------------
// type 1:SingleSubst(惰性解析)
// ---------------------------------------------------------------------------

getSubst :: proc(g : ^Gsub, lookup_idx : int) -> ^SingleSubst {
	for i in 0 ..< len(g.subs) {
		if g.subs[i].lookup_idx == lookup_idx {
			return &g.subs[i]
		}
	}
	s := SingleSubst { lookup_idx = lookup_idx }
	lo := g.lookup_offs[lookup_idx]
	sub_off := lo + int(be16(g.data, lo + 6))
	format := be16(g.data, sub_off)
	cov_off := sub_off + int(be16(g.data, sub_off + 2))
	if format == 1 {
		delta := i16(be16(g.data, sub_off + 4))
		glyphs, _ := coverageAll(g.data, cov_off)
		for gl in glyphs {
			append(&s.coverage, gl)
			append(&s.targets, u16(i32(gl) + i32(delta)))
		}
	} else if format == 2 {
		count := int(be16(g.data, sub_off + 4))
		glyphs, _ := coverageAll(g.data, cov_off)
		for i in 0 ..< min(count, len(glyphs)) {
			append(&s.coverage, glyphs[i])
			append(&s.targets, be16(g.data, sub_off + 6 + i * 2))
		}
	}
	append(&g.subs, s)
	return &g.subs[len(g.subs) - 1]
}

// ---------------------------------------------------------------------------
// Coverage 工具
// ---------------------------------------------------------------------------

coverageGlyphAt :: proc(d : []u8, cov : int, k : int) -> (u16, bool) {
	format := be16(d, cov)
	if format == 1 {
		count := int(be16(d, cov + 2))
		if k >= count {
			return 0, false
		}
		return be16(d, cov + 4 + k * 2), true
	} else if format == 2 {
		range_count := int(be16(d, cov + 2))
		idx := k
		for r in 0 ..< range_count {
			rec := cov + 4 + r * 6
			start := int(be16(d, rec))
			end := int(be16(d, rec + 2))
			span := end - start + 1
			if idx < span {
				return u16(start + idx), true
			}
			idx -= span
		}
	}
	return 0, false
}

coverageAll :: proc(d : []u8, cov : int) -> ([]u16, bool) {
	format := be16(d, cov)
	if format == 1 {
		count := int(be16(d, cov + 2))
		out := make([]u16, count)
		for i in 0 ..< count {
			out[i] = be16(d, cov + 4 + i * 2)
		}
		return out, true
	} else if format == 2 {
		range_count := int(be16(d, cov + 2))
		total := 0
		for r in 0 ..< range_count {
			rec := cov + 4 + r * 6
			total += int(be16(d, rec + 2)) - int(be16(d, rec)) + 1
		}
		out := make([]u16, total)
		idx := 0
		for r in 0 ..< range_count {
			rec := cov + 4 + r * 6
			for gl in int(be16(d, rec)) ..= int(be16(d, rec + 2)) {
				out[idx] = u16(gl)
				idx += 1
			}
		}
		return out, true
	}
	return nil, false
}

// coverage 集合包含 glyph?
coverageContains :: proc(g : ^Gsub, cov : int, glyph : u16) -> bool {
	format := be16(g.data, cov)
	if format == 1 {
		count := int(be16(g.data, cov + 2))
		lo, hi := 0, count - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			v := be16(g.data, cov + 4 + mid * 2)
			if v == glyph {
				return true
			} else if v < glyph {
				lo = mid + 1
			} else {
				hi = mid - 1
			}
		}
		return false
	} else if format == 2 {
		range_count := int(be16(g.data, cov + 2))
		for r in 0 ..< range_count {
			rec := cov + 4 + r * 6
			start := int(be16(g.data, rec))
			end := int(be16(g.data, rec + 2))
			if int(glyph) >= start && int(glyph) <= end {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// 运行时匹配
// ---------------------------------------------------------------------------

// 位置匹配:固定 glyph 或 coverage 集合
chainPosMatch :: proc(g : ^Gsub, p : ChainPos, glyph : u16) -> bool {
	if p.cov >= 0 {
		return coverageContains(g, p.cov, glyph)
	}
	return p.glyph == glyph
}

// 逐 lookup 应用连体(等价 HarfBuzz:按 calt lookup 顺序,每个 lookup
// 从左到右扫描,匹配到第一条规则即停,无替换也停,然后进入下一个 lookup)。
// 性能:行内只有少数字符参与连体(active 位图判定),先收集 active 位置,
// 每个 lookup 只在这些位置查自己的标记位图,普通字符零规则遍历。
ShapeGlyphs :: proc(g : ^Gsub, glyphs : ^[dynamic]u16) {
	if !g.has_active || len(g.lookup_order) == 0 {
		return
	}
	// 收集 active 位置(整行一次位图扫描)
	clear(&g.tmp_pos)
	for i in 0 ..< len(glyphs) {
		if g.active_bits[glyphs[i] >> 6] & (u64(1) << u64(glyphs[i] & 63)) != 0 {
			append(&g.tmp_pos, i)
		}
	}
	if len(g.tmp_pos) == 0 {
		return
	}
	for li, idx in g.lookup_order {
		marks := g.lookup_active[idx]
		if len(marks) == 0 {
			continue
		}
		p := 0
		for p < len(g.tmp_pos) {
			i := g.tmp_pos[p]
			// 替换可能改变了该位置的 glyph;按当前值查 lookup 标记
			gl := glyphs[i]
			if ai := coverageFind(g.active_glyphs[:], gl); ai < 0 || marks[ai >> 6] & (u64(1) << u64(ai & 63)) == 0 {
				p += 1
				continue
			}
			lig, n := GsubMatch(g, glyphs[:], i, int(li))
			if lig == 0 {
				p += 1
				continue
			}
			if n > 1 {
				// 连体合并:删除被消费的 glyph,位置全部左移 → 重新收集 active 位置
				for j in i + 1 ..< len(glyphs) - (n - 1) {
					glyphs[j] = glyphs[j + n - 1]
				}
				resize(glyphs, len(glyphs) - (n - 1))
				clear(&g.tmp_pos)
				for k in 0 ..< len(glyphs) {
					if g.active_bits[glyphs[k] >> 6] & (u64(1) << u64(glyphs[k] & 63)) != 0 {
						append(&g.tmp_pos, k)
					}
				}
				if len(g.tmp_pos) == 0 {
					return
				}
				p = 0 // 从新位置 0 重新扫当前 lookup
				continue
			}
			glyphs[i] = lig
			p += 1
		}
	}
}

// 在 glyphs[i..] 做连体匹配;lookup_idx < 0 匹配所有 lookup,否则只匹配指定 lookup。
// 返回(替换字形, 覆盖字符数);(0,0) = 无
GsubMatch :: proc(g : ^Gsub, glyphs : []u16, i : int, lookup_idx := -1) -> (lig : u16, count : int) {
	if i >= len(glyphs) {
		return 0, 0
	}
	// ① type 4 连体:最长匹配
	if lookup_idx < 0 {
		if si := coverageFind(g.lig_coverage[:], glyphs[i]); si >= 0 {
			set := &g.lig_sets[si]
			for rule in set.rules {
				n := int(rule.comp_count)
				if i + 1 + n > len(glyphs) {
					continue
				}
				match := true
				for c in 0 ..< n {
					if glyphs[i + 1 + c] != rule.components[c] {
						match = false
						break
					}
				}
				if match {
					return rule.lig_glyph, n + 1
				}
			}
		}
	}
	// ② type 6 上下文
	if ci := coverageFind(g.chain_coverage[:], glyphs[i]); ci >= 0 {
		set := &g.chain_sets[ci]
		for rule in set.rules {
			if lookup_idx >= 0 && int(rule.lookup) != lookup_idx {
				continue
			}
			in_len := int(rule.input_len)
			if i + in_len > len(glyphs) {
				continue
			}
			ok := true
			// 输入序列(首 = 索引 glyph,其余按位置匹配)
			for c in 1 ..< in_len {
				if !chainPosMatch(g, rule.input[c], glyphs[i + c]) {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			// 回溯(back[0] 是最靠近 input 的回溯,即 glyphs[i-1])
			bl := int(rule.back_len)
			if i < bl {
				continue
			}
			for c in 0 ..< bl {
				if !chainPosMatch(g, rule.back[c], glyphs[i - 1 - c]) {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			// 前瞻
			ll := int(rule.look_len)
			if i + in_len + ll > len(glyphs) {
				continue
			}
			for c in 0 ..< ll {
				if !chainPosMatch(g, rule.look[c], glyphs[i + in_len + c]) {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			// 上下文命中即停(HarfBuzz 语义:匹配到第一条规则后不再尝试后续),
			// 应用 seq=0 的替换;无替换则返回 (0,0)。
			for s in 0 ..< int(rule.subs_count) {
				seq := int(rule.subs_seq[s])
				li := int(rule.subs_lookup[s])
				if seq != 0 || li >= len(g.lookup_types) {
					continue
				}
				switch g.lookup_types[li] {
				case 4:
					// 嵌套连体:在当前输入序列上做连体匹配
					// 直接用全局连体集匹配(输入序列即 glyphs[i..])
					lig, n := GsubMatch(g, glyphs, i)
					if lig != 0 {
						return lig, n
					}
				case 1:
					ss := getSubst(g, li)
					if t, found := coverageLookup(ss.coverage[:], ss.targets[:], glyphs[i]); found {
						return t, 1
					}
				}
			}
			return 0, 0
		}
	}
	return 0, 0
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

coverageFind :: proc(cov : []u16, glyph : u16) -> int {
	lo, hi := 0, len(cov) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		if cov[mid] == glyph {
			return mid
		} else if cov[mid] < glyph {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return -1
}

coverageLookup :: proc(cov, targets : []u16, glyph : u16) -> (u16, bool) {
	idx := coverageFind(cov, glyph)
	if idx < 0 || idx >= len(targets) {
		return 0, false
	}
	return targets[idx], true
}

gsubSetIndex :: proc(cov : ^[dynamic]u16, sets : ^[dynamic]LigSet, first : u16) -> int {
	for i in 0 ..< len(cov) {
		if cov[i] == first {
			return i
		}
	}
	pos := 0
	for pos < len(cov) && cov[pos] < first {
		pos += 1
	}
	inject_at_u16(cov, pos, first)
	inject_at_ligset(sets, pos, LigSet {})
	return pos
}

// 每 lookup coverage 的升序去重插入(行扫描快速跳过用)
lookupCovAdd :: proc(g : ^Gsub, lookup_idx : int, glyph : u16) {
	cov := &g.lookup_covs[lookup_idx]
	if coverageFind(cov[:], glyph) >= 0 {
		return
	}
	pos := 0
	for pos < len(cov) && cov[pos] < glyph {
		pos += 1
	}
	inject_at_u16(cov, pos, glyph)
}

gsubSetIndexChain :: proc(cov : ^[dynamic]u16, sets : ^[dynamic]ChainSet, first : u16) -> int {
	for i in 0 ..< len(cov) {
		if cov[i] == first {
			return i
		}
	}
	pos := 0
	for pos < len(cov) && cov[pos] < first {
		pos += 1
	}
	inject_at_u16(cov, pos, first)
	inject_at_chainset(sets, pos, ChainSet {})
	return pos
}

inject_at_u16 :: proc(arr : ^[dynamic]u16, pos : int, v : u16) {
	append(arr, 0)
	copy(arr[pos + 1:], arr[pos:len(arr) - 1])
	arr[pos] = v
}

inject_at_ligset :: proc(arr : ^[dynamic]LigSet, pos : int, v : LigSet) {
	append(arr, LigSet {})
	copy(arr[pos + 1:], arr[pos:len(arr) - 1])
	arr[pos] = v
}

inject_at_chainset :: proc(arr : ^[dynamic]ChainSet, pos : int, v : ChainSet) {
	append(arr, ChainSet {})
	copy(arr[pos + 1:], arr[pos:len(arr) - 1])
	arr[pos] = v
}

inject_at_rules :: proc(arr : ^[dynamic]LigRule, pos : int, v : LigRule) {
	append(arr, LigRule {})
	copy(arr[pos + 1:], arr[pos:len(arr) - 1])
	arr[pos] = v
}
