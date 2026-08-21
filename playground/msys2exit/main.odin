// msys2 场景诊断:bash 启动后 Job 计数是否稳定 >0(排除 breakaway 误报),
// 以及 exit 后 Job 是否归零、读线程是否退出。
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:time"

main :: proc() {
	conpty_h, ok := ct.CreateConptyContext({80, 24}, "C:\\msys64\\msys2_shell.cmd -ucrt64 -defterm -here -full-path -no-start")
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

	// bash 启动期间观察 Job 计数
	for i in 0 ..< 5 {
		fmt.printf("t=%ds jobs=%d child_alive=%v read_alive=%v\n",
			i, ct.JobActiveProcesses(conpty_h), ct.IsChildAlive(conpty_h), ct.IsReadThreadAlive(conpty_h))
		time.sleep(1 * time.Second)
	}

	// 发 exit
	exit_cmd := "exit\r\n"
	ct.WriteConptyInput(conpty_h, transmute([]u8)exit_cmd)

	for i in 0 ..< 8 {
		jobs := ct.JobActiveProcesses(conpty_h)
		read_alive := ct.IsReadThreadAlive(conpty_h)
		fmt.printf("after exit t=%ds jobs=%d read_alive=%v\n", i, jobs, read_alive)
		if jobs == 0 || !read_alive {
			fmt.println("SESSION ENDED")
			return
		}
		time.sleep(1 * time.Second)
	}
	fmt.println("STILL RUNNING")
}
