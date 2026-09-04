// 命令事件消费(帧内路由,非 userapi):执行 canvas 命令栏事件队列中上一帧提交的
// 未完成事件,结果(成功标志 + 查询回显)写回事件槽;canvas 帧内读回显示。
package command

import cv "../canvas"

// out 回调的目标事件(ExecuteCommandString 的 out 签名无 userdata,显式模块级传递)
current_event : ^cv.CommandEvent

outWrite :: proc(msg : string) {
	if current_event == nil {
		return
	}
	nr := min(len(msg), len(current_event.result))
	copy(current_event.result[:nr], msg)
	current_event.result_len = u16(nr)
}

// Update 内调用(见 command.Update):执行所有未完成事件;查询类结果写入 result 槽
processCommandEvents :: proc() {
	n := cv.CommandEventsCount()
	for i in 0 ..< n {
		ev := cv.CommandEventAt(i)
		if ev == nil || ev.done {
			continue
		}
		current_event = ev
		ev.ok = ExecuteCommandString(string(ev.text[:ev.len]), outWrite)
		current_event = nil
		ev.done = true
	}
}
