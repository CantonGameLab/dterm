// vtparser 成本分布基准:喂合成的典型终端流,
// 分别测 ① 纯 Parse(状态机,无回调) ② Parse + 真实语义(落格 + 全部 dispatch),
// 得"解析 vs 语义"占比 → 评估异步化(解析搬辅助线程)的收益上限。
// 用法:odin run playground/vtbench/
package main

import cv "../../src/canvas"
import ct "../../src/conpty"
import "core:fmt"
import "core:time"

mk :: proc() -> []byte {
	data : [dynamic]byte
	ascii := "abcdefghijklmnopqrstuvwxyz0123456789 _-"
	rng : u32 = 12345
	for len(data) < 1 << 20 {
		rng = rng * 1664525 + 1013904223
		r := rng % 100
		switch {
		case r < 70:
			for i in 0 ..< 40 {
				append(&data, ascii[int((rng * 31) % u32(len(ascii)))])
				rng = rng * 1664525 + 1013904223
			}
		case r < 90:
			append(&data, ..[]u8{0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD}) // 你好
		case r < 95:
			sgr := "\x1b[38;2;120;180;90m"
			append(&data, sgr)
		case r < 98:
			csi := "\x1b[3;10H"
			append(&data, csi)
		case:
			append(&data, '\r', '\n')
		}
	}
	return data[:]
}

main :: proc() {
	raw := mk()
	fmt.println("input:", len(raw), "bytes")

	// ① 纯 Parse(无回调)= 状态机本体成本
	p1 : cv.Parser
	cv.Init(&p1, nil)
	best1 : time.Duration = 10 * time.Second
	for _ in 0 ..< 5 {
		start := time.now()
		cv.Parse(&p1, raw)
		d := time.since(start)
		if d < best1 { best1 = d }
	}

	// ② Parse + 真实语义:真 console + 回调全链(落格/CSI 分派)
	ctx, ok := ct.CreateConptyContext({120, 40}, "cmd.exe")
	if !ok { fmt.eprintln("pty failed"); return }
	_ = ct.StartReadThread(ctx)
	ch, cok := cv.CreateConsole(40, 120, ctx)
	if !cok { fmt.eprintln("console failed"); return }

	best2 : time.Duration = 10 * time.Second
	for _ in 0 ..< 3 {
		// 每次重置:清空缓冲(避开历史裁剪影响)
		cv.TermBufferClear(cv.ConsoleActiveTermBuffer(ch))
		start := time.now()
		cv.ConsoleFeed(ch, raw)
		d := time.since(start)
		if d < best2 { best2 = d }
	}

	mb := f64(len(raw)) / 1e6
	fmt.printf("① 状态机(无回调)  : %v  %0.1f MB/s\n", best1, mb / f64(best1) * 1e9)
	fmt.printf("② 状态机+语义(全) : %v  %0.1f MB/s\n", best2, mb / f64(best2) * 1e9)
	pct := f64(best1) / f64(best2) * 100
	fmt.printf("   解析占全链比例: %0.1f%%  → 异步化主线程理论上限节省: %0.1f%%\n", pct, pct)
	fmt.printf("   语义(落格)占比: %0.1f%%(此部分无法靠解析异步化减少)\n", 100 - pct)
}
