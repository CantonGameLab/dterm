// 复现:ConPTY 跑 cmd,再运行 modeleak(泄漏 9001/1004/鼠标模式),退出后
// 检查 shell 是否还能产生输出(模拟 opencode 卡死场景)。
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	cmd := "cmd.exe /c echo SHELL_START && C:\\Users\\GroupTheory\\Source\\dterm\\playground\\modeleak\\modeleak.exe && echo SHELL_AFTER && dir C:\\Windows\\win.ini"
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

	data := ct.GetReadWriteData(conpty_h)
	buf := make([]u8, 4096)
	defer delete(buf)

	// 抓全部输出直到超时
	out := make([dynamic]u8, 0, 65536)
	defer delete(out)
	deadline := time.time_add(time.now(), 12 * time.Second)
	last_data := time.now()
	for time.diff(time.now(), deadline) > 0 {
		n := ct.RingPop(data, buf)
		if n == 0 {
			if time.diff(last_data, time.now()) > 3 * time.Second {
				fmt.println("NO DATA for 3s (frozen?)")
				break
			}
			time.sleep(50 * time.Millisecond)
			continue
		}
		last_data = time.now()
		append(&out, ..buf[:n])
	}
	fmt.printf("total bytes=%d\n", len(out))
	// 打印关键标记
	s := string(out[:])
	markers := []string{"SHELL_START", "hello opencode", "bye", "SHELL_AFTER", "win.ini"}
	for marker in markers {
		found := false
		for i in 0 ..= len(s) - len(marker) {
			if s[i:i+len(marker)] == marker {
				found = true
				break
			}
		}
		fmt.printf("  marker %q: %v\n", marker, found)
	}
}
