package conpty

import "core:fmt"
import "core:c"
import win "core:sys/windows"
import mem "../memory"


ConptyContext :: struct {
	hpc          : HPCON,
	read_conpty  : win.HANDLE, // 读子进程输出(VT 序列)
	write_conpty : win.HANDLE, // 写键盘输入
	proc_info    : win.PROCESS_INFORMATION,
	child_procid : win.DWORD,
}

MAX_CONPTY_SLOTS :: 16

conpty_contexts : mem.GenArray(MAX_CONPTY_SLOTS, ConptyContext)

CreateConptyContext :: proc(size : win.COORD, cmd : string) -> (h : mem.Handle, ok : bool) {
	ctx, created := createConptyContextValue(size, cmd)
	if !created {
		return {}, false
	}
	h = mem.Alloc(&conpty_contexts, ctx)
	if h.id == 0 {
		destroyConptyContext(&ctx)
		return {}, false
	}
	return h, true
}

GetConptyContext :: proc(h : mem.Handle) -> ^ConptyContext {
	return mem.Get(&conpty_contexts, h)
}

createConptyContextValue :: proc(size: win.COORD, cmd: string) -> (ctx: ConptyContext, ok: bool = false) {
	conpty_side_read : win.HANDLE // ConPTY 端读(子进程键盘事件)
	main_side_write  : win.HANDLE // 我们写键盘输入
	main_side_read   : win.HANDLE // 我们读输出
	conpty_side_write: win.HANDLE // ConPTY 端写(发给子进程)

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
		destroyConptyContext(&ctx)
		return
	}
	if !InitializeProcThreadAttributeList(start_info.lpAttributeList, 1, 0, &attr_size) {
		destroyConptyContext(&ctx)
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
		destroyConptyContext(&ctx)
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
		destroyConptyContext(&ctx)
		DeleteProcThreadAttributeList(start_info.lpAttributeList)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}
	ctx.child_procid = ctx.proc_info.dwProcessId

	// hThread 不再需要;hProcess 保留用于等待/终止
	win.CloseHandle(ctx.proc_info.hThread)
	ctx.proc_info.hThread = win.INVALID_HANDLE_VALUE

	DeleteProcThreadAttributeList(start_info.lpAttributeList)
	win.HeapFree(heap, 0, start_info.lpAttributeList)
	return ctx, true
}

readConptyOutput :: proc(conpty_context: ^ConptyContext, buf: []byte) -> (n: u32, ok: bool) {
	if conpty_context.read_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_we_read: win.DWORD
	if !win.ReadFile(conpty_context.read_conpty, raw_data(buf), u32(len(buf)), &bytes_we_read, nil) {
		return 0, false
	}
	return bytes_we_read, true
}

// 回显由终端负责;直接传 UTF-8 字节
WriteConptyInput :: proc(h : mem.Handle, data: []byte) -> (n: u32, ok: bool) {
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return 0, false
	}
	if conpty_context.write_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_written: win.DWORD
	if !win.WriteFile(conpty_context.write_conpty, raw_data(data), u32(len(data)), &bytes_written, nil) {
		return 0, false
	}
	return bytes_written, true
}

// 窗口缩放时:cols = 像素宽/单元宽,rows = 像素高/单元高
Resize :: proc(h : mem.Handle, cols, rows: u16) -> bool {
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return false
	}
	hr := resizePseudoConsole(conpty_context.hpc, win.COORD{win.SHORT(cols), win.SHORT(rows)})
	return hr == win.HRESULT(0)
}

IsChildAlive :: proc(h : mem.Handle) -> bool {
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return false
	}
	if conpty_context.proc_info.hProcess == win.INVALID_HANDLE_VALUE {
		return false
	}
	code: win.DWORD
	if !win.GetExitCodeProcess(conpty_context.proc_info.hProcess, &code) {
		return false
	}
	return code == STILL_ACTIVE
}

DestroyConpty :: proc(h : mem.Handle) {
	ctx := GetConptyContext(h)
	if ctx == nil {
		return
	}
	destroyConptyContext(ctx)
	mem.Free(&conpty_contexts, h)
}

// 供创建失败回滚使用(槽位尚未登记完成)
destroyConptyContext :: proc(conpty_context: ^ConptyContext) {
	if conpty_context == nil {
		return
	}
	if conpty_context.hpc != nil {
		closePseudoConsole(conpty_context.hpc)
		conpty_context.hpc = nil
	}
	if conpty_context.read_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(conpty_context.read_conpty) // 阻塞中的 read 立即返回 false
		conpty_context.read_conpty = win.INVALID_HANDLE_VALUE
	}
	if conpty_context.write_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(conpty_context.write_conpty)
		conpty_context.write_conpty = win.INVALID_HANDLE_VALUE
	}
	if conpty_context.proc_info.hProcess != win.INVALID_HANDLE_VALUE {
		if win.WaitForSingleObject(conpty_context.proc_info.hProcess, 3000) != win.WAIT_OBJECT_0 {
			win.TerminateProcess(conpty_context.proc_info.hProcess, 1)
			win.WaitForSingleObject(conpty_context.proc_info.hProcess, win.INFINITE)
		}
		win.CloseHandle(conpty_context.proc_info.hProcess)
		conpty_context.proc_info.hProcess = win.INVALID_HANDLE_VALUE
	}
}
