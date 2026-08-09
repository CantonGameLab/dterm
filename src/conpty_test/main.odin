package main

import ct "../conpty"
import win "core:sys/windows"
import "core:fmt"
import "core:time"

read_all :: proc(ctx: ^ct.ConptyCtx, buf: []byte, ms: i64) -> (total: int, s: string) {
	deadline := time.time_add(time.now(), time.Duration(ms) * time.Millisecond)
	tmp := make([]byte, 4096)
	defer delete(tmp)
	for time.time_to_unix_nano(time.now()) < time.time_to_unix_nano(deadline) {
		n, ok := ct.read_output(ctx, tmp)
		if !ok { return total, string(buf[:total]) }
		if n > 0 {
			copy(buf[total:], tmp[:n])
			total += int(n)
		}
		time.sleep(50 * time.Millisecond)
	}
	return total, string(buf[:total])
}

main :: proc() {
	ctx, ok := ct.createVirtualConsole((win.COORD{80, 25}), "cmd.exe")
	if !ok { fmt.eprintln("create failed"); return }
	defer ct.destroy(&ctx)
	fmt.printf("child pid=%d alive=%v\n", ctx.child_procid, ct.child_alive(&ctx))

	buf := make([]byte, 64 * 1024)
	defer delete(buf)

	total, out := read_all(&ctx, buf, 500)
	fmt.printf("--- initial output (%d bytes) ---\n%s\n", total, out)

	cmd := "echo hello-from-dterm\r"
	n, wok := ct.write_input(&ctx, transmute([]byte)cmd)
	fmt.printf("wrote %d bytes ok=%v\n", n, wok)

	total, out = read_all(&ctx, buf, 800)
	fmt.printf("--- after echo (%d bytes) ---\n%s\n", total, out)

	fmt.printf("resize 100x30 -> %v\n", ct.resize(&ctx, 100, 30))

	exit_cmd := "exit"
	ct.write_input(&ctx, transmute([]byte)exit_cmd)
	time.sleep(300 * time.Millisecond)
	fmt.printf("alive after exit: %v\n", ct.child_alive(&ctx))
}
