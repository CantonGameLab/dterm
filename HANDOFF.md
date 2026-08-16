# dterm 交接文档(2026-08-14)

本文件记录项目截至本次会话的全部进度、设计决策与上下文,供下一个 agent 无缝接续。
**会话起点建议先读**:本文件 → `CLAUDE.md` → `memory/`(C:\Users\GroupTheory\.claude\projects\C--Users-GroupTheory-Source-dterm\memory\)。

---

## 1. 项目总览

Windows 终端模拟器。技术栈:**Odin + SDL3 + OpenGL 4.4 core + ConPTY**(Windows 11)。

```
包依赖链:
main → render → canvas → conpty        (数据流向下)
            └──→ font ─→ vendor:stb/truetype, vendor:OpenGL
```

数据流:ConPTY 读线程 → SPSC 环形缓冲 → `UpdateConsole` 每帧拉取 → VT 解析器 → TermBuffer(双层屏幕模型);渲染方向:字体懒光栅化入 GL_R8 图集 → 批量 quad 一帧画完。

git 现状:分支 main,最近提交 `7529a66 渐入佳境`。**src/font/font.odin(新字体系统)未提交**;playground/ 与 playground.exe 未跟踪。

## 2. 编码规范(必须遵守)

来源:项目 CLAUDE.md + 用户口头纠正(会话记录)。以下全部是用户反复强调的:

1. **纯赋值/纯读取不提供接口**:已有 Get 途径(如 `GetX(id)` 返回指针)就直接读写字段;只有**运算抽象**(校验、clamp、联动副作用如重算布局)才暴露 Setter/Getter。用户两次纠正过此点,见 memory/no-duplicate-data-getters.md。
2. **公开函数 PascalCase**;外部库绑定(api.odin)不重命名。
3. **函数间传 u32 id 句柄,count 从 1 起,0 = null/空槽**。这是硬规矩——用户原话:"怎么别的都是id就Font又开始传指针了"。跨层一律 id,内部用 `GetX(id)` 拿指针。
4. **注释精简,只写非显然逻辑,中文**。
5. **DOD 原则**(Jonathan Blow 风格):
   - 数据布局先行:先想数据怎么存、怎么被遍历,再写操作代码
   - 无继承/虚函数/接口:enum 判别 + switch
   - 槽位数组 + id 句柄,数据连续无悬挂
   - 预分配、避免热路径分配;固定容量优先
   - 直白代码:不做"为未来"的抽象(本会话删掉过没人读的 `Font.size` 字段)
   - 数据不动就不重算;显式优于隐式,禁止隐藏全局状态机
   - 值语义:小结构按值传
6. **用户工作流**:先给基础数据结构 → 设计对外接口模式 → 再完成数据操作。改动后**用户自行运行构建**并粘贴输出,agent 不代为构建。

## 3. 构建与运行

```bash
odin build src/          # 主程序 → ./src.exe(用户运行并贴输出)
odin run playground/     # 实验程序(用户运行)
./src.exe "cmd /c chcp 65001 && echo 你好"   # CLI 测试,ConPTY → 解析 → dump.txt
```

Odin 库源码在项目 `reference/` 目录。

## 4. 模块现状

### 4.1 conpty(src/conpty/,三文件)

- `conpty.odin`:ConptyContext{hpc, read/write_conpty 句柄, proc_info};CreatePseudoConsole + CreateProcessW 带 PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 全套。槽位数组 MAX_CONPTY_SLOTS=16,hpc==nil 判空。**已有 `Resize(id, cols, rows)`,供窗口缩放联动**。
- `readwrite.odin`:SPSC 无锁环形缓冲(生产者=读线程只写 tail,消费者=主循环只写 head,sync 原子 .Release/.Acquire);`StartReadThread/StopReadThread/RingPop/GetReadWriteData`。读线程 `readThreadProc` 阻塞 ReadFile → ringPush;StopReadThread 先 DestroyConpty(关句柄破阻塞)再 join。
- `api.odin`:win32 绑定。

