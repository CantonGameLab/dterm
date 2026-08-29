// 指令语法解析 + 数据化命令执行:
//   ParseCommandString:字符串 → ParsedCommand(命令数据)
//   ExecuteCommandString:字符串快捷入口(解析 + 执行)
//   ExecuteCommand:ParsedCommand → userapi(唯一命令解释器;
//     快捷键绑定表(keybindings)生成的命令数据也走这里,不做第二次分派)
// 供控制台交互 / 子进程 ANSI 指令通道使用。薄分派层,无 undo / 无历史栈。
// 语法:命令名 参数... [@id]
//   - 参数按空格分隔,"..." 包裹字符串
//   - @id 放末尾指定目标节点(缺省 = 当前焦点)
//   - bind/unbind 的键组合 = mods+key:alt/ctrl/shift/win 前缀以 '+' 连向键名
//     (大小写不敏感,如 f2/alt+shift+l/ctrl+shift+=);目标命令 = 带引号命令字符串
// 例:split right 0.5 / focus left / font "a.ttf" 40 / launch "cmd.exe" @3 /
//    bind alt+shift+l "split right" / unbind f2 / bindings
package canvas

import "core:fmt"
import "core:strings"
import inp "../input"
import mem "../memory"

// 执行命令字符串;查询类命令的结果经 out 回调回传(控制台显示用)。
// 返回 false = 语法错误或执行失败。bind 的子命令槽随消费释放。
ExecuteCommandString :: proc(s : string, out : proc(msg : string) = nil) -> bool {
	cmd, ok := ParseCommandString(s)
	if !ok {
		return false
	}
	// 子命令句柄 = 解析分配、解析+执行一体化消费后即释放(直接 Parse+Execute 的调用者自行释放)
	defer if cmd.sub.id != 0 {
		mem.Free(&sub_commands, cmd.sub)
	}
	return ExecuteCommand(cmd, out)
}

// 数据化命令 → userapi(唯一解释器;kind 全集见 CommandStringKind)
ExecuteCommand :: proc(cmd : ParsedCommand, out : proc(msg : string) = nil) -> bool {
	switch cmd.kind {
	case .Split:
		// :split <right|down> [factor] [@id]
		return SplitNewWindow(cmd.dir, cmd.target) != mem.Handle {}
	case .FocusId:
		return SetFocusWindow(cmd.target)
	case .FocusDir:
		return FocusMove(cmd.fdir, cmd.target)
	case .Destroy:
		return DestroyWindow(cmd.target)
	case .Factor:
		return SetSplitFactor(cmd.fval, cmd.target)
	case .FactorLeaf:
		return SetSplitFactorLeaf(cmd.ival, cmd.fval)
	case .Exchange:
		return ExchangeWindow(cmd.fdir, cmd.target)
	case .Font:
		return SetWindowFont(cmd.sval, cmd.fval, cmd.target)
	case .FontSize:
		return SetWindowFontSize(cmd.fval, cmd.target)
	case .FontSizeUp:
		return AdjustFontSize(2, cmd.target)
	case .FontSizeDown:
		return AdjustFontSize(-2, cmd.target)
	case .Launch:
		return LaunchConsole(cmd.sval, cmd.target)
	case .Feed:
		return FeedConsole(transmute([]u8)cmd.sval, cmd.target)
	case .AutoClose:
		return SetAutoClose(cmd.bval, cmd.target)
	case .Scroll:
		return ConsoleScroll(int(cmd.fval), cmd.target)
	case .ReviewUp:
		return ConsoleScroll(-focusRows(cmd.target), cmd.target)
	case .ReviewDown:
		return ConsoleScroll(focusRows(cmd.target), cmd.target)
	case .ToggleCommandBar:
		ToggleCommandBar(cmd.target)
		return true
	case .SetBinding:
		// :bind <mods+key> "<命令字符串>" — 子命令已由解析层解析入表(sub 句柄),执行只读
		sub := mem.Get(&sub_commands, cmd.sub)
		if sub == nil {
			return false
		}
		return SetKeyBinding(inp.Scancode(cmd.sc), cmd.mods, sub^)
	case .UnsetBinding:
		return UnsetKeyBinding(inp.Scancode(cmd.sc), cmd.mods)
	case .BindingsGet:
		if out != nil {
			if keybinding_count == 0 {
				out("(no bindings)")
			}
			for i in 0 ..< keybinding_count {
				b := &default_bindings[i]
				combo : [64]u8
				out(fmt.tprintf("bind %s \"%v\"", comboName(b.mods, b.key, &combo), b.cmd.kind))
			}
		}
		return true
	case .Count:
		if out != nil {
			out(fmt.tprintf("windows: %d", WindowCount()))
		}
		return true
	case .FocusGet:
		if out != nil {
			f := GetFocusWindow()
			out(fmt.tprintf("focus: %d", f.id))
		}
		return true
	}
	return false
}

