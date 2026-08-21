// 抓取真实终端程序启动输出到文件,供 vtreplay 回放分析。
// 用法:odin run playground/vtcapture/ [命令]  默认抓 bash
// 例:odin run playground/vtcapture/ "C:\Program Files\Neovim\bin\nvim.exe C:\Users\GroupTheory\test.txt"
// vttest 模式:odin run playground/vtcapture/ -define:vt_capture_vttest=true
//   自动按键驱动 vttest 主菜单(1=光标测试 2=屏幕特性),全程抓取
package main

import ct "../../src/conpty"
import mem "../../src/memory"
import win "core:sys/windows"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	cmd := "C:\\msys64\\usr\\bin\\bash.exe --noprofile -i"
	drive_vttest := false
	when #config(vt_capture_nvim, false) {
		cmd = "C:\\Program Files\\Neovim\\bin\\nvim.exe -u NONE -i NONE -n C:\\Users\\GroupTheory\\Source\\dterm\\src\\main.odin"
	}
	when #config(vt_capture_zsh, false) {
		cmd = "C:\\msys64\\usr\\bin\\zsh.exe"
	}
	when #config(vt_capture_vttest, false) {
		cmd = "C:\\Users\\GroupTheory\\Source\\dterm\\reference\\vttest\\vttest.exe -c C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest_cmds.txt -l C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest.log"
		drive_vttest = true
	}
	when #config(vt_capture_vttest1, false) { // 只跑测试 1(光标)
		cmd = "C:\\Users\\GroupTheory\\Source\\dterm\\reference\\vttest\\vttest.exe -c C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest_cmds1.txt -l C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest.log"
		drive_vttest = true
	}
	when #config(vt_capture_vttest2, false) { // 只跑测试 2(屏幕特性)
		cmd = "C:\\Users\\GroupTheory\\Source\\dterm\\reference\\vttest\\vttest.exe -c C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest_cmds2.txt -l C:\\Users\\GroupTheory\\Source\\dterm\\playground\\vtcapture\\vttest.log"
		drive_vttest = true
	}
	when #config(vt_capture_yazi, false) {
		cmd = "C:\\Users\\GroupTheory\\AppData\\Local\\Programs\\yazi\\yazi-x86_64-pc-windows-msvc\\yazi.exe"
	}
	when #config(vt_capture_pwsh, false) { // 检测 ConPTY 子进程的终端能力
		cmd = "powershell.exe -NoProfile -Command \"Add-Type -Namespace W -Name C -MemberDefinition '[DllImport(\\\"kernel32.dll\\\")] public static extern IntPtr GetStdHandle(int n); [DllImport(\\\"kernel32.dll\\\")] public static extern bool GetConsoleMode(IntPtr h, out uint m);'; $h = [W.C]::GetStdHandle(-11); $m = 0; $r = [W.C]::GetConsoleMode($h, [ref]$m); Write-Output ('GetConsoleMode: {0} Mode: 0x{1:X}' -f $r, $m)\""
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

	// 沙箱注入的 NO_COLOR 会禁用 yazi 等应用的颜色输出;测试时移除
	win.SetEnvironmentVariableW(win.LPCWSTR("NO_COLOR"), nil)

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

	if drive_vttest {
		driveVttest(conpty_h)
	} else {
		time.sleep(4 * time.Second)
	}

	data := ct.GetReadWriteData(conpty_h)
	buf := make([]u8, 1024)
	defer delete(buf)
	out := make([dynamic]u8, 0, 256 * 1024)
	defer delete(out)

	for {
		n := ct.RingPop(data, buf)
		if n == 0 {
			break
		}
		append(&out, ..buf[:n])
	}

	out_name := "playground/vtcapture/capture.bin"
	txt_name := "playground/vtcapture/capture.txt"
	when #config(vt_capture_vttest1, false) {
		out_name = "playground/vtcapture/capture_vttest1.bin"
		txt_name = "playground/vtcapture/capture_vttest1.txt"
	}
	when #config(vt_capture_vttest2, false) {
		out_name = "playground/vtcapture/capture_vttest2.bin"
		txt_name = "playground/vtcapture/capture_vttest2.txt"
	}

	fmt.printf("captured %d bytes\n", len(out))
	if len(out) == 0 {
		return
	}

	_ = os.write_entire_file(out_name, out[:])

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
	_ = os.write_entire_file(txt_name, strings.to_string(sb))
	fmt.printf("written %s\n", out_name)
}

// cmdfile 驱动 vttest:Setup 阶段由 Wait/Done 对覆盖,菜单/测试推进由 Read: 行提供
driveVttest :: proc(conpty_h : mem.Handle) {
	// 等待 vttest 完成 Setup + 测试 1(光标)+ 测试 2(屏幕特性)+ 退出
	time.sleep(40 * time.Second)
}
