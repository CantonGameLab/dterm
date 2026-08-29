// vtparse 移植:Paul Williams 的 DEC 兼容状态机解析器(Joshua Haberman 版,public domain)。
// 忠实移植 + 两处必要补充:
//   1. UTF-8:原版仅 ASCII,GROUND 会丢弃 0xC0-0xFF;终端需要中文等
//   2. OSC 以 BEL(0x07)终止:xterm/ConPTY 实际用 BEL 结尾
package canvas

Action :: enum u8 {
	None = 0,
	Clear,
	Collect,
	CsiDispatch,
	EscDispatch,
	Error,
	Execute,
	Hook,
	Ignore,
	OscEnd,
	OscPut,
	OscStart,
	Param,
	Print,
	Put,
	Unhook,
	// 注:UTF-8 不再以 Action 表达,由 Parse 顶层拦截(isUtf8Start/utf8Collects)
}

State :: enum u8 {
	Ground = 0, // 零值 = 初始状态
	CsiEntry,
	CsiIgnore,
	CsiIntermediate,
	CsiParam,
	DcsEntry,
	DcsIgnore,
	DcsIntermediate,
	DcsParam,
	DcsPassthrough,
	Escape,
	EscapeIntermediate,
	OscString,
	SosPmApcString,
	NoChange = 255, // 哨兵:状态不变
}

Callback :: #type proc(p : ^Parser, action : Action, ch : rune)

// 参数值上限:DEC 标准 16384,xterm/VTE 用 65535(win32-input-mode 传 UTF-16 值)
MAX_PARAMETER_VALUE :: 65535

MAX_INTERMEDIATE_CHARS :: 2
MAX_PARAMS :: 16
MAX_SUBPARAMS :: 6 // 每参数组最多子参(WT 同限;SGR 38:2::r:g:b 需 6)

Parser :: struct {
	state : State,
	cb : Callback,
	intermediate_chars : [MAX_INTERMEDIATE_CHARS + 1]u8,
	num_intermediate_chars : int,
	ignore_flagged : bool,
	// 参数模型(WT 同构):分号 = 新参数组;冒号 = 组内子参。
	// params[i] = 组主值(第一个子参,兼容扁平消费);subparams[i] = 全子参。
	params : [MAX_PARAMS]int,
	subparams : [MAX_PARAMS][MAX_SUBPARAMS]int,
	num_subparams : [MAX_PARAMS]u8, // 各组子参数个数(含主值);0 = 组未定型
	num_params : int,
	user_data : rawptr, // 回调上下文(Canvas 存 Console 句柄)

	// UTF-8(GROUND 状态消费,先于状态机)
	utf8_pending : [4]u8,
	utf8_pending_len : int,
}

// 字节区间转移
Transition :: struct {
	lo, hi : u8,
	action : Action,
	to : State,
}

StateSpec :: struct {
	entry, exit : Action,
	tr : []Transition,
}

Init :: proc(p : ^Parser, cb : Callback) {
	p.state = .Ground
	p.num_intermediate_chars = 0
	p.num_params = 0
	p.ignore_flagged = false
	p.cb = cb
	p.utf8_pending_len = 0
}

Parse :: proc(p : ^Parser, data : []byte) {
	for b in data {
		// UTF-8 续字节:先于状态机消费(任何状态)
		if p.utf8_pending_len > 0 {
			if b & 0xC0 == 0x80 { // 0b10xxxxxx = 续字节
				p.utf8_pending[p.utf8_pending_len] = b
				p.utf8_pending_len += 1
				if p.utf8_pending_len >= utf8Len(p.utf8_pending[0]) {
					cp := decodeRune(p.utf8_pending[:p.utf8_pending_len])
					p.utf8_pending_len = 0
					utf8Emit(p, cp)
				}
				continue
			}
			// 非法续字节(控制/ASCII/新起始):丢弃截断序列,当前字节重新走状态机。
			// 关键:不吞 ESC/CSI(截断字符串后的序列必须完整生效)。
			p.utf8_pending_len = 0
		}
		// 合法 UTF-8 起始,且当前状态会产出文本/字符串内容才收集
		if isUtf8Start(b) && utf8Collects(p.state) {
			p.utf8_pending[0] = b
			p.utf8_pending_len = 1
			continue
		}
		act, to := lookup(p, b)
		doTransition(p, act, to, b)
	}
}

