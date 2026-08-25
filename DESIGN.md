# dterm 设计文档

> 版本:v1(草案,待完善)
> 定位:dterm 是一个**拓展性的终端应用管理器(exterminal)**

---

## 1. 定位与愿景

- dterm 不是"终端模拟器",而是**终端应用管理器**:每个窗口承载一个终端应用,并为其提供管理工具与应用间协作能力。
- 终端应用 = **ConPTY 子进程**(shell / neovim / agent 工具等),通过 ConPTY 管道与 dterm 交流——不引入其他通信抽象。
- 超文本内容(数学公式 / GIF / 视频 / UI 控件)是未来能力,通过**扩展 ANSI 转义序列**实现;当前只做文本渲染。

## 2. 概念模型

```
Window(leaf 节点)= 一个 App = 一个 ConPTY 子进程
  ├─ console:渲染子进程输出(conpty pipeline 是唯一交流通道)
  └─ iterm[]:dterm 内置管理工具(浮层 UI,不是 app,不走 conpty)
       └─ 工具通过 dterm 指令通道控制 app
```

- **window ↔ app 一一对应**:一个 window 一个 conpty 一个 console。
- **iterm = 管理工具**:控制台、侧边文件树、预览面板、状态栏——dterm 自己渲染,复用 Console/TermBuffer(conpty_handle = 0 的内部 console)。
- **应用间交互 = 指令通道**:文件树 app 通过扩展 ANSI 序列向 dterm 发送 canvas 接口调用指令(如 focus、send-input),dterm 解析执行——指令接口面向**需要控制 dterm 的使用方**(子进程 / 外部工具)。

## 3. 分层架构

```
┌─ 使用方层:悬浮控制台指令(F2 呼出,已实现)/ ConPTY 子进程 ANSI 指令(规划)/ DLL 插件(规划)
├─ 用户接口层:指令语义(5.0)+ 用户函数族(5.0b)
├─ 适配器层:command parser(指令字符串 → 用户函数;id 世代解析)
├─ 模块接口层:canvas / conpty / font / render 公开函数(操作级,见 5.1)
├─ 数据层:窗口树 / Console / TermBuffer / 会话 / 字体
└─ 渲染层:DrawFrame(终端内容)+ nanovg UI 层(悬浮控制台)
```

- 指令入口与 DLL 插件**并存**:DLL 给编译代码的用户,指令给交互/子进程;两者都落在用户接口(5.0)上,经适配器翻译到模块接口。
- **模块间通过数据交互,避免回调交叉**;回调只允许出现在"框架 → 使用方"边界(插件契约)。

## 4. 程序状态(数据结构设计)

### 4.1 窗口树节点

```odin
// leaf 节点 = 一个 app:绑定 console;内部节点 = 纯分割容器
WindowTreeNode :: struct {
    console_id : mem.Handle,   // 仅 leaf:主应用 console;0 = 空窗
    iterms : [dynamic]Iterm,   // 管理工具浮层(锚定于本节点几何)
    using transform : Transform, // position_x/y, width/height(像素)
    frame_width : u32,          // 分割条像素宽
    frame_color : u32,
    parent_id : mem.Handle,     // 0 = 无父(仅根)
    left_son_id : mem.Handle,   // left or up
    right_son_id : mem.Handle,  // right or down
    split_factor : f32,         // 左子树所占空间
    split_type : SplitType,     // UpDown / LeftRight
    is_leaf : bool,
}
```

### 4.2 工具 iterm(锚定定位)

```odin
ToolType :: enum u8 { Console, FileTree, Preview, StatusBar, Terminal }

// 锚定规则:iterm 系数坐标转化的绝对坐标,永远等于 window 系数坐标转化的绝对坐标
//   window_pos + window_size*window_coord == iterm_pos + iterm_size*iterm_coord
Iterm :: struct {
    tool_type : ToolType,
    console_id : mem.Handle,     // 工具渲染目标(内部 console,conpty_handle = 0)
    layer : u16,                 // 绘制层(小 = 先画)
    width, height : f32,         // 绝对大小(px)
    iterm_ax, iterm_ay : f32,    // iterm 系数坐标(锚点,0..1)
    window_ax, window_ay : f32,  // window 系数坐标(锚点,0..1)
}
```

### 4.3 Console(内容与渲染目标)

```odin
Console :: struct {
    rows, cols : u16,
    origin_x, origin_y : f32,
    cursor_row, cursor_col : u16,
    vt : VtState,
    term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle,
    active_term_buffer_id : mem.Handle,
    conpty_handle : mem.Handle,  // 0 = 无后端(工具 console,dterm 自己写内容)
    font_id : mem.Handle,
    font_size : f32,
}
```

