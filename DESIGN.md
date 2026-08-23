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
┌─ 使用方层:ConPTY 子进程(夹带 ANSI 指令)/ 外部工具 / DLL 插件
├─ 用户接口层:命令字符串(OSC 999 载体)+ DLL ApiTable(意图级,低上下文)
├─ 适配器层:command parser(命令 → Command → 模块调用;id 世代解析 / 意图翻译)
├─ 模块接口层:canvas / conpty / font / render 公开函数(操作级,已知上下文)
├─ 数据层:窗口树 / Console / TermBuffer / 会话 / 字体
└─ 渲染层:DrawFrame(按 cell 内容分发)
```

- 指令通道与 DLL 插件**并存**:DLL 给编译代码的用户,ANSI 指令给运行中的子进程;两者都落在用户接口(5.0)上,经适配器翻译到模块接口。
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
| 调用方 | 其他模块(canvas ↔ conpty ↔ font) | 子进程 / DLL 插件 / 脚本 / 未来 UI |
| 上下文 | 已知:Handle 世代、布局、模块边界、调用顺序 | 极少:只知道窗口 id 与意图 |
| 参数 | `mem.Handle`、内部结构指针 | 简单整数 id、cstring、自包含参数 |
| 隐含依赖 | 可依赖全局状态(焦点、当前字体) | 不能依赖,参数必须完整 |
| 操作粒度 | 单一操作(分裂 / 挂载 / 改比例) | 意图(open-file = 聚焦 + 输入序列的组合) |
| 返回 | `(值, bool)` | 统一状态码 / 回执 |

- 模块接口在"已知上下文"下设计:传 Handle、直写字段、组合由调用方负责。
- 用户接口在"低上下文"下设计:只认窗口 id(世代解析在内部)、命令自包含、操作是意图而非步骤、返回统一状态码。
- **用户接口必须翻译/适配到模块接口**(用户接口适配器层),而不是直接暴露模块接口。

### 5.0 用户接口(外部,意图级)

命令字符串(ANSI 载体 `ESC]999;<cmd> ESC\` 与 DLL ApiTable 共享同一语义):

```
focus <id|left|right|up|down>           聚焦指定窗口(0 = 焦点自身/无参 = 当前)
open-file <window-id> <path>            让指定窗口的应用打开文件(自包含:内部翻译成应用命令)
send-input <window-id> "<bytes>"        向指定窗口的 conpty 写入原始输入序列
split <window-id> <right|down> <factor> 分裂指定窗口(参数完整,不依赖当前焦点)
remove <window-id>                      移除指定窗口
font-size <window-id> <n>               改指定窗口字体
list-windows                            (查询)返回窗口 id / 应用名 / 尺寸清单
```

- 窗口 id 是用户视角的稳定整数(世代解析由适配器完成)。
- `open-file` 是意图级命令:适配器内部 = 查目标窗口 conpty → 翻译应用命令(neovim → `:e path\r`)→ 写输入,用户不知道这些步骤。
- 返回统一状态码,经 `OSC 998` 回执(子进程)或函数返回值(DLL)。

DLL ApiTable 的用户视角函数族(与命令字符串一一对应):

```odin
// 用户接口(外部):低上下文,只认 window id
window_focus(id : u32, dir : i32) -> i32          // 0 = ok;dir: 0=id 1=left 2=right 3=up 4=down
window_split(id : u32, dir : i32, factor : f32) -> i32
window_remove(id : u32) -> i32
app_open_file(id : u32, path : cstring) -> i32    // 意图级
app_send_input(id : u32, data : cstring) -> i32
app_font_size(id : u32, size : f32) -> i32
window_list(out : ^WindowInfo, cap : i32) -> i32  // 查询
```

**用户接口适配器(实现层)**:命令字符串 / DLL 函数 → 统一解析为内部 Command 结构 → 调用模块接口。适配器负责:窗口 id → Handle 的世代解析、意图 → 步骤的翻译(open-file → 查 conpty → 写序列)、状态码统一。

```odin
// 适配器内部(非用户可见)
CommandKind :: enum u8 { Focus, OpenFile, SendInput, Split, Remove, FontSize, ... }
Command :: struct { kind, window_id : u32, data : CommandData }
```

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
ConsoleActiveTermBuffer(h) -> mem.Handle
```

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

### 6.1 DLL 插件(编译代码的用户)

- `ApiTable`:用户视角函数族(见 5.0)+ `AppState`(全局状态指针,GenArray 定长存储、地址稳定)。
- 用户 DLL `dterm_bind(^ApiTable)` 接收接口;改行为只需重编译 DLL + 热重载,不重启 dterm。
- 跨边界约束:不传动态数组/字符串所有权;用户 DLL 不分配内存;全部 `proc "stdcall"`。

### 6.2 配置分层

- **数据配置**(conf 文件,不编译):主题、字体、启动命令、快捷键映射。启动时读入,作为默认值。
- **行为配置**(Odin 代码 / DLL,编译):自定义初始化流程、特殊布局逻辑。

## 7. 工程规则(编码规范)

- 纯赋值/纯读取不提供接口:经 Get 返回指针直接读写字段;只有设计运算抽象才暴露 Setter/Getter。
- 公开函数 PascalCase;外部库绑定(api.odin)不重命名。
- 函数间传 `mem.Handle`(u32 id + 世代),count 从 1 起,0 = 空。
- 注释精简,只写非显然逻辑(中文)。
- DOD 原则:数据布局先行、槽位数组 + id、预分配、直白代码、显式优于隐式、值语义。

## 8. 待办与开放问题

- [ ] iterm 工具运行时(InternalApp 绘制 + 输入拦截)落地后定义工具输入接口
- [ ] rich content:扩展 ANSI 序列设计(OSC 998 回执 / 内容上传协议)
- [ ] 指令回复通道(子进程需要知道指令成败?)
- [ ] 多插件注册与优先级
