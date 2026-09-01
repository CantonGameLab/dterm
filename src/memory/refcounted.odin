// 引用计数槽位数组:内联定长存储 + 世代句柄 + 引用计数。
// 与 GenArray 的唯一区别:Free 只引用 -1,引用归零的槽保留(句柄随即失效,
// 栈位不腾);Alloc 无空位时自动复用 refs <= 0 的槽(世代 +1,旧句柄作废)。
// 用途:字体等公用数据 —— 多持有者共享同一实例,持有者接管引用,
// 不再需要"扫描引用集"的假共享机制。
// 命名:Odin 同包内泛型同名过程解析不可靠,操作函数统一 Rc 前缀。
// 约定:引用归零即对 Get 失效(谁持有谁引用,释放即作废);
// T 的堆资源深析构由最后释放者所在层负责(如字体模块 ReleaseFont)。
package memory

// $N 定长容量,槽 0 保留,有效容量 N-1。
// 存活 = id < next 且 refs > 0(引用归零 = 逻辑失效,槽待复用)。
RefCounted :: struct($N : int, $T : typeid) {
	data        : [N]T,   // 内联存储,地址稳定
	refs        : [N]i32, // 引用计数;<= 0 = 无引用(Alloc 复用候选)
	generations : [N]u32, // 每槽世代号(仅复用时 +1)
	next        : int,    // 从未用过的槽起点(水位线)
	count       : int,    // refs > 0 的槽数
}

// 分配:先取从未用区,耗尽后复用 refs <= 0 的槽;无候选(全部在用)= 满,返回空。
// 引用计数从 1 起(调用方接管这第一个引用)。
RcAlloc :: proc(ga : ^RefCounted($N, $T), value : T) -> Handle {
	id := rcAllocSlot(ga)
	if id < 0 {
		return {}
	}
	ga.data[id] = value
	ga.refs[id] = 1
	ga.count += 1
	return Handle { id = u32(id), generation = ga.generations[id] }
}

rcAllocSlot :: proc(ga : ^RefCounted($N, $T)) -> int {
	if ga.next < N {
		id := max(ga.next, 1) // 槽 0 保留(id 0 = 空句柄)
		ga.next = id + 1
		return id
	}
	for i in 1 ..< N {
		if ga.refs[i] <= 0 {
			ga.generations[i] += 1 // 复用:旧句柄世代对不上即失效
			return i
		}
	}
	return -1
}

// 增一个引用(同 path+size 复用时的第二持有者等)
RcRetain :: proc(ga : ^RefCounted($N, $T), h : Handle) -> bool {
	if !RcValid(ga, h) {
		return false
	}
	ga.refs[int(h.id)] += 1
	return true
}

// 释放一个引用(引用 -1);归零不腾槽,语义 = 逻辑失效,待 Alloc 复用。
// 返回 false = 句柄无效/重复释放(空操作,自愈)。
RcFree :: proc(ga : ^RefCounted($N, $T), h : Handle) -> bool {
	if !RcValid(ga, h) {
		return false
	}
	id := int(h.id)
	ga.refs[id] -= 1
	if ga.refs[id] == 0 {
		ga.count -= 1
	}
	return true
}

RcGet :: proc(ga : ^RefCounted($N, $T), h : Handle) -> ^T {
	if !RcValid(ga, h) {
		return nil
	}
	return &ga.data[int(h.id)]
}

// 当前引用计数(句柄无效/已归零 = 0;归零诊断用)
RcRefs :: proc(ga : ^RefCounted($N, $T), h : Handle) -> i32 {
	if !RcValid(ga, h) {
		return 0
	}
	return ga.refs[int(h.id)]
}

// 存活(refs > 0)槽数
RcCount :: proc(ga : ^RefCounted($N, $T)) -> int {
	return ga.count
}

RcValid :: proc(ga : ^RefCounted($N, $T), h : Handle) -> bool {
	id := int(h.id)
	if h.id == 0 || id >= ga.next {
		return false
	}
	return ga.refs[id] > 0 && ga.generations[id] == h.generation
}

// 按槽位存活判定(枚举用):分配过且引用 > 0
RcAlive :: proc(ga : ^RefCounted($N, $T), i : int) -> bool {
	return i > 0 && i < ga.next && ga.refs[i] > 0
}

// 按槽位取存活对象(枚举用,与 RcAlive 配对;跨层清理引用等冷路径)
RcGetIndex :: proc(ga : ^RefCounted($N, $T), i : int) -> ^T {
	if !RcAlive(ga, i) {
		return nil
	}
	return &ga.data[i]
}

// 按槽位取标准句柄(含当前世代;与 RcAlive/RcGetIndex 配对,扁平遍历用)
RcGetHandle :: proc(ga : ^RefCounted($N, $T), i : int) -> Handle {
	if !RcAlive(ga, i) {
		return {}
	}
	return Handle { id = u32(i), generation = ga.generations[i] }
}

// ---- 枚举迭代器(core 协议:状态对象 + 逐次 nextRc(&it))----
// 用法:
//   it := mem.RcAll(&fonts)
//   for h in mem.nextRc(&it) { ... }   // 输出标准句柄(refs > 0 + 当前世代)

RcIter :: struct($N : int, $T : typeid) {
	ga : ^RefCounted(N, T),
	i : int,
}

RcAll :: proc(ga : ^RefCounted($N, $T)) -> RcIter(N, T) {
	return { ga = ga, i = 1 } // 槽 0 保留
}

nextRc :: proc(it : ^RcIter($N, $T)) -> (Handle, bool) {
	for it.i < N {
		cur := it.i
		it.i += 1
		if RcAlive(it.ga, cur) {
			return Handle { id = u32(cur), generation = it.ga.generations[cur] }, true
		}
	}
	return {}, false
}