Cell 当前为文本单元(`cp: rune + style + wide`);rich content 未来经扩展 ANSI 序列进入,Cell 届时扩展为内容判别。

### 4.4 焦点状态

```odin
focused_node : mem.Handle  // 聚焦的 window(leaf);0 = 无
focused_iterm : i32        // -1 = 焦点在主应用;>=0 = iterms 下标
```

### 4.5 会话与字体(现状保留)

- `ConptyContext`:hpc / 管道 / 进程信息 / Job Object(进程树跟踪 + KILL_ON_JOB_CLOSE 清理)。
- `Font`:faces / GSUB / 图集 / shape 缓存。
- `Theme`:fg / bg / cursor(渲染层每帧传入)。

## 5. 接口分层:模块接口与用户接口

**两类接口必须分开设计**——调用方掌握的上下文不同:

| | 模块接口(内部) | 用户接口(外部) |
|---|---|---|
| 调用方 | 其他模块(canvas ↔ conpty ↔ font) | 子进程 / 控制台指令 / DLL 插件 / 脚本 |
| 上下文 | 已知:Handle 世代、布局、模块边界、调用顺序 | 极少:只知道窗口 id 与意图 |
| 参数 | `mem.Handle`、内部结构指针 | 简单整数 id、cstring、自包含参数 |
| 操作粒度 | 单一操作(分裂 / 挂载 / 改比例) | 意图(open-file = 聚焦 + 输入序列的组合) |
| 返回 | `(值, bool)` | 统一状态码 / 回执 |

- 模块接口在"已知上下文"下设计:传 Handle、直写字段。
- 用户接口在"低上下文"下设计:只认窗口 id(世代解析在内部)、命令自包含、操作是意图。
- **用户接口适配器**:命令字符串 → 调用模块接口(parser 层),不直接暴露模块接口。

### 5.0 用户接口(控制台指令集)

**入口**:悬浮控制台(F2 呼出)输入指令,回车执行。控制台是专用命令框,**指令无 `:` 前缀**。

**语法**:`命令名 参数... [@id]`
- 参数空格分隔,`"..."` 包裹字符串
- `@id` 放末尾指定目标窗口(缺省 = 当前焦点);`@id` 缺省或为 0 时作用于焦点窗口
- 方向:水平 `right|leftright|h`,垂直 `down|updown|v`

| 指令 | 参数 | 说明 |
|---|---|---|
| `split` | `<right\|down> [factor] [@id]` | 分裂窗口为新窗(焦点窗保留为左/上,新开右/下),新窗成为焦点 |
| `focus` | `<id\|left\|right\|up\|down>` | 聚焦指定窗口(按 id 或方向导航) |
| `destroy` | `[@id]` | 关闭窗口及其 console 应用,从树摘除 |
| `factor` | `<ratio> [@id]` | 设置窗口**父节点** split_factor(0.05..0.95) |
| `exchange` | `<left\|right\|up\|down> [@id]` | 与方向邻居**交换窗口内容**(只换 window_id,树结构不变) |
| `font` | `"<path>" <size> [@id]` | 设置窗口字体文件与字号 |
| `launch` | `"<cmd>" [@id]` | 用窗口已配置的字体启动 console 应用(需先 `font`) |
| `feed` | `"<text>" [@id]` | 向窗口 console 写入输入序列 |
| `autoclose` | `<true\|false> [@id]` | 设置应用退出后是否自动关闭窗口(默认 true) |
| `count` / `windows` | - | 查询窗口数量(经 UI 输出) |
| `focus-get` / `getfocus` | - | 查询当前焦点窗口 id(经 UI 输出) |

**示例**:
```
split right            # 焦点窗向右分裂
split down 0.4         # 向下分裂,上(原窗)占 40%
focus 3                # 聚焦 id=3 的窗口
focus left             # 焦点向左导航
factor 0.6             # 焦点窗父节点比例 0.6
exchange right         # 与右侧邻居交换内容
font "./f.ttf" 18      # 焦点窗字体 Cascadia 18
launch "cmd.exe"       # 启动 cmd(需先设字体)
destroy @3             # 关闭窗口 3
autoclose false        # 应用退出后保留窗口
count                  # 窗口数量
```

**parser 实现:** `src/canvas/parser.odin`(`ParseCommandString` / `ExecuteCommandString`),直接调用 `src/canvas/window.odin` 的用户函数。

### 5.0b 用户接口(函数族,window.odin)

