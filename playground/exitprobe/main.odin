// 验证:正常 exit 后,main 的会话结束检测(Job 归零 || 读线程断开)能否触发。
// 修复前:只依赖读线程断开,而 ConPTY 管道在子进程退出后不产生 EOF,
// 读线程永久阻塞 → exit 后终端卡死不退出。
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:time"

main :: proc() {
	conpty_h, ok := ct.CreateConptyContext({80, 24}, "cmd.exe")
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

	time.sleep(800 * time.Millisecond)
	exit_cmd := "exit\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)exit_cmd)

	// 模拟 main 主循环的会话结束检测,最多 8 秒
	for i in 0 ..< 80 {
		jobs := ct.JobActiveProcesses(conpty_h)
		read_alive := ct.IsReadThreadAlive(conpty_h)
		if jobs == 0 || !read_alive {
			fmt.printf("PASS: session ended at t=%dms (jobs=%d read_alive=%v)\n", i*100, jobs, read_alive)
			return
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.println("FAIL: session never ended(卡死复现)")
}