### 4.2 canvas —— 树(canvas.odin)

- `WindowTreeNode`:节点即窗口,`iterms [dynamic]Iterm` + Transform(绝对几何,像素)+ frame_width/color + parent/left/right_son_id + split_factor/split_type + is_leaf/in_use。根 id 硬编码 1(ROOT_WINDOW_TREE_NODE_ID),transform = 窗口分辨率。
- `Iterm`:layer、type(Console/FrameBuffer)、console_id、scale_transform(节点几何的归一化缩放)。
- **`ItermAbsoluteTransform(node_id, index)`**:现算的 Getter——绝对矩形 = 节点几何 × scale,每次调用现算,不存内存(本会话确认的既定模式)。
- 布局:`RecalculateTransforms(id)` 递归按 split_factor/frame_width 划分;**所有树操作(分裂/删除/提升/设因子/设类型/设子)最终都走它**;`WindowTreeSetRootSize(w,h)` 是窗口 resize 的唯一入口(改 root 几何 + 全树重算)。
- 防成环:treeNodeSetSon 拒绝把祖先挂成子。
- 分裂语义:TreeNodeSplit 后原节点保留为左子,新父接管其在祖父母中的位置。

### 4.3 canvas —— 屏幕(term.odin)+ VT(vt.odin)

双层屏幕模型:
- **内容层 TermBuffer**:`lines [dynamic]Line`(滚动历史 + 可视区一体)+ scroll_offset。MAX_SCROLLBACK_LINES=10000,TRIM_SLACK=512 防频繁裁行。
- **视口层 Console**:rows/cols、cursor、VtState、term_buffer_ids(ids[0]=主屏,交替屏 1049)、active_term_buffer_id、**font_id(新增)**、**origin_x/origin_y(新增,居中网格左上角)**。
- id 约定:Console 槽位 id == Conpty 槽位 id(CreateConsole 的 conpty_id 即返回 id,因为 ConPTY 是 16 槽)。
- 渲染契约:`visible_top = max(0, len(lines) - rows - scroll_offset)`;屏幕第 r 行 ↔ lines[visible_top+r]。
- VT 解析器(vt.odin):Normal/Esc/Csi/Osc 状态机,UTF-8 分片缓冲,params[16]。支持:C0(BS/TAB/LF/CR)、DECSC/DECRC、CSI A/B/C/D/H/f/G/J/K/m/h/l/r/s/u/S/T/n、SGR(16/256/truecolor/样式)、私用模式 7/25/1049/2026、滚动区。DSR 6 应答光标位置(写回 ConPTY)。`ConsoleFeed` 为调试直喂入口(main.odin 用)。
- 写路径:ConsoleWriteRune(落格→前进→折行/滚动)。**ResizeRepack(列宽变化重排已有行)未实现**。

### 4.4 font(src/font/font.odin)—— 本会话全新重写,未构建验证

**外部约束**:旧字体系统已从工作区删除(仅存 git 历史),用户明确"不用参考直接重写";接口尽量简洁;Font 必须 id 化。

对外数据与接口:

```odin
Glyph :: struct { advance : f32, bitmap_w, bitmap_h : f32, xoff, yoff : f32, uv0_x, uv0_y, uv1_x, uv1_y : f32 }
Metrics :: struct { cell_width, cell_height, ascent : f32 }

GetFont :: proc(id : u32) -> ^Font                     // Get 途径,id 0/越界/未用 → nil
LoadFont :: proc(path : string, size : f32, antialias : u8 = 2) -> (id : u32, ok : bool)
DestroyFont :: proc(id : u32)
GetGlyph :: proc(id : u32, cp : rune) -> (Glyph, bool) // 懒光栅化入口
GetMetrics :: proc(id : u32) -> Metrics
GetAtlasTexture :: proc(id : u32) -> u32
```

内部数据(槽位数组 + id,与 canvas 同构):