控制台指令最终映射到这些函数(用户代码/未来 DLL 也可直接调用):

| 函数 | 签名 | 说明 |
|---|---|---|
| `CreateWindowTreeRoot` | `() -> mem.Handle` | 建根节点 + 根窗口,幂等 |
| `SplitNewWindow` | `(dir : SplitType, id = {}) -> mem.Handle` | 分裂新窗,焦点移到新窗 |
| `DestroyWindow` | `(id = {}) -> bool` | 关应用+会话+树摘除;唯一剩余窗口清空整树 |
| `SetSplitFactor` | `(factor : f32, id = {}) -> bool` | 设父节点比例 |
| `ExchangeWindow` | `(dir : FocusDirection, id = {}) -> bool` | 与方向邻居交换 window_id |
| `SetWindowFont` | `(path : string, size : f32, id = {}) -> bool` | 设窗口字体(无窗则自动创建) |
| `LaunchConsole` | `(cmd : string, id = {}) -> bool` | 用窗口字体启动会话;默认 auto_close=true |
| `FeedConsole` | `(data : []byte, id = {}) -> bool` | 写输入到窗口 console |
| `SetAutoClose` | `(b : bool, id = {}) -> bool` | 设置自动关闭 |
| `ClearWindowConsole` | `(id = {}) -> bool` | 清窗口会话(保留窗口/字体) |
| `ConsoleScroll` | `(delta : int, id = {}) -> bool` | 历史滚动:正=向下翻(新内容),负=向上翻(旧内容,进入 review);滚回最新自动回普通模式 |
| `ConsoleExitReview` | `(id = {}) -> bool` | 立即退出 review 回普通(实时跟随);键盘输入绑定目标 |
| `PollSessions` | `() -> bool` | 每帧检测会话结束,按 auto_close 处理;返回是否有存活会话 |
| `SetFocusWindow` | `(id : mem.Handle) -> bool` | 设焦点 |
| `FocusMove` | `(dir : FocusDirection, id = {}) -> bool` | 方向导航设焦点 |
| `GetFocusWindow` | `() -> mem.Handle` | 查询焦点 |
| `WindowCount` | `() -> int` | 查询窗口数 |

### 5.1 模块接口(内部,操作级)

```odin
InitWindowTree()                                   // 建根(幂等)
WindowTreeRoot() -> mem.Handle                     // 当前根(分裂后根迁移)
GetWindowTreeNode(h) -> ^WindowTreeNode            // 取节点(直接读写字段)
NodeHandleById(id : u32) -> mem.Handle             // id → 带当前世代的句柄
WindowTreeSetRootSize(w, h)                        // 窗口 resize 更新根几何

TreeNodeSplit(h, split_type, factor) -> (parent, new_h, ok)  // h 保留为左/上,新开右/下
TreeNodeRemove(h)                                  // 摘除子树,父变单子自动提升
TreeNodeSetSplitFactor(h, factor) -> bool          // 内部节点比例 0.05..0.95
TreeNodeSetSplitType(h, split_type) -> bool        // 内部节点方向
TreeNodeSetLeftSon / TreeNodeSetRightSon(h, son) -> bool  // 手动挂子(含环检测)
RecalculateTransforms(h)                           // 递归重算子树几何
```

### 5.2 Console

```odin
CreateConsole(rows, cols, conpty_handle) -> (h, ok)  // conpty_handle 可 0(工具 console)
DestroyConsole(h)
GetConsole(h) -> ^Console
ConsoleUpdateLayout(h, t, cell_w, cell_h) -> bool  // 每帧:算 cols/rows + 居中取整
ConsoleUpdateTree(root_h)                          // 遍历树:布局 + Resize + 拉输出
UpdateConsole(h)                                   // 拉 conpty 环形缓冲喂解析器
ConsoleFeed(h, data)                               // 注入字节(工具自绘 / 测试 / 指令回显)
ConsoleSetCursor(h, row, col) -> bool
ConsoleViewportTop(h) -> (top, in_review)          // 视口顶行(渲染/应答共用入口)
ConsoleActiveTermBuffer(h) -> mem.Handle
```

**历史滚动数据模型(单真值,绝对锚定)**:`TermBuffer.review_line`
- `0` = 普通模式(实时跟随,底行 = 最新行,新输出自动贴底)
- `n (1..)` = review 模式,值 = 屏幕底行物理索引 + 1;**新输出到达时不动**(视口内容稳定),trim 裁剪头行时平移补偿,resize 按"顶行不变"重排
- 滚回最新(n 到达 len)→ 置 0(普通);与"底行 = 0"的哨兵冲突用 +1 编码避开
- 视口顶行 = `viewportTop(console, tb)`(唯一公式,渲染/光标应答共用)