// 合法起始:C2-DF(2 字节)/E0-EF(3 字节)/F0-F4(4 字节)。
// C0/C1(overlong 编码)与 F5-FF 非法 → 不进收集,由状态机忽略。
isUtf8Start :: proc(b : u8) -> bool {
	return b >= 0xC2 && b <= 0xF4
}

// 只收集会产出"可见字符/字符串内容"的状态;CSI/ESC 等控制序列中的
// 0x80+ 字节 = 非法位置,由状态机忽略。
utf8Collects :: proc(state : State) -> bool {
	#partial switch state {
	case .Ground, .OscString, .DcsPassthrough, .SosPmApcString:
		return true
	}
	return false
}

// 解码完成 → 按当前状态决定去向(Ground = 打印;OSC/DCS = 字符串内容)
utf8Emit :: proc(p : ^Parser, cp : rune) {
	#partial switch p.state {
	case .Ground:
		call(p, .Print, cp)
	case .OscString:
		call(p, .OscPut, cp)
	case .DcsPassthrough:
		call(p, .Put, cp)
	}
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

lookup :: proc(p : ^Parser, b : u8) -> (Action, State) {
	// 任意状态生效的转移(ESC/C1 控制)
	for t in anywhere_transitions {
		if b >= t.lo && b <= t.hi {
			return t.action, t.to
		}
	}
	// 状态内转移
	spec := &state_specs[p.state]
	for t in spec.tr {
		if b >= t.lo && b <= t.hi {
			return t.action, t.to
		}
	}
	return .None, .NoChange
}

doTransition :: proc(p : ^Parser, action : Action, to : State, ch : u8) {
	if to != .NoChange {
		exit := state_specs[p.state].exit
		entry := state_specs[to].entry
		if exit != .None {
			doAction(p, exit, 0)
		}
		if action != .None {
			doAction(p, action, ch)
		}
		if entry != .None {
			doAction(p, entry, 0)
		}
		p.state = to
	} else {
		doAction(p, action, ch)
	}
}

doAction :: proc(p : ^Parser, action : Action, ch : u8) {
	#partial switch action {
	case .Collect:
		if p.num_intermediate_chars + 1 > MAX_INTERMEDIATE_CHARS {
			p.ignore_flagged = true
		} else {
			p.intermediate_chars[p.num_intermediate_chars] = ch
			p.num_intermediate_chars += 1
		}
	case .Param:
		if ch == ';' {
			// 分号 = 新参数组;当前组定型(空段 = 1 个 0)
			if p.num_params == 0 {
				p.num_params = 1
				p.num_subparams[0] = 0
				p.params[0] = 0
			}
			paramEnd(p)
			if p.num_params < MAX_PARAMS {
				p.num_params += 1
				p.num_subparams[p.num_params - 1] = 0
			}
		} else if ch == ':' {
			// 冒号 = 组内子参;当前子参定型,开新子参(值 0)
			if p.num_params == 0 {
				p.num_params = 1
				p.num_subparams[0] = 0
				p.params[0] = 0
			}
			if p.num_params <= MAX_PARAMS {
				paramEnd(p)
				i := p.num_params - 1
				if int(p.num_subparams[i]) < MAX_SUBPARAMS {
					p.num_subparams[i] += 1
					p.subparams[i][p.num_subparams[i] - 1] = 0
				}
			}
		} else {
			// 数字:累加到当前组最后一个子参;主值(第一个子参)同步 params
			if p.num_params == 0 {
				p.num_params = 1
				p.num_subparams[0] = 0
				p.params[0] = 0
			}
			if p.num_params <= MAX_PARAMS {
				i := p.num_params - 1
				if p.num_subparams[i] == 0 {
					p.num_subparams[i] = 1
					p.subparams[i][0] = 0
				}
				j := int(p.num_subparams[i]) - 1
				v := p.subparams[i][j] * 10 + int(ch - '0')
				if v > MAX_PARAMETER_VALUE {
					v = MAX_PARAMETER_VALUE
				}
				p.subparams[i][j] = v
				if j == 0 {
					p.params[i] = v
				}
			}
		}
	case .Clear:
		p.num_intermediate_chars = 0
		p.num_params = 0
		p.ignore_flagged = false
		for i in 0 ..< MAX_PARAMS {
			p.num_subparams[i] = 0
		}
	case .Ignore:
		// 无操作
	case .Error:
		call(p, .Error, rune(ch))
	case .CsiDispatch:
		flushParams(p) // 末尾组定型(如 CSI 5;)后派发
		call(p, action, rune(ch))
	case:
		call(p, action, rune(ch))
	}
}