```odin
MAX_FONT_SLOTS :: 8; MAX_FACES :: 2; ATLAS_PAD :: 1; ATLAS_START :: 1024; ATLAS_MAX :: 4096; SLOT_LOAD_FACTOR :: 0.75
FALLBACK_FONTS :: []string{ msyh.ttc, simhei.ttf, simsun.ttc, Deng.ttf }   // C:\Windows\Fonts
Face :: struct { data : []byte, info : stbtt.fontinfo, scale : f32 }
GlyphSlot :: struct { cp : rune, face_index : u8, w, h : u16, xoff, yoff, advance : f32, u0, v0, u1, v1 : f32 }  // cp==0 = 空槽
Atlas :: struct { texture : u32, pixels : []u8, width, height, cur_x, cur_y, row_height : u32 }
Font :: struct { in_use : bool, faces : [MAX_FACES]Face, face_count : u32, antialias : u8, cell_width, cell_height, ascent : f32, slots : [dynamic]GlyphSlot, slot_count : u32, atlas : Atlas }
```

关键设计(每条都有决策背景):

1. **懒光栅化**:字形首次用到才 stbtt 渲染入图集,哈希缓存(rune→slot)。开放寻址线性探测,cp==0 空槽终止;装 0.75 翻倍重哈希(slotGrow)。
2. **图集**:GL_R8 单通道灰度(零格式转换),1024² 起步 4096 封顶。**CPU pixels 缓冲是权威源** = 上传源 + 扩容重画目标;增量 TexSubImage2D 局部上传;扩容 TexImage2D 整体重定义 + 按 slots 重画全部字形(**位图不存副本,靠 cp+face_index+w/h 重画**)+ 更新 slot UV。行式分配:cur_x 沿行排,行满换行;1px ATLAS_PAD 防线性采样串色;CLAMP_TO_EDGE + LINEAR。
3. **抗锯齿**:`MakeCodepointBitmapSubpixelPrefilter` 超采样 1-3(2x2 放大光栅化 + prefilter 缩小),sub_x/sub_y 亚像素偏移并入 slot.xoff/yoff 保证像素对齐。antialias 存 Font 字段,**LoadFont 时 clamp 一次设定(相对静止,启动时定)**。
4. **中文 fallback**:主 face `FindGlyphIndex('你')==0` 则按序附系统中文字体(msyh→simhei→simsun→Deng),共用同一图集,对外无感;face_index 记录槽位来源供扩容重画。
5. **pad 语义(踩过坑)**:slot.w/h = 位图内容尺寸;xoff/yoff 存含 pad 的像素偏移,**glyphFromSlot 输出时减 ATLAS_PAD**;UV = 内容区(不含 pad)。quad 尺寸与 UV 必须一一对应,否则文字错位。
6. **格子度量**:cell_height = ceil((ascent-descent+line_gap)*scale);cell_width = ceil('M' advance*scale);ascent = ascent*scale(渲染层基线用)。

编译风险自查清单(尚未验证):`cast([^]byte)raw_data(...)` 两处(faceLoad)+ MakeCodepointBitmap 两处;切片索引必须 int 转换;u32/int 比较转换;id 化后 render.odin 调用点已同步(DrawText 签名已改)。

### 4.5 render(src/render/render.odin)

- 屏幕坐标 = 像素,左上原点 Y 向下;顶点着色器换算 NDC;`BeginFrame → DrawRect/DrawText → EndFrame`;每帧 flushBatch 一次 draw call。
- 批量:MAX_QUADS=4096(120x30 一屏 3600 格够用),同纹理攒批,纹理切换 flush;Vertex{x,y,u,v,r,g,b,a}。
- **shader 关键修复(本会话)**:图集是 R8 灰度,片元必须 `fragColor = vec4(vColor.rgb, vColor.a * texture(uTex, vUv).r)`——灰度作 alpha,否则文字渲染为不透明红色。DrawRect 用白 1x1 纹理(灰度=1)行为不变。
- DrawText(font_id, text, x, y, color):(x,y)=基线;遍历 rune,\n 换行,GetGlyph 失败跳格(advance 用 cell_width),pushQuad(tex, pen+offset, ..., UV, color)。
- **窗口主循环未写**:render.odin 只有框架(RenderInit/PollEvents/BeginFrame/EndFrame),SDL resize 事件、树渲染、输入都未接入。

