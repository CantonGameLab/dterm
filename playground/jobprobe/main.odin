// 调试 Job Object:创建 ConPTY + Job,打印活动进程数与 AssignProcess 结果
package main

import ct "../../src/conpty"
import win "core:sys/windows"
import "core:fmt"
import "core:time"

main :: proc() {
	conpty_h, ok := ct.CreateConptyContext({80, 24}, "C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start")
	if !ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(conpty_h)
	ct.StartReadThread(conpty_h)
	defer ct.StopReadThread(conpty_h)

	for i in 0 ..< 6 {
		alive := ct.IsChildAlive(conpty_h)
		fmt.printf("t=%ds job alive=%v\n", i, alive)
		time.sleep(1 * time.Second)
	}
}
