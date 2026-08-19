// 抓取真实终端程序启动输出到文件,供 vtreplay 回放分析。
// 用法:odin run playground/vtcapture/ [命令]  默认抓 bash
// 例:odin run playground/vtcapture/ "C:\Program Files\Neovim\bin\nvim.exe C:\Users\GroupTheory\test.txt"
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	cmd := "C:\\msys64\\usr\\bin\\bash.exe --noprofile -i"
	when #config(vt_capture_nvim, false) {
		cmd = "C:\\Program Files\\Neovim\\bin\\nvim.exe -u NONE -i NONE -n C:\\Users\\GroupTheory\\Source\\dterm\\src\\main.odin"
	}
	when #config(vt_capture_zsh, false) {
		cmd = "C:\\msys64\\usr\\bin\\zsh.exe"
	}
	if len(os.args) > 1 {
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for i in 1 ..< len(os.args) {
			if i > 1 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, os.args[i])
		}
		cmd = strings.to_string(sb)
	}
	fmt.printf("capturing: %s\n", cmd)

	conpty_h, ok := ct.CreateConptyContext({80, 24}, cmd)
	if !ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(conpty_h)

	if !ct.StartReadThread(conpty_h) {
		fmt.eprintln("StartReadThread failed")
		return
	}
	defer ct.StopReadThread(conpty_h)

	// 等 4 秒让 bash 打完提示符
	time.sleep(4 * time.Second)

	data := ct.GetReadWriteData(conpty_h)
	buf := make([]u8, 1024)
	defer delete(buf)
	out := make([dynamic]u8, 0, 64 * 1024)
	defer delete(out)

	for {
		n := ct.RingPop(data, buf)
		if n == 0 {
			break
		}
		append(&out, ..buf[:n])
	}

	fmt.printf("captured %d bytes\n", len(out))
	if len(out) == 0 {
		return
	}

	_ = os.write_entire_file("playground/vtcapture/capture.bin", out[:])

	// 可读转储:转义可视化
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for b in out {
		switch b {
		case 0x1b: strings.write_string(&sb, "<ESC>")
		case 0x07: strings.write_string(&sb, "<BEL>")
		case 0x0d: strings.write_string(&sb, "<CR>")
		case 0x0a: strings.write_string(&sb, "<LF>\n")
		case 0x09: strings.write_string(&sb, "<TAB>")
		case 0x00 ..= 0x1f:
			fmt.sbprintf(&sb, "<%02x>", b)
		case:
			strings.write_byte(&sb, b)
		}
	}
	_ = os.write_entire_file("playground/vtcapture/capture.txt", strings.to_string(sb))
	fmt.println("written capture.bin / capture.txt")
}
