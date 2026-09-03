// 动画引擎(render 域帧间状态):缓动函数(公式参考 reference/EasingLibrary,
// easings.odin 同源 public domain)+ 光标动画表(与 console 表同构)。
// 真源不动(canvas 零改动):动画只在渲染取值;显式时间输入(now)便于测试。
// 光标闪烁 = 硬相位(亮灭各半,无渐变);位移 = QuadOut 插值。
package render

import cv "../canvas"
import mem "../memory"
import s3 "vendor:sdl3"
import "core:math"

// ---------------------------------------------------------------------------
// 缓动函数:签名 (t, b, c, d) = 时间 / 起点值 / 变化量 / 时长(Penner 风格)
// ---------------------------------------------------------------------------
EaseLinear :: proc(t, b, c, d : f32) -> f32 {
	return c * t / d + b
}

// QuadraticEaseOut(参考库同式):-p*(p-2),p = t/d
EaseQuadOut :: proc(t, b, c, d : f32) -> f32 {
	k := t / d
	return -c * k * (k - 2.0) + b
}

now_ms :: proc() -> f64 {
	return f64(s3.GetTicks())
}

// ---------------------------------------------------------------------------
// 光标动画:每 console 一份(与 consoles 表同构,id 索引;generation 不匹配 =
// 孤儿/已换代 → 重置)。位置插值(QuadOut);闪烁相位 = 绝对时间戳纯函数(零状态)。
// ---------------------------------------------------------------------------
CURSOR_ANIM_MS :: 0.1 // 位置插值时长

CursorAnim :: struct {
	known : bool, // 该行已初始化(首帧 = 快照;generation 校验前提)
	generation : u32, // 对应 console 句柄世代(校验)
	active : bool, // 位置插值中
	px, py : f32, // 上次渲染位置(帧间连续;续接起点)
	tx, ty : f32, // 目标 = 真源格像素
	start_x, start_y : f32, // 插值起点
	start_ms : f64,
}

cursor_anims : [cv.MAX_CONSOLE_SLOTS]CursorAnim

// 光标动画状态机(每帧调用;真源格 (cx, cy) 变化 → QuadOut 插值)。
// 返回当前渲染位置。显式 now(ms)便于测试。
CursorAnimEval :: proc(console_h : mem.Handle, cx, cy : f32, now : f64) -> (rx, ry : f32) {
	if console_h.id == 0 || int(console_h.id) >= cv.MAX_CONSOLE_SLOTS {
		return cx, cy
	}
	anim := &cursor_anims[int(console_h.id)]
	if !anim.known || anim.generation != console_h.generation {
		anim^ = CursorAnim {
			known = true,
			generation = console_h.generation,
			px = cx,
			py = cy,
			tx = cx,
			ty = cy,
		}
		return cx, cy // 首帧/换代:直接落位
	}
	if anim.active {
		if anim.tx != cx || anim.ty != cy {
			// 目标再变(连续移动):从当前渲染值无缝续接
			anim.start_x, anim.start_y = anim.px, anim.py
			anim.tx, anim.ty = cx, cy
			anim.start_ms = now
		}
		k := f32(now - anim.start_ms) / CURSOR_ANIM_MS
		if k >= 1 {
			anim.active = false
			anim.px, anim.py = cx, cy
		} else {
			anim.px = EaseQuadOut(k, anim.start_x, anim.tx - anim.start_x, 1.0)
			anim.py = EaseQuadOut(k, anim.start_y, anim.ty - anim.start_y, 1.0)
		}
	} else if anim.px != cx || anim.py != cy {
		// 真源位置变化 → 启动(起点 = 上次渲染位置)
		anim.active = true
		anim.start_x, anim.start_y = anim.px, anim.py
		anim.tx, anim.ty = cx, cy
		anim.start_ms = now
	}
	return anim.px, anim.py
}

// 闪烁相位(DECSCUSR 语义,固定 500ms 亮 / 500ms 灭):闪烁样式 0/1/3/5 按相位
// 亮灭(硬切);常亮样式 2/4/6 恒亮。相位用绝对时间戳(零状态)。
// 输入活动窗口(距 last_activity_ms < INPUT_ACTIVE_MS)= 常亮(WT 行为:用户
// 输入期间光标不闪烁;活动时刻 = console.input_activity_ms,显式注入)。
INPUT_ACTIVE_MS :: 500

BlinkAlpha :: proc(style : u8, now : f64, last_activity_ms : u64) -> f32 {
	switch style {
	case 0, 1, 3, 5:
		if last_activity_ms != 0 && now - f64(last_activity_ms) < INPUT_ACTIVE_MS {
			return 1.0 // 输入窗口:常亮
		}
		if math.mod(now, 1000.0) < 500.0 {
			return 1.0
		}
		return 0.0
	}
	return 1.0
}

// 光标颜色:主题色 + alpha(0xAARRGGBB;0xRRGGBB 高字节 0 = 不透明)
CursorColor :: proc(base : u32, alpha : f32) -> u32 {
	a := u32(clamp(alpha, 0, 1) * 255 + 0.5)
	return (a << 24) | (base & 0x00FFFFFF)
}