// 当前组定型:无子参则补一个 0(空段);主值同步(防 params 残留)
paramEnd :: proc(p : ^Parser) {
	i := p.num_params - 1
	if i < 0 {
		return
	}
	if p.num_subparams[i] == 0 {
		p.num_subparams[i] = 1
		p.subparams[i][0] = 0
		p.params[i] = 0
	}
}

// 全部组定型(dispatch 前);未定型组 = 空段 0
flushParams :: proc(p : ^Parser) {
	paramEnd(p)
}

call :: proc(p : ^Parser, action : Action, ch : rune) {
	if p.cb != nil {
		p.cb(p, action, ch)
	}
}

// ---------------------------------------------------------------------------
// UTF-8
// ---------------------------------------------------------------------------

utf8Len :: proc(b : u8) -> int {
	switch {
	case b < 0x80: return 1
	case b < 0xE0: return 2
	case b < 0xF0: return 3
	case b < 0xF8: return 4
	}
	return 1 // 非法起始字节,只消费自身
}

decodeRune :: proc(bytes : []u8) -> rune {
	switch len(bytes) {
	case 1: return rune(bytes[0])
	case 2: return rune(bytes[0] & 0x1F) << 6 | rune(bytes[1] & 0x3F)
	case 3: return rune(bytes[0] & 0x0F) << 12 | rune(bytes[1] & 0x3F) << 6 | rune(bytes[2] & 0x3F)
	case 4: return rune(bytes[0] & 0x07) << 18 | rune(bytes[1] & 0x3F) << 12 | rune(bytes[2] & 0x3F) << 6 | rune(bytes[3] & 0x3F)
	}
	return 0
}

// ---------------------------------------------------------------------------
// 转移表(由 vtparse_tables.rb 忠实转录;OSC 增加 BEL 终止)
// ---------------------------------------------------------------------------

anywhere_transitions := [?]Transition{
	{0x18, 0x18, .Execute, .Ground},
	{0x1A, 0x1A, .Execute, .Ground},
	{0x80, 0x8F, .Execute, .Ground},
	{0x91, 0x97, .Execute, .Ground},
	{0x99, 0x99, .Execute, .Ground},
	{0x9A, 0x9A, .Execute, .Ground},
	{0x9C, 0x9C, .None, .Ground}, // ST
	{0x1B, 0x1B, .None, .Escape}, // ESC
	{0x98, 0x98, .None, .SosPmApcString}, // SOS
	{0x9E, 0x9E, .None, .SosPmApcString}, // PM
	{0x9F, 0x9F, .None, .SosPmApcString}, // APC
	{0x90, 0x90, .None, .DcsEntry},       // DCS
	{0x9D, 0x9D, .None, .OscString},      // OSC
	{0x9B, 0x9B, .None, .CsiEntry},       // CSI
}

tr_ground := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x7F, .Print, .NoChange},
	// UTF-8 起始由 Parse 顶层拦截(isUtf8Start + utf8Collects),不走状态机表
}

tr_escape := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .EscapeIntermediate},
	{0x30, 0x4F, .EscDispatch, .Ground},
	{0x51, 0x57, .EscDispatch, .Ground},
	{0x59, 0x59, .EscDispatch, .Ground},
	{0x5A, 0x5A, .EscDispatch, .Ground},
	{0x5C, 0x5C, .EscDispatch, .Ground},
	{0x60, 0x7E, .EscDispatch, .Ground},
	{0x5B, 0x5B, .None, .CsiEntry},
	{0x5D, 0x5D, .None, .OscString},
	{0x50, 0x50, .None, .DcsEntry},
	{0x58, 0x58, .None, .SosPmApcString},
	{0x5E, 0x5E, .None, .SosPmApcString},
	{0x5F, 0x5F, .None, .SosPmApcString},
}

tr_escape_intermediate := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x7E, .EscDispatch, .Ground},
}

