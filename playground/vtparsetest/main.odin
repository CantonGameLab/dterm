// vtparse 状态机隔离测试:喂已知序列,打印回调动作,验证切分正确。
package main

import vp "../../src/vtparse"
import "core:fmt"

cb :: proc(p : ^vp.Parser, action : vp.Action, ch : rune) {
	fmt.printf("  %-12s ch=0x%02x", action, u32(ch))
	if p.num_intermediate_chars > 0 {
		fmt.printf(" int=[")
		for i in 0 ..< p.num_intermediate_chars {
			fmt.printf("%c", p.intermediate_chars[i])
		}
		fmt.printf("]")
	}
	if p.num_params > 0 {
		fmt.printf(" params=[")
		for i in 0 ..< p.num_params {
			fmt.printf("%d,", p.params[i])
		}
		fmt.printf("]")
	}
	fmt.println()
}

main :: proc() {
	parser : vp.Parser
	vp.Init(&parser, cb)

	tests := []struct {
		name : string,
		data : string,
	}{
		{"普通文本", "hello"},
		{"UTF-8 中文", "你好"},
		{"SGR 红色", "\x1b[31m"},
		{"DA2 终端识别", "\x1b[>0c"},
		{"modifyOtherKeys", "\x1b[>4;2m"},
		{"DECRQM 模式查询", "\x1b[?25$p"},
		{"DEC 光标模式", "\x1b[?25h"},
		{"DECSCUSR 光标形状", "\x1b[2 q"},
		{"OSC 标题 BEL 终止", "\x1b]0;test\x07"},
		{"OSC ST 终止", "\x1b]0;test\x1b\\"},
		{"字符集", "\x1b(0"},
		{"方向键 CSI", "\x1b[A"},
		{"C1 控制", "\x1b\x9c"},
		{"ESC D IND", "\x1bD"},
		{"残留参数:无参序列必须 num_params=0", "\x1b[2J\x1b[H"},
		{"混合流", "ab\x1b[31mcd\x1b[0m你好"},
	}

	for t in tests {
		fmt.printf("== %s ==\n", t.name)
		vp.Parse(&parser, transmute([]byte)t.data)
		fmt.println()
	}
}