// 焦点(或 target)console 的行数;无 console 返回 0(翻页/滚动安全空转)
focusRows :: proc(target : mem.Handle) -> int {
	node_h := resolveWindow(target)
	if node_h.id == 0 {
		return 0
	}
	win := NodeWindow(node_h)
	if win == nil {
		return 0
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return 0
	}
	return int(console.rows)
}

// 解析结果:按 kind 判别取用字段
CommandStringKind :: enum u8 {
	Split,
	FocusId,
	FocusDir,
	Destroy,
	Factor,
	Exchange,
	Font,
	FontSize,     // fval:绝对字号
	FontSizeUp,   // +1(绑定)
	FontSizeDown, // -1(绑定)
	Launch,
	Feed,
	AutoClose,
	Scroll,       // fval:行数(正下负上)
	ReviewUp,     // 上翻一屏(绑定 PageUp)
	ReviewDown,   // 下翻一屏(绑定 PageDown)
	ToggleCommandBar, // 悬浮控制台切换(绑定 F2)
	Count,
	FocusGet,
	FactorLeaf,   // ival:叶子序号(1-based)认领的 split;fval:新 factor
	SetBinding,   // sc+mods:键组合;sval:目标命令字符串(执行时再解析)
	UnsetBinding, // sc+mods:移除该绑定
	BindingsGet,  // 枚举输出全部绑定
}

ParsedCommand :: struct {
	kind : CommandStringKind,
	target : mem.Handle, // @id 解析出的节点(带世代);0 = 焦点
	dir : SplitType, // Split 用
	fdir : FocusDirection, // Focus 用;Exchange 仅 Left/Right(叶子序)
	fval : f32, // Factor/Font
	ival : int, // FactorLeaf:叶子序号(1-based)
	bval : bool, // AutoClose
	sval : string, // Font path / Launch cmd / Feed 文本(借用输入内存)
	sc : u32, // SetBinding/UnsetBinding:scancode 数值
	mods : KeyMods, // SetBinding/UnsetBinding:修饰位
	sub : mem.Handle, // SetBinding:子命令(解析层 Alloc 入 sub_commands;消费后释放)
}

// bind 子命令表:解析层 Alloc(每次 bind 解析一个槽),ExecuteCommandString 消费后 Free。
// 嵌套 bind 拒绝(子命令不再挂子命令,单层足够)。
MAX_SUB_COMMANDS :: 32

sub_commands : mem.GenArray(MAX_SUB_COMMANDS, ParsedCommand)