### 4.6 main(src/main.odin)

CLI 测试模式(无窗口):创建 Conpty → CreateConsole → StartReadThread → 睡眠等输出 → drain(UpdateConsole 循环)→ WriteConptyInput → 再 drain → ConsoleFeed 直喂 VT 验证解析器 → dumpConsole 到 dump.txt。窗口版主循环是接下来的主任务。

## 5. 本会话工作记录(事无巨细)

### 5.1 字体系统重写(已完成,未构建)

过程:用户要求"重新编写整个字体系统,对外接口尽量简洁,先数据结构 → 接口模式 → 数据操作",禁止参考旧代码。经历了 3 次重写:初稿(Font 传指针)→ 用户纠正 id 化(全 id 传递)→ 补抗锯齿参数(启动时一次设定)。期间概念问答(图集纹理管理、UV 采样原理:两个三角形带 UV 顶点属性,GPU 逐片元插值,texture() 采样"抠图")。
删掉的冗余:`Font.size` 字段(渲染层改用 GetMetrics,无人读)。

### 5.2 Console 居中布局(已完成,驱动未接入)

用户需求:**每次 iterm 空间变换触发 Console 更新;由 iterm 实际 transform + Console 字体决定 cols/rows;Console 居中,不锚定左上角**。随后补充:**每次 Window 更新也触发 iterm 更新**(此链 canvas 已天然闭合:WindowTreeSetRootSize → RecalculateTransforms → ItermAbsoluteTransform 派生)。

设计决策(与用户讨论后确定):
- **事件链**:窗口 resize/树操作 → RecalculateTransforms → iterm transform 更新;每帧 render 驱动 → 取 transform + font 度量 → ConsoleUpdateLayout → rows/cols 变化才 ct.Resize。
- **transform 现算不存**:用现成 Getter `ItermAbsoluteTransform`,用户明确"不将 iterm 的实际 transform 存入内存"。
- **触发机制**:每帧幂等重算(布局就 2 次除法,不建脏标记状态机),"更新动作"(ct.Resize)以 rows/cols 前后比对守卫。
- **font_size 推不出 cell_width**(等宽格宽是 'M' advance,各字体比例不同)→ Console 加 `font_id` 字段,布局用 fnt.GetMetrics 精确值。

term.odin 改动:
- Console 增字段:`origin_x, origin_y : f32`(居中网格左上角,iterm 坐标空间)、`font_id : u32`。
- 私有 `applyConsoleSize(console, rows, cols)`:`ConsoleSetSize` 与布局共用的副作用(改尺寸 + cursor/scroll_bottom clamp)。
- 新运算接口 `ConsoleUpdateLayout(console_id, t : Transform, cell_w, cell_h : f32) -> bool`:
  cols = max(1, floor(w/cell_w)), rows 同理;origin = 居中偏移;内部走 applyConsoleSize。
- 渲染契约(注释已更新):第 r 行第 c 列格子像素 = (origin_x + c*cell_w, origin_y + r*cell_h);文字基线 = origin_y + r*cell_h + ascent。
- font_id 赋值是纯字段写入,无接口(CreateConsole 后 GetConsole(id).font_id = x 直接写)。

**未接入**:render 窗口主循环还没写,每帧驱动代码在此(插入点模板):

```odin
// 每帧对每个 console iterm:
t := cv.ItermAbsoluteTransform(node_id, i)
m := fnt.GetMetrics(console.font_id)
old_rows, old_cols := console.rows, console.cols
cv.ConsoleUpdateLayout(it.console_id, t, m.cell_width, m.cell_height)
if console.rows != old_rows || console.cols != old_cols {
    ct.Resize(it.console_id, console.cols, console.rows)
}
```

### 5.3 playground 分代数组(实验程序,有 bug)

