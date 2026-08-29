// 用户接口层:面向意图的函数族(窗口生命周期/会话/字体/滚动),
// CommandBar 与子进程指令通道(parser)的绑定目标;id 省略 = 当前焦点。
package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// 默认启动配置(新建窗口时自动应用;cmd 留空 = 不自动启动)
// ---------------------------------------------------------------------------
// 状态属于用户接口层配置:API 设置生效于之后创建的窗口
// (CreateWindowTreeRoot / SplitNewWindow),对已有窗口不追溯。
// cmd 非空但 font 为空时,LaunchConsole 因无字体失败(启动前必须可设字体);
// 正常用法是 cmd+font+size 一起设置,或全部留空 = 窗口不启动。
default_cmd : string
default_font : string
default_font_size : f32

// 设置默认启动配置(cmd/font 传空串 = 对应项不自动应用)
SetDefaultLaunch :: proc(cmd, font : string, size : f32) {
	if default_cmd != "" {
		delete(default_cmd)
	}
	if default_font != "" {
		delete(default_font)
	}
	default_cmd = strings.clone(cmd)
	default_font = strings.clone(font)
	default_font_size = size
}

// 查询默认启动配置(cmd/font 为内部存储借用,只读)
GetDefaultLaunch :: proc() -> (cmd, font : string, size : f32) {
	return default_cmd, default_font, default_font_size
}

// 新建窗口的自动应用:先字体后启动(先设字体,应用才能挂上)。
// 只应用于创建瞬间,不影响窗口后续手动操作。
applyDefaultLaunch :: proc(node_h : mem.Handle) {
	if node_h.id == 0 {
		return
	}
	if default_font != "" {
		SetWindowFont(default_font, default_font_size, node_h)
	}
	if default_cmd != "" {
		if !LaunchConsole(default_cmd, node_h) {
			fmt.eprintln("default launch failed:", default_cmd)
		}
	}
}

// ---------------------------------------------------------------------------
// 窗口树
// ---------------------------------------------------------------------------
// 从空窗口树初始化根节点 + 根窗口,返回根节点 handle;重复调用幂等。
// 根窗也按默认启动配置应用(cmd 留空 = 仅建窗不启动)。
CreateWindowTreeRoot :: proc() -> mem.Handle {
	InitWindowTree()
	root := WindowTreeRoot()
	win := CreateWindow()
	if win.id != 0 {
		TreeNodeSetWindow(root, win)
	}
	applyDefaultLaunch(root)
	SetFocus(root)
	return root
}

// 对 id(或焦点)window 按 dir 分裂出新 window:自动分配窗口对象(空白窗格,
// 后续 SetWindowFont/launch/工具直接可用);新窗成为焦点。
// 树级 TreeNodeSplit 保持纯结构;窗口分配在用户语义层(SplitNewWindow)完成。
// 新窗按默认启动配置应用(cmd 留空 = 空白窗格不启动)。
SplitNewWindow :: proc(dir : SplitType, id : mem.Handle = {}) -> mem.Handle {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return {}
	}
	_, new_h, ok := TreeNodeSplit(node_h, dir, 0.5)
	if !ok {
		return {}
	}
	ensureWindow(new_h) // 分配窗口对象(建窗失败不阻塞 split;按需补建,幂等)
	applyDefaultLaunch(new_h)
	SetFocus(new_h)
	return new_h
}

// 删除 id(或焦点)window:关闭其 console 应用 + 会话,释放窗口,并从树中摘除。
// 目标是唯一剩余窗口(根)时,清空整个树(所有窗口关闭 = 程序可退出)。
DestroyWindow :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return false
	}
	win_h := node.window_id
	if win := GetWindow(node.window_id); win != nil {
		// 关闭会话:先断引用再销毁(GenArray 句柄各自判定,DestroyConsole 只销毁本体)
		clearConsoleRefs(win.console_id)
		DestroyConsole(win.console_id)
		// 字体不销毁:全局共享(同 path+size 复用,其他窗口可能仍引用)
		DestroyWindowSlot(win_h)
	}
	// 唯一剩余窗口(根):清空整个树
	if node_h == WindowTreeRoot() {
		ResetWindowTree()
		SetFocus({})
		return true
	}
	// 候选兄弟:先记录再摘树(摘除时的提升/吸收可能释放兄弟槽)
	brother := mem.Handle {}
	if parent := GetWindowTreeNode(node.parent_id); parent != nil {
		brother = parent.left_son_id == node_h ? parent.right_son_id : parent.left_son_id
	}
	TreeNodeRemove(node_h)
	// 焦点落在被删窗:摘树后定焦点。兄弟被释放/变内部 → 回落根(根壳常驻)
	if GetFocus() == node_h {
		b := GetWindowTreeNode(brother)
		if brother.id == 0 || b == nil || !b.is_leaf {
			brother = WindowTreeRoot()
		}
		if brother.id == 0 {
			SetFocus({})
			return true
		}
		if b := GetWindowTreeNode(brother); b != nil && !b.is_leaf {
			brother = firstLeaf(brother)
		}
		SetFocus(brother)
	}
	return true
}

