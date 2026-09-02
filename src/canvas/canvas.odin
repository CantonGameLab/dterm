// canvas 模块:每帧主入口(DAG 中位于 input/event 之后、render 之前)。
// 自身数据(窗口树/Buffer/Console/VT/工具条)+ 固定有序子步骤:
//   1. 树遍历:布局 + 消费各会话输出(vtparse → 状态),Resize 联动 ConPTY
//   2. 会话轮询:auto_close 销毁;全部窗口关闭返回 false
//   3. 绑定层:键鼠动作(绑定表 → 用户接口)
//   4. 文本路由:bar 可见 → CommandBar 编辑状态机;否则 → 应用(退出 review + Feed)
package canvas

import mem "../memory"
import inp "../input"
import "core:fmt"

Update :: proc() -> bool {
	ConsoleUpdateTree(WindowTreeRoot()) // 更新 WindowTree 的 layout + 消费输出
	if !PollSessions() {
		fmt.println("all sessions ended")
		return false
	}

	SelectionValidate() // 选区自愈(buffer 数据链验证;失效即清,渲染前定稿)

	ProcessMouse()
	ProcessKeys()

	if CommandBarVisible() {
		if buf := inp.TakeAppInput(); len(buf) > 0 {
			commandBarFeed(buf)
		}
	} else {
		if buf := inp.TakeAppInput(); len(buf) > 0 {
			InputText(buf)
		}
	}

	return true
}
