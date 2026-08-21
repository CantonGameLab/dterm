// 模拟 opencode:启动时设置 Win32 输入模式(9001)+ 焦点事件(1004)+ 鼠标追踪,
// 退出时不恢复这些模式(复现 opencode 泄漏),观察 ConPTY 是否卡死。
package main

import win "core:sys/windows"
import "core:c"
import "core:fmt"
import "core:os"

main :: proc() {
	// 输出:opencode 启动序列(泄漏模式)
	seq := "\x1b[?9001h\x1b[?1004h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?25l\x1b[2J\x1b[Hhello opencode simulation\r\n"
	hout := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	written : win.DWORD
	win.WriteFile(hout, raw_data(seq), u32(len(seq)), &written, nil)

	// 等 2 秒模拟运行
	win.Sleep(2000)

	// opencode 退出:只恢复光标,泄漏其他模式
	exit_seq := "\x1b[?25h\x1b[0mbye\r\n"
	win.WriteFile(hout, raw_data(exit_seq), u32(len(exit_seq)), &written, nil)
	fmt.println("simulated opencode exit")
	os.exit(0)
}
