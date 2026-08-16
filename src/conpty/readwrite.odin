package conpty

import win "core:sys/windows"
import "core:thread"
import "core:sync"
import "core:time"
import mem "../memory"

MAX_READ_BUFFER :: (2<<16) // 128KB,2 的幂(环绕用 & 掩码)

// SPSC 无锁环形缓冲:生产者=读线程(只写 tail),消费者=主循环(只写 head)。
// 跨线程字段用 sync 原子:写 .Release,读 .Acquire。
// 与 conpty_contexts 同下标并行,无独立世代;handle 存关联 conpty 句柄供读线程取上下文。
ReadWriteData :: struct {
	handle      : mem.Handle,
	thread      : ^thread.Thread,
	read_buffer : [MAX_READ_BUFFER]byte,
	head        : u32, // 仅主循环写
	tail        : u32, // 仅读线程写
}

read_write_datas : [MAX_CONPTY_SLOTS]ReadWriteData

// 阻塞读管道 → 写环形缓冲;ReadFile 被 CloseHandle 打断(失败)时退出
readThreadProc :: proc(t: ^thread.Thread) {
	h := (cast(^mem.Handle)t.data)^
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return
	}
	read_write_data := &read_write_datas[h.id]
	buf := make([]byte, 8 * 1024)
	defer delete(buf)
	for {
		n, ok := readConptyOutput(conpty_context, buf)
		if !ok {
			break
		}
		ringPush(read_write_data, buf[:n])
	}
}

GetReadWriteData :: proc(h : mem.Handle) -> ^ReadWriteData {
	if GetConptyContext(h) == nil {
		return nil
	}
	return &read_write_datas[h.id]
}

ringPush :: proc(read_write_data: ^ReadWriteData, data: []byte) {
	written := 0
	for written < len(data) {
		avail := MAX_READ_BUFFER - 1 - ringLen(read_write_data) // 留一字节区分空/满
		if avail == 0 {
			time.sleep(1 * time.Millisecond)
			continue
		}
		n := min(avail, u32(len(data) - written))
		base := int(read_write_data.tail) & (MAX_READ_BUFFER - 1)
		for i in 0 ..< int(n) {
			read_write_data.read_buffer[(base + i) & (MAX_READ_BUFFER - 1)] = data[written + i]
		}
		sync.atomic_store_explicit(&read_write_data.tail, read_write_data.tail + n, .Release)
		written += int(n)
	}
}

ringLen :: proc(read_write_data: ^ReadWriteData) -> u32 {
	return read_write_data.tail - sync.atomic_load_explicit(&read_write_data.head, .Acquire)
}

RingPop :: proc(read_write_data: ^ReadWriteData, out: []byte) -> int {
	n := 0
	for n < len(out) {
		if ringLen(read_write_data) == 0 {
			break
		}
		idx := int(read_write_data.head) & (MAX_READ_BUFFER - 1)
		out[n] = read_write_data.read_buffer[idx]
		sync.atomic_store_explicit(&read_write_data.head, read_write_data.head + 1, .Release)
		n += 1
	}
	return n
}

StartReadThread :: proc(h : mem.Handle) -> bool {
	if GetConptyContext(h) == nil {
		return false
	}
	read_write_data := &read_write_datas[h.id]
	if read_write_data.thread != nil {
		return false
	}
	read_write_data.handle = h
	read_write_data.head, read_write_data.tail = 0, 0
	read_write_data.thread = thread.create(readThreadProc)
	if read_write_data.thread == nil {
		return false
	}
	read_write_data.thread.data = &read_write_data.handle // 必须在 start 前设置
	thread.start(read_write_data.thread)
	return true
}

// 先关句柄破阻塞 → join → 再释放槽(读线程仍持 ^ConptyContext,槽须在 join 后释放)
StopReadThread :: proc(h : mem.Handle) {
	ctx := GetConptyContext(h)
	if ctx == nil {
		return
	}
	read_write_data := &read_write_datas[h.id]
	if read_write_data.thread == nil {
		return
	}
	destroyConptyContext(ctx)
	thread.join(read_write_data.thread)
	thread.destroy(read_write_data.thread)
	read_write_data.thread = nil
	mem.Free(&conpty_contexts, h)
}

StopAllReadThreads :: proc() {
	for i in 1 ..< MAX_CONPTY_SLOTS {
		if mem.Alive(&conpty_contexts, i) {
			StopReadThread(mem.Handle { id = u32(i), generation = conpty_contexts.generations[i] })
		}
	}
}
