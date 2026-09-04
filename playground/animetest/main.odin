// 光标动画回归(纯状态机,不 Init GL):ease 端点 / 首帧落位 / 启动 / 插值断点 /
// 续接 / 双 console 独立 / 换代重置 / 硬相位闪烁与颜色编码。
// 时间显式注入(伪时钟每帧 +16ms),状态机完全复现。
package main

import rnd "../../src/render"
import cv "../../src/canvas"
import "core:fmt"
import "core:math"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

checkNear :: proc(name : string, got, want : f32) {
	if math.abs(got - want) < 1e-3 {
		fmt.printf("  ok  %s (%.4f)\n", name, got)
	} else {
		fmt.printf("FAIL  %s got=%.4f want=%.4f\n", name, got, want)
	}
}

main :: proc() {
	// ---- 缓动断点 ----
	checkNear("ease linear mid", rnd.EaseLinear(5, 10, 20, 10), 20)
	checkNear("ease quad out 0", rnd.EaseQuadOut(0, 10, 90, 90), 10)
	checkNear("ease quad out 1", rnd.EaseQuadOut(90, 10, 90, 90), 100)
	checkNear("ease quad out 0.5", rnd.EaseQuadOut(45, 10, 90, 90), 77.5) // -p(p-2):p=0.5 → 0.75
	_ = rnd.CursorColor // 颜色编码函数仍存在(视觉管线用)

	// 两个工具 console(conpty = 0,无会话):每 console 独立动画
	ch1, ok1 := cv.CreateConsole(24, 80, {})
	if !ok1 {
		fmt.println("console1 failed")
		return
	}
	ch2, ok2 := cv.CreateConsole(24, 80, {})
	if !ok2 {
		fmt.println("console2 failed")
		return
	}

	t := f64(1000.0)
	frame :: proc(h : $H, cx, cy : f32, now : ^f64) -> (f32, f32) {
		rx, ry := rnd.CursorAnimEval(h, cx, cy, now^)
		now^ += 16
		return rx, ry
	}

	// ---- ch1 首帧:落位;同位置下一帧不动画 ----
	rx, ry := frame(ch1, 100, 200, &t) // t=1000
	check("init pos", rx == 100 && ry == 200, true)
	rx, ry = frame(ch1, 100, 200, &t) // t=1016
	check("settled pos", rx == 100, true)

	// ---- 真源变 → 启动(起点帧 = 上次渲染位置) ----
	rx, ry = frame(ch1, 160, 200, &t) // t=1032:启动,start_ms=1032
	check("launch from last", rx == 100, true)

	// ---- 插值断点/到达:时长 ≥ 一帧(16ms)才有中间态;否则次帧直落 ----
	mid := rnd.CURSOR_ANIM_MS >= 16.0
	if mid {
		rx, ry = frame(ch1, 160, 200, &t) // t=1048(启动后 16ms)
		k := 16.0 / f64(rnd.CURSOR_ANIM_MS)
		checkNear("interp mid", rx, 100 + 60.0 * f32(2.0*k - k*k))
	}
	t = 1032 + f64(rnd.CURSOR_ANIM_MS)
	rx, ry = frame(ch1, 160, 200, &t) // 时长后首帧:到达
	check("arrive after dur", rx == 160, true)

	// ---- 续接:active 中目标再变 → 起点 = 当前渲染值 ----
	t = 1140.0
	_, _ = frame(ch1, 300, 200, &t) // 启动 160→300(start_ms=1140)
	if mid {
		_, _ = frame(ch1, 300, 200, &t) // 中间帧 k=16/时长
	}
	t = 1172.0
	rx, ry = frame(ch1, 500, 200, &t) // 目标再变:续接(起点帧返回当前渲染值)
	if mid {
		k16 := 16.0 / f64(rnd.CURSOR_ANIM_MS)
		checkNear("resume continuous", rx, 160 + 140.0 * f32(2.0*k16 - k16*k16))
	} else {
		check("resume fast", rx == 160, true) // 时长≈0:续接帧 k=0 → 返回上一帧渲染值(启动帧的 160)
	}

	// ---- 双 console 独立:ch2 不动,ch1 动画不受影响 ----
	_, _ = frame(ch2, 300, 300, &t)
	_, _ = frame(ch1, 500, 200, &t)
	rx, ry = frame(ch2, 300, 300, &t)
	check("ch2 independent", rx == 300 && ry == 300, true)

	// ---- 换代重置:销毁 ch1 → 新 console 复用它槽(id 相同 generation+1) ----
	cv.DestroyConsole(ch1)
	ch1b, okb := cv.CreateConsole(24, 80, {})
	check("recreate ok", okb, true)
	check("same slot likely", ch1b.id == ch1.id, true)
	t = 5000.0
	rx, ry = rnd.CursorAnimEval(ch1b, 777, 400, t)
	check("epoch reset pos", rx == 777 && ry == 400, true)
	t += 16
	rx, ry = rnd.CursorAnimEval(ch1b, 777, 400, t)
	check("epoch no anim", rx == 777, true)

	// ---- 硬相位闪烁(DECSCUSR 语义:0/1/3/5 闪烁,固定 500ms 亮/500ms 灭;2/4/6 常亮) ----
	no_act := u64(0)
	checkNear("blink style0 on", rnd.BlinkAlpha(0, 0, no_act), 1.0)
	checkNear("blink style0 near edge", rnd.BlinkAlpha(0, 499, no_act), 1.0)
	checkNear("blink style0 off", rnd.BlinkAlpha(0, 500, no_act), 0.0)
	checkNear("blink style0 off-mid", rnd.BlinkAlpha(0, 750, no_act), 0.0)
	checkNear("blink style1 on", rnd.BlinkAlpha(1, 250, no_act), 1.0)
	checkNear("blink style5 on", rnd.BlinkAlpha(5, 0, no_act), 1.0)
	checkNear("blink style5 off", rnd.BlinkAlpha(5, 600, no_act), 0.0)
	check("steady style2", rnd.BlinkAlpha(2, 0, no_act), 1.0) // 常亮类恒常亮
	check("steady style2 mid", rnd.BlinkAlpha(2, 500, no_act), 1.0)
	check("steady style4", rnd.BlinkAlpha(4, 500, no_act), 1.0)

	// ---- 输入活动窗口:距上次活动 < 500ms → 常亮(即使绝对相位在灭段) ----
	act := u64(1500) // 上次活动时刻 = 相位 500ms(灭段起点)
	checkNear("activity window on", rnd.BlinkAlpha(0, 1900, act), 1.0) // 差 400ms,相位 900(灭段)仍常亮
	checkNear("activity window edge", rnd.BlinkAlpha(0, 1999, act), 1.0) // 差 499ms
	checkNear("activity window out off", rnd.BlinkAlpha(0, 2500, act), 0.0) // 差 1000ms → 相位 500 = 灭
	checkNear("activity window out on", rnd.BlinkAlpha(0, 2100, act), 1.0) // 差 600ms → 相位 100 = 亮
	checkNear("activity style1 on", rnd.BlinkAlpha(1, 1600, act), 1.0) // 差 100ms 窗口内
	checkNear("activity style1 out", rnd.BlinkAlpha(1, 2600, act), 0.0) // 差 1100ms → 相位 600 = 灭
	check("activity steady style2", rnd.BlinkAlpha(2, 2500, act), 1.0) // 常亮类不受影响
	checkNear("activity zero-last", rnd.BlinkAlpha(0, 1099, u64(0)), 1.0) // last=0 视为从未输入:相位 99 = 亮
	checkNear("activity zero-last off", rnd.BlinkAlpha(0, 1500, u64(0)), 0.0) // 相位 500 = 灭

	check("color alpha .5", rnd.CursorColor(0x00FFFFFF, 0.5), u32(0x80FFFFFF))
	check("color opaque", rnd.CursorColor(0x00FFFFFF, 1.0), u32(0xFFFFFFFF))
	check("color zero", rnd.CursorColor(0x123456, 0.0), u32(0x00123456))

	fmt.println("animetest done")
}
