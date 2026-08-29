// vtparse(已并入 canvas)状态机隔离测试:喂已知序列,打印回调动作,验证切分正确。
package main

import cv "../../src/canvas"
import "core:fmt"

cb :: proc(p : ^cv.Parser, action : cv.Action, ch : rune) {
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
		if p.num_subparams[0] > 1 {
			fmt.printf(" sub0=[")
			for i in 0 ..< int(p.num_subparams[0]) {
				fmt.printf("%d,", p.subparams[0][i])
			}
			fmt.printf("]")
		}
	}
	fmt.println()
}

main :: proc() {
	parser : cv.Parser
	cv.Init(&parser, cb)

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
		// P0 修复验证:
		// ① 截断 UTF-8(缺续字节)后的 ESC 不能被吞:ESC[31m 必须完整 dispatch
		{"截断 UTF-8 不吞 ESC", "\xE4\x1B[31m"},
		// ② 非法起始(overlong C0 / 越界 F6)被忽略,后续正常文本继续打印
		{"非法 UTF-8 起始忽略", "ab\xC0\xF6cd"},
		// ③ 参数钳制到 65535(之后仅剩小参数)
		{"参数钳制 65535", "\x1b[1234567890123456789012;5M"},
		// ④ OSC 字符串内的 UTF-8 字节保留(不再被丢弃)
		{"OSC 内 UTF-8", "\x1b]0;你好\x07"},
		// ⑤ OSC 截断后由 BEL 正常终止,剩余文本不丢
		{"OSC 截断后 BEL 终止", "\x1b]0;\xE4\x07ok"},
		// P1 子参数验证:
		// ⑥ 冒号式子参组 [38,2,0,r,g,b](cs 槽在 index 2)
		{"SGR 冒号 RGB 子参", "\x1b[38:2::255:0:0m"},
		// ⑦ 冒号式 256 索引 [38,5,0,n] 与 [38,5,n] 均取末位
		{"SGR 冒号 256 子参", "\x1b[38:5::100m"},
		// ⑧ 分号式保持扁平参数(每组 1 个子参)
		{"SGR 分号 RGB", "\x1b[38;2;1;2;3m"},
		// ⑨ 混用:第 2 组带子参,其余组扁平
		{"SGR 子参混用", "\x1b[1;38:2::12:34:56;4m"},
	}

	for t in tests {
		fmt.printf("== %s ==\n", t.name)
		cv.Parse(&parser, transmute([]byte)t.data)
		fmt.println()
	}
}
