// 测输入侧:ConPTY 跑 cmd,注入 modeleak(泄漏 9001h),随后向 ConPTY 写命令,
// 检查 shell 是否响应(模拟 opencode 退出后键盘输入卡死)。
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	cmd := "cmd.exe"
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
	drain(data, buf, 500)
	// 运行 modeleak(泄漏 9001h + 鼠标模式)
	leak_cmd := "C:\\Users\\GroupTheory\\Source\\dterm\\playground\\modeleak\\modeleak.exe\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)leak_cmd)
	drain(data, buf, 3000)
	// 泄漏后:发送简单命令,看 shell 是否响应
	cmd2 := "echo INPUT_AFTER_LEAK\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)cmd2)
	drain(data, buf, 3000)
	// 再发一条
	cmd3 := "echo KEY_AFTER_LEAK\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)cmd3)
	drain(data, buf, 3000)
	fmt.println("done")
}
