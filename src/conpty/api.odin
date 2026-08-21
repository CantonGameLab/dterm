package conpty

import win "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

HPCON :: rawptr
PROC_THREAD_ATTRIBUTE_LIST :: rawptr
LPPROC_THREAD_ATTRIBUTE_LIST :: ^PROC_THREAD_ATTRIBUTE_LIST

PSEUDOCONSOLE_INHERIT_CURSOR :: 1
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016 //虚拟终端属性记号
STILL_ACTIVE :: 0x00000103 // GetExitCodeProcess 中进程仍存活

// Job Object(进程树管理):core:sys/windows 未绑定,此处静态绑定 kernel32
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
JOBOBJECTINFOCLASS_BASIC_ACCOUNTING :: 1
JOBOBJECTINFOCLASS_EXTENDED_LIMIT :: 9

// 查询信息类 JobObjectBasicAccountingInformation 的返回结构
JobObjectBasicAccountingInfo :: struct {
	total_user_time, total_kernel_time : i64,
	this_period_total_user_time, this_period_total_kernel_time : i64,
	total_page_fault_count, total_processes : u32,
	active_processes, total_terminated_processes : u32,
}

// SetInformationJobObject 类 JobObjectExtendedLimitInformation 的输入结构
// (仅 LimitFlags 字段有意义,其余保持 0)
JobObjectBasicLimitInformation :: struct {
	per_process_user_time_limit, per_process_kernel_time_limit : i64,
	limit_flags : u32,
	minimum_working_set_size, maximum_working_set_size : win.SIZE_T,
	active_process_limit : u32,
	affinity : win.SIZE_T,
	priority_class : u32,
	scheduling_class : u32,
}

JobObjectExtendedLimitInfo :: struct {
	basic_limit : JobObjectBasicLimitInformation,
	io_info     : [7]u64, // IO_COUNTERS
	process_mem : [3]win.SIZE_T,
	job_mem     : [4]win.SIZE_T,
	peer_handle : win.HANDLE,
}

STARTUPINFOEXW :: struct {
	StartupInfo: win.STARTUPINFOW,
	lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
}

foreign kernel32 {
	@(link_name="CreatePseudoConsole")
	_CreatePseudoConsole :: proc(
		size:    win.COORD,
		hInput:  win.HANDLE,
		hOutput: win.HANDLE,
		dwFlags: win.DWORD,
		phPC:    ^HPCON,
	) -> win.HRESULT ---

	@(link_name="ResizePseudoConsole")
	_ResizePseudoConsole :: proc(
		hPC:  HPCON,
		size: win.COORD,
	) -> win.HRESULT ---

	@(link_name="ClosePseudoConsole")
	_ClosePseudoConsole :: proc(hPC: HPCON) ---
	@(link_name="InitializeProcThreadAttributeList")
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
		dwAttributeCount: win.DWORD,
		dwFlags: win.DWORD,
		lpSize: ^win.SIZE_T,
	) -> win.BOOL ---

	@(link_name="UpdateProcThreadAttribute")
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
		dwFlags: win.DWORD,
		Attribute: win.DWORD_PTR,
		lpValue: rawptr,
		cbSize: win.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize: ^win.SIZE_T,
	) -> win.BOOL ---

	@(link_name="DeleteProcThreadAttributeList")
	DeleteProcThreadAttributeList :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
	) ---

	@(link_name="CreateJobObjectW")
	CreateJobObjectW :: proc(lpJobAttributes: ^win.SECURITY_ATTRIBUTES, lpName: win.LPCWSTR) -> win.HANDLE ---
	@(link_name="SetInformationJobObject")
	SetInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJOB_OBJECT_INFOLength: win.DWORD) -> i32 ---
	@(link_name="AssignProcessToJobObject")
	AssignProcessToJobObject :: proc(hJob, hProcess: win.HANDLE) -> i32 ---
	@(link_name="QueryInformationJobObject")
	QueryInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJOB_OBJECT_INFOLength: win.DWORD, lpReturnLength: ^win.DWORD) -> i32 ---
}

createPseudoConsole :: proc(
	size : win.COORD,
	hinput : win.HANDLE,
	houtput : win.HANDLE,
	flags : win.DWORD = 0
) -> (HPCON, win.HRESULT) {
	hpcon : HPCON
	hr := _CreatePseudoConsole(size, hinput, houtput, flags, &hpcon)
	return hpcon, hr
}

resizePseudoConsole :: proc(
	hpc: HPCON,
	size: win.COORD
) -> win.HRESULT {
	return _ResizePseudoConsole(hpc, size)
}

closePseudoConsole :: proc(
	hpc : HPCON
) {
	_ClosePseudoConsole(hpc)
}

