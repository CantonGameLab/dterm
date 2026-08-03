package conpty

import "core:c"
import win "core:sys/windows" 


createVirtualConsole :: proc(size: win.COORD, cmd : string) -> HPCON{

	main_side_read_conpty : win.HANDLE
	main_side_write_conpty : win.HANDLE
	conpty_side_read_main : win.HANDLE
	conpty_side_write_main : win.HANDLE
	win.CreatePipe(&conpty_side_read_main, &main_side_write_conpty, nil, 0)
	win.CreatePipe(&main_side_read_conpty, &conpty_side_write_main, nil, 0)
	
	hpc: HPCON
	hr: win.HRESULT

	hpc, hr = createPseudoConsole(size, conpty_side_read_main, conpty_side_write_main, 0)
	
	return hpc
}