### 5.3 工具 iterm

```odin
TreeNodeAddIterm(h, tool_type) -> (index, ok)      // 挂工具(锚定参数由 ItermGet 直写)
TreeNodeRemoveIterm(h, index)
ItermGet(h, index) -> ^Iterm                       // 直写 tool_type / 锚定 / layer
ItermAbsoluteTransform(h, index) -> Transform      // 锚定公式(见 4.2)
```

### 5.4 焦点与输入路由

```odin
SetFocus(node_h) / GetFocus() -> mem.Handle
FocusNeighbor(from, dir) -> mem.Handle             // 方向导航(上行找边界祖先,下行找最远 leaf)
SetFocusIterm(index : i32) / GetFocusIterm() -> i32

// 输入路由(每帧):全局按键 → 焦点目标
//   焦点在主应用(focused_iterm == -1):写 conpty
//   焦点在工具:交给工具处理(dterm 内部,后续工具落地时定义)
```

### 5.5 会话 / 字体 / 渲染(现状保留)

```odin
// conpty
CreateConptyContext(size, cmd) -> (h, ok)
DestroyConpty(h)
Resize(h, cols, rows) -> bool
WriteConptyInput(h, data) -> (n, ok)
StartReadThread(h) / StopReadThread(h)
GetReadWriteData(h) -> ^ReadWriteData
IsReadThreadAlive(h) -> bool
JobActiveProcesses(h) -> int

// font
LoadFont(path, size, antialias=1) -> (h, ok)
DestroyFont(h) / GetFont(h) / GetMetrics(h)
GetGlyph(h, cp) / GetGlyphById(h, gid) / GlyphIndex(h, cp)
GetAtlasTexture(h) / ShapeLine(h, ^[dynamic]u16)

// render
Init / Quit / GetWindowSize / GetWindow
BeginFrame / EndFrame
DrawRect / DrawRune / DrawGlyphById / DrawText
DrawFrame(theme)
```

## 6. 对外扩展接口

### 6.1 指令入口现状(V1 已实现)

- **悬浮控制台指令**(已实现):F2 呼出悬浮输入框,输入指令回车执行(见 5.0)。这是当前唯一的指令入口,供用户交互。
- **ANSI 子进程指令通道**(规划,未实现):子进程经扩展 ANSI 序列(`ESC]999;<cmd> ESC\`)向 dterm 发指令。需在 vtparse 加 OSC 999 识别 → 提取命令字符串 → `ExecuteCommandString`。
- 两者共用同一套指令语义(5.0),只是载体不同。

### 6.2 DLL 插件(规划,未实现)

- `ApiTable`:用户视角函数族(见 5.0b)+ `AppState`(全局状态指针,GenArray 定长存储、地址稳定)。
- 用户 DLL `dterm_bind(^ApiTable)` 接收接口;改行为只需重编译 DLL + 热重载,不重启 dterm。
- 跨边界约束:不传动态数组/字符串所有权;用户 DLL 不分配内存;全部 `proc "stdcall"`。

### 6.3 配置分层

- **数据配置**(conf 文件,不编译):主题、字体、启动命令、快捷键映射。启动时读入,作为默认值。
- **行为配置**(Odin 代码 / DLL,编译):自定义初始化流程、特殊布局逻辑。

## 7. 工程规则(编码规范)

- 纯赋值/纯读取不提供接口:经 Get 返回指针直接读写字段;只有设计运算抽象才暴露 Setter/Getter。
- 公开函数 PascalCase;外部库绑定(api.odin)不重命名。
- 函数间传 `mem.Handle`(u32 id + 世代),count 从 1 起,0 = 空。
- 注释精简,只写非显然逻辑(中文)。
- DOD 原则:数据布局先行、槽位数组 + id、预分配、直白代码、显式优于隐式、值语义。

## 8. 待办与开放问题

- [ ] ANSI 子进程指令通道:vtparse 识别 `OSC 999 ; <cmd> ST`,转 `ExecuteCommandString`
- [ ] iterm 工具运行时(InternalApp 绘制 + 输入拦截)落地后定义工具输入接口
- [ ] rich content:扩展 ANSI 序列设计(OSC 998 回执 / 内容上传协议)
- [ ] 多插件注册与优先级
- [ ] 指令回复通道(子进程需要知道指令成败?)
- [ ] 多插件注册与优先级