tr_csi_entry := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .CsiIntermediate},
	{0x3A, 0x3A, .None, .CsiIgnore},
	{0x30, 0x39, .Param, .CsiParam},
	{0x3B, 0x3B, .Param, .CsiParam},
	{0x3C, 0x3F, .Collect, .CsiParam}, // ? > < = 私用标记
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_csi_ignore := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x3F, .Ignore, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x40, 0x7E, .None, .Ground},
}

tr_csi_param := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x30, 0x39, .Param, .NoChange},
	{0x3B, 0x3B, .Param, .NoChange},
	// 冒号 = 子参数分隔(xterm 新式 SGR 如 38:2::r:g:b、4:3m)。
	// 按普通参数分隔处理,SGR 层再解释(与分号同语义,空字段为 0)。
	{0x3A, 0x3A, .Param, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3C, 0x3F, .None, .CsiIgnore},
	{0x20, 0x2F, .Collect, .CsiIntermediate},
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_csi_intermediate := [?]Transition{
	{0x00, 0x17, .Execute, .NoChange},
	{0x19, 0x19, .Execute, .NoChange},
	{0x1C, 0x1F, .Execute, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x3F, .None, .CsiIgnore},
	{0x40, 0x7E, .CsiDispatch, .Ground},
}

tr_dcs_entry := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3A, 0x3A, .None, .DcsIgnore},
	{0x20, 0x2F, .Collect, .DcsIntermediate},
	{0x30, 0x39, .Param, .DcsParam},
	{0x3B, 0x3B, .Param, .DcsParam},
	{0x3C, 0x3F, .Collect, .DcsParam},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_intermediate := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x2F, .Collect, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x30, 0x3F, .None, .DcsIgnore},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_ignore := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .Ignore, .NoChange},
}

tr_dcs_param := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x30, 0x39, .Param, .NoChange},
	{0x3B, 0x3B, .Param, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
	{0x3A, 0x3A, .None, .DcsIgnore},
	{0x3C, 0x3F, .None, .DcsIgnore},
	{0x20, 0x2F, .Collect, .DcsIntermediate},
	{0x40, 0x7E, .None, .DcsPassthrough},
}

tr_dcs_passthrough := [?]Transition{
	{0x00, 0x17, .Put, .NoChange},
	{0x19, 0x19, .Put, .NoChange},
	{0x1C, 0x1F, .Put, .NoChange},
	{0x20, 0x7E, .Put, .NoChange},
	{0x7F, 0x7F, .Ignore, .NoChange},
}

tr_sos_pm_apc_string := [?]Transition{
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .Ignore, .NoChange},
}

tr_osc_string := [?]Transition{
	{0x07, 0x07, .None, .Ground}, // BEL 终止 OSC(新增,ConPTY/xterm 用法)
	{0x00, 0x17, .Ignore, .NoChange},
	{0x19, 0x19, .Ignore, .NoChange},
	{0x1C, 0x1F, .Ignore, .NoChange},
	{0x20, 0x7F, .OscPut, .NoChange},
}

state_specs := [14]StateSpec {
	{tr = tr_ground[:]},                                 // Ground = 0
	{entry = .Clear, tr = tr_csi_entry[:]},              // CsiEntry = 1
	{tr = tr_csi_ignore[:]},                             // CsiIgnore = 2
	{tr = tr_csi_intermediate[:]},                       // CsiIntermediate = 3
	{tr = tr_csi_param[:]},                              // CsiParam = 4
	{entry = .Clear, tr = tr_dcs_entry[:]},              // DcsEntry = 5
	{tr = tr_dcs_ignore[:]},                             // DcsIgnore = 6
	{tr = tr_dcs_intermediate[:]},                       // DcsIntermediate = 7
	{tr = tr_dcs_param[:]},                              // DcsParam = 8
	{entry = .Hook, exit = .Unhook, tr = tr_dcs_passthrough[:]}, // DcsPassthrough = 9
	{entry = .Clear, tr = tr_escape[:]},                 // Escape = 10
	{tr = tr_escape_intermediate[:]},                    // EscapeIntermediate = 11
	{entry = .OscStart, exit = .OscEnd, tr = tr_osc_string[:]}, // OscString = 12
	{tr = tr_sos_pm_apc_string[:]},                      // SosPmApcString = 13
}