// 把命令字符串解析为 ParsedCommand;字符串字段借用 s 内存(调用方保证 s 存活于本次调用)
ParseCommandString :: proc(s : string) -> (ParsedCommand, bool) {
	trimmed := strings.trim_space(s)
	if len(trimmed) == 0 {
		return {}, false
	}
	tokens : [16]string
	n := parseTokens(trimmed, &tokens)
	if n == 0 {
		return {}, false
	}
	pc : ParsedCommand

	// 剥离末尾 @id
	argn := n - 1
	if n >= 2 && tokens[n - 1][0] == '@' {
		id, ok := parseU32(tokens[n - 1][1:])
		if !ok {
			return {}, false
		}
		pc.target = NodeHandleById(id)
		argn = n - 2
	}
	args := tokens[1:1 + argn]

	switch tokens[0] {
	case "split":
		if argn < 1 {
			return {}, false
		}
		dir, ok := parseSplitDir(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .Split
		pc.dir = dir
		if argn >= 2 {
			f, ok := parseF32(args[1])
			if !ok {
				return {}, false
			}
			// factor 当前 SplitNewWindow 固定 0.5;存了备用
			_ = f
		}
	case "focus":
		if argn < 1 {
			return {}, false
		}
		if id, ok := parseU32(args[0]); ok {
			pc.kind = .FocusId
			pc.target = NodeHandleById(id)
		} else if d, ok := parseFocusDir(args[0]); ok {
			pc.kind = .FocusDir
			pc.fdir = d
		} else {
			return {}, false
		}
	case "destroy":
		pc.kind = .Destroy
	case "factor":
		if argn < 1 {
			return {}, false
		}
		f, ok := parseF32(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .Factor
		pc.fval = f
	case "factorleaf":
		if argn < 2 {
			return {}, false
		}
		n, nok := parseU32(args[0])
		if !nok {
			return {}, false
		}
		f, fok := parseF32(args[1])
		if !fok {
			return {}, false
		}
		pc.kind = .FactorLeaf
		pc.ival = int(n)
		pc.fval = f
	case "exchange":
		if argn < 1 {
			return {}, false
		}
		d, ok := parseFocusDir(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .Exchange
		pc.fdir = d
	case "font":
		if argn < 2 {
			return {}, false
		}
		size, ok := parseF32(args[1])
		if !ok {
			return {}, false
		}
		pc.kind = .Font
		pc.sval = args[0]
		pc.fval = size
	case "fontsize":
		if argn < 1 {
			return {}, false
		}
		size, ok := parseF32(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .FontSize
		pc.fval = size
	case "scroll":
		if argn < 1 {
			return {}, false
		}
		delta, ok := parseF32(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .Scroll
		pc.fval = delta
	case "launch":
		if argn < 1 {
			return {}, false
		}
		pc.kind = .Launch
		pc.sval = args[0]
	case "feed":
		if argn < 1 {
			return {}, false
		}
		pc.kind = .Feed
		pc.sval = args[0]
	case "autoclose":
		if argn < 1 {
			return {}, false
		}
		pc.kind = .AutoClose
		pc.bval = args[0] == "true" || args[0] == "1" || args[0] == "on"
	case "count", "windows":
		pc.kind = .Count
	case "focus-get", "getfocus":
		pc.kind = .FocusGet
	case "bind":
		if argn < 2 {
			return {}, false
		}
		key, mods, ok := parseKeyCombo(args[0])
		if !ok {
			return {}, false
		}
		sub, sub_ok := ParseCommandString(args[1])
		if !sub_ok || sub.kind == .SetBinding || sub.kind == .UnsetBinding {
			return {}, false // 非法目标命令(禁止嵌套 bind)
		}
		sub_h := mem.Alloc(&sub_commands, sub)
		if sub_h.id == 0 {
			return {}, false // 表满(子命令槽未消费;旧槽随消费释放)
		}
		pc.kind = .SetBinding
		pc.sc = u32(key)
		pc.mods = mods
		pc.sub = sub_h
	case "unbind":
		if argn < 1 {
			return {}, false
		}
		key, mods, ok := parseKeyCombo(args[0])
		if !ok {
			return {}, false
		}
		pc.kind = .UnsetBinding
		pc.sc = u32(key)
		pc.mods = mods
	case "bindings":
		pc.kind = .BindingsGet
	case "fontsizeup":
		pc.kind = .FontSizeUp
	case "fontsizedown":
		pc.kind = .FontSizeDown
	case "reviewup":
		pc.kind = .ReviewUp
	case "reviewdown":
		pc.kind = .ReviewDown
	case "toggle-commandbar", "togglebar":
		pc.kind = .ToggleCommandBar
	case:
		return {}, false
	}
	return pc, true
}

// "mods+key" → scancode + 修饰;键名 = 最后一段(大小写不敏感,
// ScancodeFromName 内统一大写),mods 段 = alt/ctrl/shift/win(可零个,可重复出现)
parseKeyCombo :: proc(s : string) -> (key : inp.Scancode, mods : KeyMods, ok : bool) {
	if len(s) == 0 {
		return {}, {}, false
	}
	key_start := 0
	for i in 0 ..< len(s) {
		if s[i] == '+' {
			key_start = i + 1
		}
	}
	if key_start >= len(s) {
		return {}, {}, false
	}
	key, ok = inp.ScancodeFromName(s[key_start:])
	if !ok {
		return {}, {}, false
	}
	if key_start == 0 {
		return key, {}, true // 无修饰
	}
	mod_part := s[:key_start - 1]
	start := 0
	for i in 0 ..= len(mod_part) {
		if i == len(mod_part) || mod_part[i] == '+' {
			switch mod_part[start:i] {
			case "alt": mods += {.Alt}
			case "ctrl", "ctl": mods += {.Ctrl}
			case "shift": mods += {.Shift}
			case "win", "super": mods += {.Win}
			case: return {}, {}, false
			}
			start = i + 1
		}
	}
	return key, mods, true
}

// 修饰 → 字符串前缀("alt+shift+";空修饰 = "";借用调用方缓冲,仅调用期间有效)
modsPrefix :: proc(mods : KeyMods, buf : ^[32]u8) -> string {
	if mods == {} {
		return ""
	}
	n := 0
	if .Alt in mods {
		copy(buf[n:], "alt+")
		n += 4
	}
	if .Ctrl in mods {
		copy(buf[n:], "ctrl+")
		n += 5
	}
	if .Shift in mods {
		copy(buf[n:], "shift+")
		n += 6
	}
	if .Win in mods {
		copy(buf[n:], "win+")
		n += 4
	}
	return string(buf[:n])
}

// 键组合显示名("alt+shift+l";借用调用方缓冲,仅调用期间有效)
comboName :: proc(mods : KeyMods, key : inp.Scancode, buf : ^[64]u8) -> string {
	n := len(modsPrefix(mods, cast(^[32]u8)buf))
	kname := inp.ScancodeName(key)
	if n + len(kname) < len(buf) {
		copy(buf[n:], kname)
		n += len(kname)
	}
	return string(buf[:n])
}

// 拆分参数:支持 "..." 字符串;返回 tokens(借用 s 内存)
parseTokens :: proc(s : string, tokens : ^[16]string) -> int {
	count := 0
	i := 0
	for i < len(s) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i += 1
		}
		if i >= len(s) {
			break
		}
		if s[i] == '"' {
			start := i + 1
			j := start
			for j < len(s) && s[j] != '"' {
				j += 1
			}
			if count < 16 {
				tokens[count] = s[start:j]
				count += 1
			}
			i = j + 1
		} else {
			start := i
			for i < len(s) && s[i] != ' ' && s[i] != '\t' {
				i += 1
			}
			if count < 16 {
				tokens[count] = s[start:i]
				count += 1
			}
		}
	}
	return count
}

parseU32 :: proc(s : string) -> (u32, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v : u32
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + u32(c - '0')
	}
	return v, true
}

parseF32 :: proc(s : string) -> (f32, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := false
	start := 0
	if s[0] == '-' {
		neg = true
		start = 1
	}
	int_part : f32
	frac_part : f32
	frac_scale : f32 = 0.1
	seen_digit := false
	seen_dot := false
	for i in start ..< len(s) {
		c := s[i]
		if c == '.' && !seen_dot {
			seen_dot = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		seen_digit = true
		if !seen_dot {
			int_part = int_part * 10 + f32(c - '0')
		} else {
			frac_part += f32(c - '0') * frac_scale
			frac_scale *= 0.1
		}
	}
	if !seen_digit {
		return 0, false
	}
	v := int_part + frac_part
	if neg {
		v = -v
	}
	return v, true
}

parseSplitDir :: proc(s : string) -> (SplitType, bool) {
	switch s {
	case "right", "leftright", "h":
		return .LeftRight, true
	case "down", "updown", "v":
		return .UpDown, true
	}
	return {}, false
}

parseFocusDir :: proc(s : string) -> (FocusDirection, bool) {
	switch s {
	case "left":
		return .Left, true
	case "right":
		return .Right, true
	case "up":
		return .Up, true
	case "down":
		return .Down, true
	}
	return {}, false
}
