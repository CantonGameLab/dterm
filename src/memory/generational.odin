// 分代槽位数组:内联定长存储 + 世代句柄,手动内存管理。
// 所有资源(id 句柄容器)的统一实现;外部只经 Handle 引用,不持有裸指针。
// T 须为值语义:Free 只复位槽值,不深析构自有堆资源(释放策略由场景定)。
package memory

// 世代句柄:id 0 = 空;generation 仅在 Free 时 +1,旧句柄世代对不上即失效。
Handle :: struct {
	id         : u32,
	generation : u32,
}

// $N 定长容量,槽 0 保留,有效容量 N-1。
// 存活判定无需占用位:存活 = id < next(分配过)且 id ∉ pool(未释放)。
GenArray :: struct($N : int, $T : typeid) {
	data        : [N]T,   // 内联存储,地址稳定
	generations : [N]u32, // 每槽世代号
	pool        : [N]u32, // 空闲 id 栈(后释放先复用)
	pool_count  : int,
	next        : int, // 从未用过的槽起点(水位线)
	count       : int, // 存活数
}

Alloc :: proc(ga : ^GenArray($N, $T), value : T) -> Handle {
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

// 指定槽位分配(如窗口树根);已存活返回空句柄
AllocAt :: proc(ga : ^GenArray($N, $T), slot : int, value : T) -> Handle {
	if slot <= 0 || slot >= N || Alive(ga, slot) {
		return {}
	}
	ga.data[slot] = value
	ga.count += 1
	ga.next = max(ga.next, slot + 1)
	for i in 0 ..< ga.pool_count {
		if ga.pool[i] == u32(slot) {
			ga.pool[i] = ga.pool[ga.pool_count - 1]
			ga.pool_count -= 1
			break
		}
	}
	return Handle { id = u32(slot), generation = ga.generations[slot] }
}

Free :: proc(ga : ^GenArray($N, $T), h : Handle) -> bool {
	if !Valid(ga, h) {
		return false
	}
	id := int(h.id)
	ga.generations[id] += 1
	ga.data[id] = {} // 复位槽值,防旧裸指针读到脏数据
	ga.pool[ga.pool_count] = h.id
	ga.pool_count += 1
	ga.count -= 1
	return true
}

Get :: proc(ga : ^GenArray($N, $T), h : Handle) -> ^T {
	if !Valid(ga, h) {
		return nil
	}
	return &ga.data[int(h.id)]
}

Valid :: proc(ga : ^GenArray($N, $T), h : Handle) -> bool {
	id := int(h.id)
	if h.id == 0 || id >= ga.next {
		return false
	}
	return ga.generations[id] == h.generation
}

// 按槽位存活判定(枚举用):分配过且不在空闲栈。O(pool_count),仅冷路径遍历用
Alive :: proc(ga : ^GenArray($N, $T), i : int) -> bool {
	if i <= 0 || i >= ga.next {
		return false
	}
	for j in 0 ..< ga.pool_count {
		if ga.pool[j] == u32(i) {
			return false
		}
	}
	return true
}

// 按槽位取存活对象(枚举用,与 Alive 配对;跨层清理引用等冷路径)
GetIndex :: proc(ga : ^GenArray($N, $T), i : int) -> ^T {
	if !Alive(ga, i) {
		return nil
	}
	return &ga.data[i]
}

// 按槽位取标准句柄(含当前世代;与 Alive/GetIndex 配对,扁平遍历用)
GetHandle :: proc(ga : ^GenArray($N, $T), i : int) -> Handle {
	if !Alive(ga, i) {
		return {}
	}
	return Handle { id = u32(i), generation = ga.generations[i] }
}