`playground/generational.odin`:分代数组泛型——id 句柄 + 世代号规避悬挂引用(ABA 防护)。三数组:data[N]T、generations[N]u32、pool[N]u32(空闲 id 栈)+ pool_count/next/count。句柄 = `Handle{id, generation}` 双字段;释放 → generation+1 + id 入 pool;取用校验世代,对不上即失效(内存被释放过的证据)。0 = 空句柄,槽 0 永不分配。接口:alloc(ga, value)/free(ga, h)/get(ga, h)->^T/valid。
与用户讨论:pool 预填 vs 空栈+next 混合式——**用户选定混合式(省去初始化)**。定长容量,满判定 count == N-1。

**已知 bug(用户运行确认)**:`generational.odin(82:2) runtime assertion: get(&ga, a) != nil`。
根因:`next` 字段零值初始化 = 0,而非注释声称的 1 → 首次 alloc 分配到槽 0,返回 Handle{id=0},而 valid 拒绝 id==0 → 所有句柄无效。**修复(一行,未应用)**:alloc 新槽分支改为

```odin
} else {
    id = max(ga.next, 1) // 槽 0 保留
    ga.next = id + 1
}
```

(注意不能只 `ga.next += 1`,否则 next=0 时重复分配槽 1;必须 `ga.next = id + 1`。)

## 6. 已知问题与遗留清单

1. **字体系统未构建验证**(编译风险点见 4.4 清单)。
2. **playground 断言失败**(根因与修复见 5.3)。
3. **render 窗口主循环未写**(最大块):SDL 事件循环、resize → WindowTreeSetRootSize、树遍历渲染叶子 iterm(Console 网格文字/光标/背景、FrameBuffer)、每帧 ConsoleUpdateLayout + ct.Resize 联动(模板见 5.2)、输入(键盘 → ConPTY,完全未开始)。
4. **上会话遗留**(旧会话,未处理):font tex=0 崩溃(疑似旧系统残留)、ResizeRepack(列宽变化重排已有行,terminal 必须)、wide char(宽字符占两格)未实现。
5. render 层 DrawText 的 color 参数是 0xRRGGBB,CellStyle 里颜色是 u32(0xFFFFFFFF = 查主题色 DEFAULT_COLOR),渲染时需映射主题色——未做。
6. `fonts_count/consoles_count/...` 计数字段仅用于增长,防收缩遍历,勿动。

## 7. 建议下一步(顺序)

1. 修 playground bug(5.3 一行修复)→ 用户跑 `odin run playground/` 验证。
2. 用户跑 `odin build src/` 验证字体系统,处理编译错误。
3. 写 render 窗口主循环(见 6.3),先做:窗口 resize 联动(事件链模板已备)→ 树遍历渲染 console 网格(文字、光标、背景)。
4. 键盘输入 → ct.WriteConptyInput。
5. 遗留项:ResizeRepack、wide char、主题色映射。

## 8. 对下一个 agent 的注意事项(踩坑记录)

- **Edit 工具事故教训**:给 LoadFont 加参数时 old_string 匹配到了 GetGlyph 的注释行,导致两个 LoadFont 定义、文件结构损坏。大改动后务必通读全文验证结构;Edit 的 old_string 要足够独特。
- **Odin 类型地狱**(font 初稿踩过):切片/数组索引必须 int(`int(y) * int(width)`);`raw_data()` 返回 rawptr,传 `[^]byte` 参数要 `cast([^]byte)`;u32 vs int 比较要显式转换。
- **shader**:R8 图集灰度必须作 alpha(RGBA 乘灰度会把文字变不透明红)。
- **用户会纠正规范**:id 化、删冗余 getter、删无人读字段——写新代码前先对照第 2 节。
- 与用户讨论设计时遵循:先数据结构、再接口、再操作;用户对"为什么"很敏感,给决策理由,别只给结论。
- 用户自己构建并贴输出,不要代为运行 `odin build`。
- 中文交流;注释精简中文。
