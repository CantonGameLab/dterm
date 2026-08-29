// ConPTY 输出抓取:启动命令(可交互),静置 N 秒后 dump 环形缓冲全部字节。
// 用法:odin run playground/oscapture/ -- claude
// 产出:dump.bin(原始字节,写到 cwd)+ dump_hex.txt(前 8KB hex 预览)
// 用途:分析应用(如 claude)发出的 VT 序列在 dterm 解析器下的问题。
package main

import ct "../../src/conpty"
import mem "../../src/memory"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

g_h : mem.Handle

main :: proc() {
	cmd := "claude"
	if len(os.args) > 1 {
		cmd = strings.join(os.args[1:], " ")
	}
	h, ok := ct.CreateConptyContext({120, 40}, cmd)
	if !ok {
		// CreateProcessW 对裸命令只认 .exe;claude 等 npm 脚本是 .cmd → 经 cmd.exe /c
		fmt.eprintln("direct launch failed, retry via cmd.exe /c:", cmd)
		cmd = fmt.tprintf("cmd.exe /c %s", cmd)
		h, ok = ct.CreateConptyContext({120, 40}, cmd)
	}
	if !ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	if !ct.StartReadThread(h) {
		fmt.eprintln("StartReadThread failed")
		return
	}
	fmt.println("capturing:", cmd, "| 20s(你可以直接输入,按键会转发给应用)")
	g_h = h
	t := thread.create(forwardThread)
	thread.start(t)
	time.sleep(20 * time.Second)

	rwd := ct.GetReadWriteData(h)
	buf : [64 * 1024]byte
	data : [dynamic]byte
	for {
		n := ct.RingPop(rwd, buf[:])
		if n <= 0 {
			break
		}
		append(&data, ..buf[:n])
	}
	ct.StopReadThread(h)
	fmt.println("captured", len(data), "bytes")

	_ = os.write_entire_file("dump.bin", data[:])
	out : strings.Builder
	for i in 0 ..< min(8192, len(data)) {
		if i % 16 == 0 {
			strings.write_string(&out, fmt.tprintf("%04X ", i))
		}
		b := data[i]
		if b >= 0x20 && b <= 0x7E {
			strings.write_rune(&out, rune(b))
		} else {
			strings.write_byte(&out, '.')
		}
		if i % 16 == 15 {
			strings.write_byte(&out, '\n')
		}
	}
	_ = os.write_entire_file("dump_hex.txt", transmute([]byte)strings.to_string(out))
	fmt.println("wrote dump.bin + dump_hex.txt (first 8KB) to cwd")
}

// 转发 stdin 键击到应用(简单阻塞转发;与主循环无共享状态)
forwardThread :: proc(t : ^thread.Thread) {
	buf : [512]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if n <= 0 || err != nil {
			return
		}
		ct.WriteConptyInput(g_h, buf[:n])
	}
}
