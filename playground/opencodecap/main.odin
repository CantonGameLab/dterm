// 复现 opencode 退出后 ConPTY 卡死:启动 opencode → ESC 退出 → 抓取后续输出
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	cmd := "cmd.exe /c opencode"
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

	// 抓启动输出
	time.sleep(6 * time.Second)
	for {
		n := ct.RingPop(data, buf)
		if n == 0 {
			break
		}
		fmt.printf("STARTUP: %s\n", string(buf[:n]))
	}

	// 发 ESC 退出 opencode
	esc := []u8{0x1B}
	ct.WriteConptyInput(conpty_h, esc)
	time.sleep(2 * time.Second)

	// 抓退出后的输出
	out := make([dynamic]u8, 0, 65536)
	defer delete(out)
	deadline := time.time_add(time.now(), 5 * time.Second)
	for time.diff(time.now(), deadline) > 0 {
		n := ct.RingPop(data, buf)
		if n == 0 {
			time.sleep(50 * time.Millisecond)
			continue
		}
		append(&out, ..buf[:n])
	}
	fmt.printf("AFTER_EXIT bytes=%d\n", len(out))
	ok_write := os.write_entire_file("playground/vtcapture/opencode_exit.bin", out[:])
	fmt.println("write ok=", ok_write)

	// 检查子进程是否还活着
	alive := ct.IsChildAlive(conpty_h)
	fmt.printf("child alive after exit: %v\n", alive)
	time.sleep(3 * time.Second)
	alive2 := ct.IsChildAlive(conpty_h)
	fmt.println("child alive 3s later:", alive2)
}