// ---------------------------------------------------------------------------
// 分割配置
// ---------------------------------------------------------------------------
// 设置 id(或焦点)window 的父节点 split_factor(0.05..0.95)
SetSplitFactor :: proc(factor : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return false
	}
	return TreeNodeSetSplitFactor(node.parent_id, factor)
}

// 与 id(或焦点)window 的 dir 方向邻居交换窗口内容:只交换两节点的 window_id,
// 树结构不变
ExchangeWindow :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	a := GetWindowTreeNode(node_h)
	b := GetWindowTreeNode(target)
	if a == nil || b == nil {
		return false
	}
	a.window_id, b.window_id = b.window_id, a.window_id
	return true
}

// 设置先序叶子序号(1-based)认领的 split 节点 factor;无认领(最右叶/越界)返回 false。
// 认领覆盖全部 split(每个内部节点恰一个认领叶),叶子序号即所有 split_factor
// 的统一索引。
SetSplitFactorLeaf :: proc(n : int, factor : f32) -> bool {
	if n < 1 {
		return false
	}
	ComputeLeafOrder()
	i := n - 1
	if i >= leaf_count {
		return false
	}
	owner := leaf_split_owner[i]
	if owner.id == 0 {
		return false
	}
	return TreeNodeSetSplitFactor(owner, factor)
}

// ---------------------------------------------------------------------------
// 字体加载(表满自动回收)
// ---------------------------------------------------------------------------
// 引用集 = 全部 Window.font_id(字体唯一真相 = 窗口;console 无副本)。
// LoadFont 表满时:扫描引用集 → 清一个未被引用的旧档 → 重试。

loadFontEvict :: proc(path : string, size : f32) -> (mem.Handle, bool) {
	if h, ok := fnt.LoadFont(path, size); ok {
		return h, true
	}
	if !fnt.FontTableFull() {
		return {}, false // 非表满失败(字号/文件),重试无意义
	}
	used : [fnt.MAX_FONT_SLOTS]mem.Handle
	n := collectUsedFonts(&used)
	if !fnt.EvictUnused(used[:n]) {
		return {}, false // 全部在用:无可回收
	}
	return fnt.LoadFont(path, size)
}

