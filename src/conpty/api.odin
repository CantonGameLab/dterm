package conpty

import win "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

HPCON :: rawptr
PROC_THREAD_ATTRIBUTE_LIST :: rawptr
LPPROC_THREAD_ATTRIBUTE_LIST :: ^PROC_THREAD_ATTRIBUTE_LIST

PSEUDOCONSOLE_INHERIT_CURSOR :: 1
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

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

