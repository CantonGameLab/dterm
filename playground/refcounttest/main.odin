// RefCounted 池回归:分配/引用/复用/满拒绝/世代失效。
// 专用场景 = 字体(公用数据):Free 是引用 -1;新区用完 + 无空位时
// 复用 refs <= 0 的槽;全部引用在用时 = 满拒绝。
package main

import "core:fmt"
import mem "../../src/memory"

MAX_N :: 4 // 槽 0 保留,有效槽 1..3

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	ga := mem.RefCounted(MAX_N, int){}

	// 基础分配:id 从 1 起(槽 0 保留)
	h1 := mem.RcAlloc(&ga, 111)
	h2 := mem.RcAlloc(&ga, 222)
	check("alloc id1", h1.id, u32(1))
	check("alloc id2", h2.id, u32(2))
	check("count=2", mem.RcCount(&ga), 2)
	check("get1", mem.RcGet(&ga, h1)^, 111)
	check("get2", mem.RcGet(&ga, h2)^, 222)

	// 引用:Retain +1;Free -1(仍有效);归零 = 失效但槽保留
	mem.RcRetain(&ga, h1)
	check("refs=2", mem.RcRefs(&ga, h1), i32(2))
	mem.RcFree(&ga, h1)
	check("refs=1 still valid", mem.RcValid(&ga, h1), true)
	mem.RcFree(&ga, h1)
	check("refs=0 invalid", mem.RcValid(&ga, h1), false)
	check("count=1", mem.RcCount(&ga), 1)
	check("refs query 0", mem.RcRefs(&ga, h1), i32(0))

	// 新区取完 → 复用 refs<=0 的槽(世代 +1,旧句柄失效)
	h3 := mem.RcAlloc(&ga, 333)
	check("alloc slot3 (new region)", h3.id, u32(3))
	h4 := mem.RcAlloc(&ga, 444)
	check("reuse slot1", h4.id, u32(1))
	check("old h1 invalid (gen bump)", mem.RcValid(&ga, h1), false)
	check("old h2 still valid", mem.RcValid(&ga, h2), true)
	check("get4", mem.RcGet(&ga, h4)^, 444)

	// 全部引用在用 → 满拒绝
	check("full reject", mem.RcAlloc(&ga, 555).id, u32(0))
	check("count=3", mem.RcCount(&ga), 3)

	// 释放一个再分配:复用归零槽
	mem.RcFree(&ga, h2)
	check("h2 invalid after 0", mem.RcValid(&ga, h2), false)
	h5 := mem.RcAlloc(&ga, 555)
	check("reuse slot2", h5.id, u32(2))
	check("get5", mem.RcGet(&ga, h5)^, 555)

	// 重复释放 = 空操作(自愈)
	check("free once ok", mem.RcFree(&ga, h3), true)
	check("double free noop", mem.RcFree(&ga, h3), false)

	// 空句柄无效
	check("empty handle invalid", mem.RcValid(&ga, mem.Handle {}), false)
}