collectUsedFonts :: proc(used : ^[fnt.MAX_FONT_SLOTS]mem.Handle) -> int {
	n := 0
	for i in 0 ..< MAX_WINDOW_SLOTS {
		if w := mem.GetIndex(&windows, i); w != nil && w.font_id.id != 0 && n < fnt.MAX_FONT_SLOTS {
			used[n] = w.font_id
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// 字体
// ---------------------------------------------------------------------------
// 设定 id(或焦点)window 的字体样式(加载字体文件;LaunchConsole 前必须设置)。
// 节点无窗口时自动创建窗口。
SetWindowFont :: proc(path : string, size : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("SWF: no window")
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		fmt.eprintln("SWF: no win obj")
		return false
	}
	new_font, ok := loadFontEvict(path, size)
	if !ok {
		fmt.eprintln("SWF: LoadFont failed:", path, size)
		return false
	}
	// 字体全局共享(同 path+size 复用 LoadFont 返回同一 handle),
	// 旧字体不销毁:其他窗口可能仍引用;仅窗口指针指向新字体。
	// 字体唯一真相 = win.font_id(console 读取经窗口,无副本)
	win.font_id = new_font
	return true
}

// 设置 id(或焦点)window 的字体大小(保留字体文件;同 path 新 size 重新加载,
// 按 (path,size) 去重共享;失败保留旧字体)
SetWindowFontSize :: proc(size : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || win.font_id.id == 0 {
		return false // 未设字体
	}
	path := fnt.FontPath(win.font_id)
	if len(path) == 0 {
		return false
	}
	new_font, ok := loadFontEvict(path, size)
	if !ok {
		return false
	}
	win.font_id = new_font
	return true
}

// 增量改字号(快捷键 FontSizeUp/Down 的绑定目标;步长 1)
AdjustFontSize :: proc(delta : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || win.font_id.id == 0 {
		return false
	}
	return SetWindowFontSize(fnt.FontSize(win.font_id) + delta, node_h)
}

// 清空 id(或焦点)window 的会话:销毁其 console + ConPTY,窗口与字体保留,
// 之后可再次 LaunchConsole。与 DestroyWindow 不同,不删窗口。
ClearWindowConsole :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("CWC: no node")
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || GetConsole(win.console_id) == nil { // 句柄有效性由 GenArray 判定
		fmt.eprintln("CWC: no console")
		return false
	}
	clearConsoleRefs(win.console_id)
	DestroyConsole(win.console_id)
	return true
}

// 断掉所有指向 console_h 的引用(窗口 console_id + 工具浮层 console_id)。
// 窗口层销毁会话前的第一步:避免悬挂句柄让"空闲窗口"被误判占用。
clearConsoleRefs :: proc(h : mem.Handle) {
	for i in 0 ..< MAX_WINDOW_SLOTS {
		if w := mem.GetIndex(&windows, i); w != nil {
			if w.console_id == h {
				w.console_id = {}
			}
			for &it in w.iterms {
				if it.console_id == h {
					it.console_id = {}
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// 会话(Console 应用)
// ---------------------------------------------------------------------------
// launch 语义:在 id(或焦点)window 启动一个 console 应用。
//   - 窗口空闲(无 console)→ 直接启动
//   - 已被占用 → 自动 split 出兄弟窗(继承字体)再启动,新窗成为焦点
//   - 明确失败:无可启动节点 / 无字体
LaunchConsole :: proc(cmd : string, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("LC: no node")
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		win = ensureWindow(node_h)
		if win == nil {
			fmt.eprintln("LC: no win obj")
			return false
		}
	}
	// 已有有效 console:不覆盖,split 一个新窗承载新会话;
	// 空/悬挂引用由 GenArray 判定 == nil,一律视为空闲(自愈清 0)
	if GetConsole(win.console_id) != nil {
		_, new_h, ok := TreeNodeSplit(node_h, .LeftRight, 0.5)
		if !ok {
			fmt.eprintln("LC: split failed")
			return false
		}
		win2 := ensureWindow(new_h)
		if win2 == nil {
			fmt.eprintln("LC: no win obj (new)")
			return false
		}
		win2.font_id = win.font_id // 继承字体(已有 console 说明已设字体)
		SetFocus(new_h)
		node_h, win = new_h, win2
	} else {
		win.console_id = {}
	}
	if fnt.GetFont(win.font_id) == nil {
		fmt.eprintln("LC: no font")
		return false // 未设置字体,先 SetWindowFont
	}
	conpty_h, ok := ct.CreateConptyContext({80, 24}, cmd)
	if !ok {
		fmt.eprintln("LC: CreateConptyContext failed:", cmd)
		return false
	}
	if !ct.StartReadThread(conpty_h) {
		fmt.eprintln("LC: StartReadThread failed:", cmd)
		ct.DestroyConpty(conpty_h)
		return false
	}
	console_h, cok := CreateConsole(24, 80, conpty_h)
	if !cok {
		fmt.eprintln("LC: CreateConsole failed:", cmd)
		ct.StopReadThread(conpty_h)
		ct.DestroyConpty(conpty_h)
		return false
	}
	win.console_id = console_h
	win.auto_close = true // 默认:应用退出即自动关窗;SetAutoClose(false) 可关闭
	return true
}

// 通过 conpty 向 id(或焦点)window 的 console 应用输入字符串
FeedConsole :: proc(data : []byte, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return false
	}
	// conpty 句柄无效(工具 console 等)由 WriteConptyInput 内部返回 false
	_, ok := ct.WriteConptyInput(console.conpty_handle, data)
	return ok
}

// 设置 id(或焦点)window 在 console 应用退出后是否自动销毁
SetAutoClose :: proc(auto_close : bool, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		return false
	}
	win.auto_close = auto_close
	return true
}

// 会话轮询:遍历(只读收集会话状态)→ 处理段(单窗口动作)。
// 遍历规范:一次遍历不改多种数据 —— 收集在遍历内,销毁/输出消费是显式处理段。
// 返回 true = 仍有窗口(主循环继续);false = 所有窗口已关闭(程序可退出)。
PollSessions :: proc() -> bool {
	// 遍历:收集(读树/窗口/会话;不修改任何数据)
	leaves : [MAX_TREE_NODE_SLOTS]mem.Handle
	count := 0
	collectLeaves(WindowTreeRoot(), &leaves, &count)

	SessionEnded :: struct {
		node_h : mem.Handle,
		auto_close : bool,
	}
	ended : [MAX_TREE_NODE_SLOTS]SessionEnded
	ended_count := 0
	alive := false
	for i in 0 ..< count {
		node_h := leaves[i]
		win := NodeWindow(node_h)
		if win == nil {
			continue // 无窗口
		}
		alive = true // 窗口还在 = 程序继续(会话可有可无)
		console := GetConsole(win.console_id)
		if console == nil {
			continue // 空窗口/悬挂引用,无会话
		}
		// conpty 句柄无效(工具 console)时 JobActiveProcesses 返回 -1,视为无会话
		jobs := ct.JobActiveProcesses(console.conpty_handle)
		if jobs <= 0 || !ct.IsReadThreadAlive(console.conpty_handle) {
			ended[ended_count] = SessionEnded { node_h = node_h, auto_close = win.auto_close }
			ended_count += 1
		}
	}

	// 处理:每项动作(先消费剩余输出,再按 auto_close 销毁窗口)
	for i in 0 ..< ended_count {
		updateWindow(ended[i].node_h)
		if ended[i].auto_close {
			DestroyWindow(ended[i].node_h)
		}
	}
	return alive
}

// 消费单个窗口 console 的剩余输出(会话结束前的最后内容)
updateWindow :: proc(node_h : mem.Handle) {
	win := NodeWindow(node_h)
	if win != nil {
		UpdateConsole(win.console_id) // 内部判 console 有效
	}
}

// ---------------------------------------------------------------------------
// 历史滚动(review)
// ---------------------------------------------------------------------------
// 历史滚动,delta 单位 = 行:
//   delta > 0 → 向下翻(看更新的内容);delta < 0 → 向上翻(看旧内容,进入 review)
//   边界:向上翻到历史顶 clamp;向下滚到底(回到最新行)自动退出 review,
//   回到普通模式(实时跟随)。
// 数据模型(单真值):TermBuffer.review_line
//   0              = 普通模式(实时跟随,底行 = 最新行)
//   n (1..)        = review 模式,值 = 窗口底行物理索引 + 1;绝对锚定:
//                    新输出到达时不动(视口内容稳定),trim 裁剪时平移补偿
//   滚回最新       = review_line 置 0(与"底行索引+1 == len"等价,避免
//                    "底行 = 0"与普通模式哨兵冲突)
// 输入字节前的退出(键盘任意输入回到普通模式)由绑定层调 ConsoleExitReview。
ConsoleScroll :: proc(delta : int, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	cur := int(tb.review_line) - 1
	if tb.review_line == 0 {
		cur = len(tb.lines) - 1 // 普通模式起点 = 最新底行
	}
	nl := clamp(cur + delta, 0, len(tb.lines) - 1)
	if nl >= len(tb.lines) - 1 {
		tb.review_line = 0 // 滚回最新 = 普通模式
	} else {
		tb.review_line = u32(nl + 1)
	}
	return true
}

// 退出 review 回到普通模式(实时跟随)。键盘输入等"立即回到当前"动作的绑定目标。
ConsoleExitReview :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	tb.review_line = 0
	return true
}

// ---------------------------------------------------------------------------
// 焦点
// ---------------------------------------------------------------------------
// 设置 id 为当前焦点
SetFocusWindow :: proc(id : mem.Handle) -> bool {
	if GetWindowTreeNode(id) == nil {
		return false
	}
	SetFocus(id)
	return true
}

// 将 id(或焦点)window 的 dir 方向指向的 window 设为焦点
FocusMove :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	SetFocus(target)
	return true
}

// 查询当前焦点 window(节点 handle)
GetFocusWindow :: proc() -> mem.Handle {
	return GetFocus()
}

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------
// 统计当前 leaf(window)数量
WindowCount :: proc() -> int {
	count := 0
	countLeaves(WindowTreeRoot(), &count)
	return count
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------
// id 省略(0)时解析为当前焦点
resolveWindow :: proc(id : mem.Handle) -> mem.Handle {
	if id.id != 0 {
		return id
	}
	return GetFocus()
}

