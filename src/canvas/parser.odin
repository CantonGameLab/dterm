// 指令语法解析:字符串 → 直接调用 canvas 用户接口(window.odin)。
// 供控制台交互 / 子进程 ANSI 指令通道使用。薄分派层,无 undo / 无历史栈。
// 语法:命令名 参数... [@id]
//   - 参数按空格分隔,"..." 包裹字符串
//   - @id 放末尾指定目标节点(缺省 = 当前焦点)
// 例:split right 0.5 / focus left / font "a.ttf" 40 / launch "cmd.exe" @3
package canvas

import "core:fmt"
import "core:strings"
import mem "../memory"

// 执行命令字符串;查询类命令的结果经 out 回调回传(控制台显示用)。
// 返回 false = 语法错误或执行失败。
ExecuteCommandString :: proc(s : string, out : proc(msg : string) = nil) -> bool {
	cmd, ok := ParseCommandString(s)
	if !ok {
		return false
	}
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
	case .Exchange:
		return ExchangeWindow(cmd.fdir, cmd.target)
	case .Font:
		return SetWindowFont(cmd.sval, cmd.fval, cmd.target)
	case .Launch:
		return LaunchConsole(cmd.sval, cmd.target)
	case .Feed:
		return FeedConsole(transmute([]u8)cmd.sval, cmd.target)
	case .AutoClose:
		return SetAutoClose(cmd.bval, cmd.target)
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

// 解析结果:按 kind 判别取用字段
CommandStringKind :: enum u8 {
	Split,
	FocusId,
	FocusDir,
	Destroy,
	Factor,
	Exchange,
	Font,
	Launch,
	Feed,
	AutoClose,
	Count,
	FocusGet,
}

ParsedCommand :: struct {
	kind : CommandStringKind,
	target : mem.Handle, // @id 解析出的节点(带世代);0 = 焦点
	dir : SplitType, // Split 用
	fdir : FocusDirection, // Focus/Exchange 用
	fval : f32, // Factor/Font
	bval : bool, // AutoClose
	sval : string, // Font path / Launch cmd / Feed 文本(借用输入内存)
}

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
	case:
		return {}, false
	}
	return pc, true
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
