// 关键测试:msys2 bash 中泄漏 9001h 后,VT 文本输入是否仍有效
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:time"

main :: proc() {
	cmd := "C:\\msys64\\usr\\bin\\bash.exe --noprofile -i"
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

	drain :: proc(data : ^ct.ReadWriteData, buf : []u8, ms : int) {
		deadline := time.time_add(time.now(), time.Duration(ms) * time.Millisecond)
		for time.diff(time.now(), deadline) > 0 {
			n := ct.RingPop(data, buf)
			if n > 0 {
				fmt.printf("<< %q\n", string(buf[:n]))
			} else {
				time.sleep(20 * time.Millisecond)
			}
		}
	}

	// 启动
	drain(data, buf, 1000)
	// 先测正常输入
	s1 := "echo BEFORE\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)s1)
	drain(data, buf, 1500)
	// 直接发送 9001h + 1004h(模拟 opencode 泄漏)
	s2 := "printf '\\x1b[?9001h\\x1b[?1004h'\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)s2)
	drain(data, buf, 1500)
	// 泄漏后输入
	s3 := "echo AFTER_LEAK\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)s3)
	drain(data, buf, 2000)
	// 泄漏后方向键(转义序列输入)
	s4 := "\x1b[A"
	ct.WriteConptyInput(conpty_h, transmute([]u8)s4)
	drain(data, buf, 1000)
	fmt.println("done")
}
