// 分代数组泛型实验:id 句柄 + 世代号,悬挂引用在取用时被拒。
// 槽位释放 → generation+1,id 入 pool(栈,最近释放先复用);
// 复用槽的 generation 保持释放后的值,旧句柄世代对不上即失效。
// 约定:id 0 = 空句柄,槽 0 永不分配(count 从 1 起)。
// T 须为值语义(POD):free 只复位槽值,不深析构自有堆资源。
package main

import "core:fmt"

Handle :: struct {
	id : u32,
	generation : u32,
}

// $N 定长容量;pool = 空闲 id 栈;next = 从未用过的槽起点(初值 1,槽 0 保留)
GenArray :: struct($N : int, $T : typeid) {
	data : [N]T,
	generations : [N]u32,
	pool : [N]u32,
	pool_count : int,
	next : int,
	count : int, // 存活数
}

// 分配:先复用 pool,再用新槽;满返回空句柄。新槽 generation 保持 0 起
alloc :: proc(ga : ^GenArray($N, $T), value : T) -> Handle {
	if ga.count == N - 1 {
		return {}
	}
	id : int
	if ga.pool_count > 0 {
		ga.pool_count -= 1
		id = int(ga.pool[ga.pool_count])
	} else {
		id = max(ga.next, 1) // 槽 0 保留
		ga.next = id + 1
	}
	ga.data[id] = value
	ga.count += 1
	return Handle { id = u32(id), generation = ga.generations[id] }
}

// 释放:句柄无效(世代对不上)拒绝;generation+1 后旧句柄全部失效,id 入空闲栈
free :: proc(ga : ^GenArray($N, $T), h : Handle) -> bool {
	if !valid(ga, h) {
		return false
	}
	ga.generations[int(h.id)] += 1
	ga.data[int(h.id)] = {} // 复位槽值,防旧裸指针读到脏数据
	ga.pool[ga.pool_count] = h.id
	ga.pool_count += 1
	ga.count -= 1
	return true
}

// 取用:id 越界 / 世代对不上 → nil。注意:指针只活到下一次 free/alloc 前
get :: proc(ga : ^GenArray($N, $T), h : Handle) -> ^T {
	if !valid(ga, h) {
		return nil
	}
	return &ga.data[int(h.id)]
}

valid :: proc(ga : ^GenArray($N, $T), h : Handle) -> bool {
	if h.id == 0 || int(h.id) >= ga.next {
		return false
	}
	return ga.generations[int(h.id)] == h.generation
}

// ---------------------------------------------------------------------------

Thing :: struct {
	x : int,
	name : string,
}

main :: proc() {
	ga : GenArray(8, Thing)

	a := alloc(&ga, Thing{1, "a"})
	b := alloc(&ga, Thing{2, "b"})
	c := alloc(&ga, Thing{3, "c"})
	assert(get(&ga, a) != nil && get(&ga, a).name == "a")
	assert(ga.count == 3)

	assert(free(&ga, a)) // 释放 → 旧句柄失效
	assert(get(&ga, a) == nil)
	assert(!free(&ga, a)) // 重复释放拒绝

	d := alloc(&ga, Thing{4, "d"}) // 复用 a 的槽
	assert(d.id == a.id && d.generation != a.generation)
	assert(get(&ga, d).x == 4)
	assert(get(&ga, a) == nil) // 旧句柄世代对不上,永久失效

	assert(get(&ga, {}) == nil) // 空句柄
	assert(!free(&ga, {}))

	e := alloc(&ga, Thing{5, "e"})
	f := alloc(&ga, Thing{6, "f"})
	g := alloc(&ga, Thing{7, "g"})
	h := alloc(&ga, Thing{8, "h"})
	assert(alloc(&ga, Thing{9, "i"}).id == 0) // 槽 1..7 全占用 → 满

	assert(free(&ga, b))
	i := alloc(&ga, Thing{9, "i"}) // 释放的空位又被复用
	assert(i.id == b.id && get(&ga, i) != nil && get(&ga, b) == nil)

	fmt.println("generational array ok, alive =", ga.count)
}
