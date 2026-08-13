package conpty

import win "core:sys/windows"
import "core:thread"
import "core:sync"
import "core:time"

MAX_READ_BUFFER :: (2<<16) // 128KB,2 的幂(环绕用 & 掩码)

// SPSC 无锁环形缓冲:生产者=读线程(只写 tail),消费者=主循环(只写 head)。
// 跨线程字段用 sync 原子:写 .Release,读 .Acquire。
ReadWriteData :: struct {
	id             : u32, // 与 conpty_contexts 同下标;0 = 空
	thread         : ^thread.Thread,
	read_buffer    : [MAX_READ_BUFFER]byte,
	head           : u32, // 仅主循环写
	tail           : u32, // 仅读线程写
}

read_write_datas : [MAX_CONPTY_SLOTS]ReadWriteData

// 阻塞读管道 → 写环形缓冲;ReadFile 被 CloseHandle 打断(失败)时退出
readThreadProc :: proc(t: ^thread.Thread) {
	id := (cast(^u32)t.data)^ // id 经 thread.data 传入
	read_write_data := &read_write_datas[id]
	conpty_context := GetConptyContext(id)
	if conpty_context == nil {
		return
	}
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

GetReadWriteData :: proc(id : u32) -> ^ReadWriteData {
	if id == 0 || id >= MAX_CONPTY_SLOTS {
		return nil
	}
	return &read_write_datas[id]
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

StartReadThread :: proc(id : u32) -> bool {
	read_write_data := GetReadWriteData(id)
	if read_write_data == nil || read_write_data.thread != nil {
		return false
	}
	if GetConptyContext(id) == nil {
		return false
	}
	read_write_data.id = id
	read_write_data.head, read_write_data.tail = 0, 0
	read_write_data.thread = thread.create(readThreadProc)
	if read_write_data.thread == nil {
		return false
	}
	read_write_data.thread.data = &read_write_data.id // 必须在 start 前设置
	thread.start(read_write_data.thread)
	return true
}

// 关读句柄打破阻塞读 → join
StopReadThread :: proc(id : u32) {
	read_write_data := GetReadWriteData(id)
	if read_write_data == nil || read_write_data.thread == nil {
		return
	}
	DestroyConpty(id)
	thread.join(read_write_data.thread)
	thread.destroy(read_write_data.thread)
	read_write_data.thread = nil
}

StopAllReadThreads :: proc() {
	for i in 0 ..< MAX_CONPTY_SLOTS {
		StopReadThread(u32(i))
	}
}
