package conpty

import "core:fmt"
import "core:c"
import win "core:sys/windows"

STILL_ACTIVE :: 0x00000103 // GetExitCodeProcess 中进程仍存活

ConptyCtx :: struct {
	hpc          : HPCON,               // 伪控制台句柄（ConPTY 本身）
	read_conpty  : win.HANDLE,          // 主侧读管道：子进程输出（VT 序列）从这里读
	write_conpty : win.HANDLE,          // 主侧写管道：键盘输入从这里写
	proc_info    : win.PROCESS_INFORMATION, // 子进程句柄（hProcess 用于等待/终止）
	child_procid : win.DWORD,
}

// 创建伪控制台并启动子进程。
//
// 管道拓扑：
//   子进程(conhost) <--> [ConPTY] <--> 主侧管道 <--> 本进程
//                     hInput/hOutput      read_conpty / write_conpty
//
// 之后：
//   - read_output / write_input 读写管道
//   - resize 改终端字符行列数
//   - destroy 关闭一切
createVirtualConsole :: proc(size: win.COORD, cmd: string) -> (ctx: ConptyCtx, ok: bool = false) {
	conpty_side_read : win.HANDLE // ConPTY 的输入（来自子进程键盘事件）
	main_side_write  : win.HANDLE // 我们写键盘输入
	main_side_read   : win.HANDLE // 我们读输出（VT 序列）
	conpty_side_write: win.HANDLE // ConPTY 的输出（发给子进程）

	// 注意：主侧两个句柄由调用方（destroy）关闭；conpty 侧两个句柄随
	// ClosePseudoConsole 自动失效，不要手动关。
	if !win.CreatePipe(&conpty_side_read, &main_side_write, nil, 0) {
		return
	}
	if !win.CreatePipe(&main_side_read, &conpty_side_write, nil, 0) {
		win.CloseHandle(conpty_side_read)
		win.CloseHandle(main_side_write)
		return
	}

	hpc, hr := createPseudoConsole(size, conpty_side_read, conpty_side_write, 0)
	if hr != win.HRESULT(0) {
		fmt.eprintln("CreatePseudoConsole Failed")
		win.CloseHandle(conpty_side_read)
		win.CloseHandle(main_side_write)
		win.CloseHandle(main_side_read)
		win.CloseHandle(conpty_side_write)
		return
	}
	// 成功：conpty 侧句柄归 ConPTY 所有，不再由我们关闭

	ctx.hpc          = hpc
	ctx.read_conpty  = main_side_read
	ctx.write_conpty = main_side_write

	start_info: STARTUPINFOEXW
	start_info.StartupInfo.cb = size_of(start_info)

	attr_size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)

	heap := win.GetProcessHeap()
	start_info.lpAttributeList = cast(LPPROC_THREAD_ATTRIBUTE_LIST) win.HeapAlloc(heap, 0, attr_size)
	if start_info.lpAttributeList == nil {
		destroy(&ctx)
		return
	}
	if !InitializeProcThreadAttributeList(start_info.lpAttributeList, 1, 0, &attr_size) {
		destroy(&ctx)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}
	if !UpdateProcThreadAttribute(
		start_info.lpAttributeList,
		0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		cast(rawptr) hpc,
		size_of(HPCON),
		nil,
		nil,
	) {
		destroy(&ctx)
		DeleteProcThreadAttributeList(start_info.lpAttributeList)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}

	cmd_wide := win.utf8_to_wstring(cmd)

	if !win.CreateProcessW(
		nil,
		cmd_wide,
		nil,
		nil,
		false,
		win.EXTENDED_STARTUPINFO_PRESENT,
		nil,
		nil,
		&start_info.StartupInfo,
		&ctx.proc_info,
	) {
		err := win.GetLastError()
		fmt.eprintfln("CreateProcessW Failed: %v", err)
		destroy(&ctx)
		DeleteProcThreadAttributeList(start_info.lpAttributeList)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}
	ctx.child_procid = ctx.proc_info.dwProcessId

	// hThread 不再需要；hProcess 保留用于等待/终止（destroy 时关闭）
	win.CloseHandle(ctx.proc_info.hThread)
	ctx.proc_info.hThread = win.INVALID_HANDLE_VALUE

	DeleteProcThreadAttributeList(start_info.lpAttributeList)
	win.HeapFree(heap, 0, start_info.lpAttributeList)
	return ctx, true
}

// ---------------------------------------------------------------------------
// 交互
// ---------------------------------------------------------------------------

// 阻塞读取子进程输出（VT 转义序列字节流）。无数据时挂起；
// 管道被 destroy 关闭或子进程退出时返回 false，读取线程据此结束。
// 应在专用线程中调用，读到的字节交给 VT 解析器处理。
read_output :: proc(ctx: ^ConptyCtx, buf: []byte) -> (n: u32, ok: bool) {
	if ctx.read_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_read: win.DWORD
	if !win.ReadFile(ctx.read_conpty, raw_data(buf), u32(len(buf)), &bytes_read, nil) {
		return 0, false
	}
	return bytes_read, true
}

// 写入输入到子进程。终端会回显，无需本地回显。
// 直接传 UTF-8 字节即可（如键盘事件拼接的字符串）。
write_input :: proc(ctx: ^ConptyCtx, data: []byte) -> (n: u32, ok: bool) {
	if ctx.write_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_written: win.DWORD
	if !win.WriteFile(ctx.write_conpty, raw_data(data), u32(len(data)), &bytes_written, nil) {
		return 0, false
	}
	return bytes_written, true
}

// 调整终端尺寸（字符行列）。窗口缩放时调用：
//   cols = 像素宽 / 单元宽，rows = 像素高 / 单元高
resize :: proc(ctx: ^ConptyCtx, cols, rows: u16) -> bool {
	hr := resizePseudoConsole(ctx.hpc, win.COORD{win.SHORT(cols), win.SHORT(rows)})
	return hr == win.HRESULT(0)
}

// 子进程是否仍在运行
child_alive :: proc(ctx: ^ConptyCtx) -> bool {
	if ctx.proc_info.hProcess == win.INVALID_HANDLE_VALUE {
		return false
	}
	code: win.DWORD
	if !win.GetExitCodeProcess(ctx.proc_info.hProcess, &code) {
		return false
	}
	return code == STILL_ACTIVE
}

// 销毁虚拟终端：先关 ConPTY（子进程读管道断开，自行退出），
// 超时未退再强杀，最后回收所有句柄。
destroy :: proc(ctx: ^ConptyCtx) {
	if ctx.hpc != nil {
		closePseudoConsole(ctx.hpc)
		ctx.hpc = nil
	}
	if ctx.read_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(ctx.read_conpty) // 阻塞中的 read_output 立即返回 false
		ctx.read_conpty = win.INVALID_HANDLE_VALUE
	}
	if ctx.write_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(ctx.write_conpty)
		ctx.write_conpty = win.INVALID_HANDLE_VALUE
	}
	if ctx.proc_info.hProcess != win.INVALID_HANDLE_VALUE {
		if win.WaitForSingleObject(ctx.proc_info.hProcess, 3000) != win.WAIT_OBJECT_0 {
			win.TerminateProcess(ctx.proc_info.hProcess, 1)
			win.WaitForSingleObject(ctx.proc_info.hProcess, win.INFINITE)
		}
		win.CloseHandle(ctx.proc_info.hProcess)
		ctx.proc_info.hProcess = win.INVALID_HANDLE_VALUE
	}
}
