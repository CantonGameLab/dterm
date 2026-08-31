# Windows Terminal 字形样式(粗/斜/下划线/删除线)渲染机制报告

> **取证条件说明(重要)**:本次调研环境禁止直连网络(`curl`/`node` 到 raw.githubusercontent.com 均被沙箱拦截:`schannel: SEC_E_NO_CREDENTIALS` / `ECONNRESET`),只能通过搜索引擎索引确认**文件、PR、commit、文档**的存在与标题。因此本报告的引用粒度是 **文件路径 + PR/commit 链接**,**不给伪造的行号**。凡是我依据代码结构记忆推断、但本次未能取得直接证据的,一律显式标注 **[未证实]**。

---

## ① 数据流总览:从 SGR 到像素

WT 的管线是严格分层的,字体在最后一层才出现:

```
VT 解析 (SGR)          → src/terminal/adapter/adaptDispatch.cpp : SetGraphicsRendition
   ↓ 只写"语义位"
文本缓冲区属性         → src/buffer/out/TextAttribute.hpp (CharacterAttributes 位域 + TextColor fg/bg/underlineColor)
   ↓ 按 attribute run 切段
渲染编排               → src/renderer/base/renderer.cpp
   ├─ UpdateDrawingBrushes(TextAttribute, RenderSettings, ...)   → 颜色 + "字体变体"选择
   ├─ PaintBufferLine(...)                                        → 文字
   └─ PaintBufferGridLines(GridLineSet, color, ...)               → 下划线/删除线/上划线/框线
   ↓
渲染引擎               → src/renderer/atlas/*(AtlasEngine + BackendD3D/BackendD2D)
   ↓
DirectWrite(字体集合/回退/造型/光栅化) + D3D11(图集与合成)
```

关键机制事实:

1. **语义层完全不知道字体文件**。`TextAttribute` 里只有位标志(intense / italics / underline style / crossed-out / overlined / 框线)与三个颜色。SGR 1 在 WT 的命名是 **Intense**(不是 Bold),这次重命名有专门 issue:[#12252 Rename TextAttribute::IsBold to TextAttribute::IsIntense](https://github.com/microsoft/terminal/issues/12252)。这正是"终端语义 ≠ 字体属性"的显式承认。
2. **装饰(underline/strikethrough)不是文本属性,而是独立的"网格线集合"通道**。接口在 `src/renderer/inc/IRenderEngine.hpp`,枚举 `GridLines` 用 `til::enumset` 承载([commit dacff61 Use the til::enumset type for the GridLines enum in the renderers](https://github.com/microsoft/terminal/commit/dacff61f8862fa7c28f0244e74555cb2658455ad),[IRenderEngine.hpp](https://github.com/microsoft/terminal/blob/52ddfaa453a172ae6f3484bdc5c1db6ff35406c7/src/renderer/inc/IRenderEngine.hpp))。
3. **"intense 到底是变亮还是变粗"由渲染设置决定,不由 VT 决定**:`src/renderer/base/RenderSettings.cpp` 的 `Mode::IntenseIsBold` / `Mode::IntenseIsBright`,来源是 profile 的 `intenseTextStyle`([PR #10778 / commit 0a76283 "Add an ENUM setting for disabling rendering 'intense' text as bold"](https://archive.softwareheritage.org/browse/snapshot/959abb998348b47e448bc786e32b443eaabb1d76/log/?release=v1.10.2383.0),schema 修补 [commit 33cb0eb (#14210)](https://github.com/microsoft/terminal/commit/33cb0eb05f5aa9fee98da50296b854713bcc7470))。
4. **默认渲染器现在是 AtlasEngine**:1.20 起默认启用(参见 [v1.20.11271.0 release](https://github.com/microsoft/terminal/releases/tag/v1.20.11271.0)、[日文媒体报道:1.20 で AtlasEngine が既定有効化](https://forest.watch.impress.co.jp/docs/news/1590057.html));早期是实验开关 `experimental.useAtlasEngine`([PR #12304](https://github.com/microsoft/terminal/pull/12304));**旧的 DxEngine 已被整体删除**([PR #16278 / commit bf25595 "Remove DxEngine"](https://github.com/microsoft/terminal/commit/bf25595961190d97b6d92bcc23b383713acd1214))。AtlasEngine 的起点是 [PR #11623 "Introduce AtlasEngine - A new text rendering prototype"](https://github.com/microsoft/terminal/pull/11623)。

### SGR 映射一览(已核实的实现点)

| SGR | 语义 | WT 实现证据 |
|---|---|---|
| 1 | intense(粗 or 亮,取决 `intenseTextStyle`) | [#12252](https://github.com/microsoft/terminal/issues/12252)、[PR #13577](https://github.com/microsoft/terminal/pull/13577) |
| 3 | italics | `CharacterAttributes::Italics` **[字段名未证实]** |
| 4 / 4:0–4:5 | 下划线样式(单/双/曲/点/虚) | [PR #15795 / commit d19aaf7 "Add support for underline style and color in VT"](https://github.com/microsoft/terminal/commit/d19aaf7ead82aa11ae18673f67715e9c85b92884) |
| 9 | crossed-out(删除线) | `CharacterAttributes::CrossedOut` **[字段名未证实]** |
| 21 | doubly underlined | [commit e7a1a67 "Add support for the 'doubly underlined' graphic rendition attribute"](https://github.com/microsoft/terminal/commit/e7a1a675af7d3aaa0444fd8d15e3652ffccd70c3) |
| 53 | **overline(上划线),不是双删除线** | [commit 70a7ccc "Add support for the 'overline' graphic rendition attribute (#6754)"](https://github.com/microsoft/terminal/commit/70a7ccc120d5d5a096e82aff16da299ec6c2ed06)、[issue #6000](https://github.com/microsoft/terminal/issues/6000) |
| 58 / 59 | 下划线颜色(set / reset) | [PR #15795](https://github.com/microsoft/terminal/pull/15795) + 渲染侧 [PR #16097 / commit e268c1c](https://github.com/microsoft/terminal/commit/e268c1c952f21c1b41ceac6ace7778d2b78620bf) |

> **纠正提问中的一个前提**:ECMA-48 与 WT 的 **53 = overlined**,WT **没有"双删除线"**;"双下划线"才是 21。这点有 issue #6000 / commit 70a7ccc 直接证据。

---

## ② 字体匹配:一个 family + 运行时 weight/style

### 2.1 数据模型:`FontInfoDesired` / `FontInfo`

这是从 conhost/GDI 时代继承下来的结构(`src/types/inc/FontInfoBase.hpp`、`FontInfo.hpp`、`FontInfoDesired.hpp`),字段本质是 **LOGFONT 的抽象**:

- `_faceName`(单个族名字符串)
- `_weight`(数值,GDI `FW_*` 与 DWRITE 权重同域:`FW_NORMAL=400`,`FW_BOLD=700`)
- `_family`(GDI family flags)、`_codePage`
- `FontInfo` 追加**已解析的实际尺寸**:cell 像素尺寸 `_coordSize` / `_coordSizeUnscaled`;`FontInfoDesired` 追加"期望点大小 / EngineSize"

**机制要点(高置信,细节 [未证实])**:这个结构里**只有 weight,没有 italic / stretch**。也就是说 WT 的"字体对象"只描述**基础字体**(族名 + 基础权重 + 尺寸),而 **bold/italic 是逐 run 的 `TextAttribute` 属性**,在 `UpdateDrawingBrushes` 时才与字体合成。这与提问中的判断一致:设置里没有 `font.italic` 这个键——本次搜索**没有找到** `font.italic` 的任何文档或 schema 证据,**判定为不存在 [未证实/疑不存在]**;斜体只能由 SGR 3 产生。

### 2.2 设置层(settings.json)

- `font.face`(旧 `fontFace`):族名。**1.20+ 支持 fallback 列表**——[PR #16821 / commit de7f931 "Add support for customizing font fallback"](https://github.com/microsoft/terminal/commit/de7f931228312996a8b586e5348d5dda46610b84),需求来自 [issue #5634 "Update fontFace to support multiple fonts"](https://github.com/microsoft/terminal/issues/5634)。实现机制是 **`IDWriteFontFallbackBuilder::AddMapping` + `CreateFontFallback`**,把用户指定的族按顺序排在系统 fallback 之前 **[实现细节未证实,但 API 与 PR 标题一致]**。
- `font.weight`:[PR #6048 / commit d1560fe "Add font weight options"](https://github.com/microsoft/terminal/commit/d1560fe9c1e20c85d7e121616b9382e5c35954c6),后续修 schema [commit af56088 (#6248)](https://github.com/microsoft/terminal/commit/af56088cb6c515752ca09cc2c87fc5f5182bed25)。取值是字符串枚举(thin/extra-light/light/semi-light/normal/medium/semi-bold/bold/extra-bold/black/extra-black)或 100–990 数值,底层就是 `DWRITE_FONT_WEIGHT`。
- `font.features` / `font.axes`:仓库里有设计文档 `doc/specs/#1790 - Font features and axes-spec.md`([归档副本](https://archive.softwareheritage.org/browse/content/sha1_git:63b56230361558adfdba5c979e76c4e44442df2f/?path=doc/specs/%231790%20-%20Font%20features%20and%20axes-spec.md))。`font.axes` 是**可变字体轴**(如 `"wght": 650`),这是拿到"非 700 粗度"的正规途径。
- `intenseTextStyle`:见 §3。官方文档:[配置文件外观设置](https://learn.microsoft.com/zh-cn/windows/terminal/customize-settings/profile-appearance)(取值 none/bold/bright/all;**默认值我记为 `bright`,但本次未取到明确文档快照 → [未证实]**)。

### 2.3 渲染层怎么决定"用哪个字体文件"

1. `AtlasEngine::UpdateFont(FontInfoDesired&, FontInfo&, features, axes)` → 内部 `_resolveFontMetrics(...)` 把请求解析成一个 `FontSettings`(在 `src/renderer/atlas/common.h`),内容包括:字体集合、族名、`fontSizeInDIP`、`cellSize`、基础 `fontWeight`、以及**下划线/删除线/双下划线/上划线的位置与粗细** **[字段名未证实]**。
2. 建立 **4 个 `IDWriteTextFormat`**:regular / bold / italic / bold-italic,索引由一个位枚举给出(我记忆为 `FontRelevantAttributes { Bold = 0b01, Italic = 0b10 }`,配 `_getTextFormat(attributes)`;本次搜索**未命中该标识符** → **[未证实]**)。`CreateTextFormat` 的参数即 `(familyName, fontCollection, weight, style, stretch, sizeInDIP, localeName)`;bold 变体传 `DWRITE_FONT_WEIGHT_BOLD(700)`,italic 变体传 `DWRITE_FONT_STYLE_ITALIC`。**这一步就是"SGR → 字体文件"的全部决策**:同一族名 + 不同 (weight, style) 交给 DWrite 去挑 face。
3. **逐字符回退**:AtlasEngine 用 `IDWriteFontFallback::MapCharacters`(基线参数取自当前 text format 的 collection/family/weight/style/stretch),返回 `mappedLength / mappedFont / scale`,再 `mappedFont->CreateFontFace(...)`。搜索索引到 `AtlasEngine.cpp` 中的实际代码行片段 `mappedEnd = idx + mappedLength;`([raw 索引命中](https://raw.githubusercontent.com/microsoft/terminal/17db409e7ab7869b3757cf911fd1e5d307c9c290/src/renderer/atlas/AtlasEngine.cpp)),可确认该循环存在。关键:**回退发生在"字符 → 字体"层,并且继承当前 run 的 weight/style**,所以 CJK/emoji 回退字体也会尽量取其 bold/italic 变体。
4. 还支持"**邻近字体**"(与可执行文件同目录、未安装的字体):[commit 4c364e9 "Use nearby fonts for font fallback (#11764)"](https://github.com/microsoft/terminal/commit/4c364e9342ee090711e3d022c81e23bc2af00265)。
5. **"Cascadia Code Bold" 这类带样式后缀的族名**:DWrite 的 `FindFamilyName` 只认 family name(WWS/typographic family),后缀通常匹配不到。WT 曾尝试用 font set 过滤来解析"复杂名字规格":[PR #10777 "[DRAFT] Use Font Set filtering/matching to better resolve complex name specifications"](https://github.com/microsoft/terminal/pull/10777) —— **注意它是 DRAFT,未合并**。所以"写 Bold 后缀就能选到 Bold 变体"在 WT 里**不是可靠机制**;正解是 `font.weight` 或 `font.axes`。DWrite 的匹配规则(WWS 模型、`GetMatchingFonts`、`ConvertWeightStretchStyleToFontAxisValues`)见 [DirectWrite: Font selection](https://learn.microsoft.com/en-us/windows/win32/DirectWrite/font-selection)。
6. **等宽 cell 的确定**:用参考字形的推进宽度算 cell 宽、用字体 ascent/descent/lineGap 算 cell 高,然后取整;取整策略有专门 PR:[#13833 "AtlasEngine: Round cell sizes to nearest instead of up"](https://github.com/microsoft/terminal/pull/13833);用户可覆盖 cell 尺寸:[PR #14255 "Implement cell size customizations"](https://github.com/microsoft/terminal/pull/14255)。字形比 cell 宽时会缩放:[commit b6acacc "AtlasEngine: Scale glyphs to better fit the cell size"](https://github.com/microsoft/terminal/commit/b6acacc82f7a285230312987c0600417e6295bc9)。**用哪个字符做参考(我记为 `L"0"`)→ [未证实]**。

---

## ③ 粗体:真粗体 + DWrite 模拟,WT 自己不"双描"

**(a) 真粗体路径**:`TextAttribute::IsIntense()` 且 `RenderSettings::Mode::IntenseIsBold` 打开 → 该 run 选择 bold 版 text format(weight 700)→ DWrite 在族内挑 Bold face → 图集里生成独立字形条目。AtlasEngine 是**后来才补上**这条路的:[PR #13577 / commit feabe41 "AtlasEngine: Handle IntenseIsBold"](https://github.com/microsoft/terminal/commit/feabe41a08604345a1eeb4b38fd1c99b811f8ecd)(另有同名早期提交 [2fe72b8](https://github.com/microsoft/terminal/commit/2fe72b8845a1f59337a2c6408b2e65e51ed99186))。

**(b) 合成粗体**:
- 我**没有找到任何证据**表明 AtlasEngine 自己做 "x+1 双描"/2px 偏移叠加。搜索 `synthetic bold` / `double strike` / `DxSynthesizedTextRenderer` 在 microsoft/terminal 中**全部无命中**。**提问里提到的 `DxSynthesizedTextRenderer` 类:未找到任何证据,判定为不存在** (旧 DxEngine 的实际组成是 `CustomTextLayout` / `CustomTextRenderer` / `DxFontRenderData` / `DxFontInfo` / `BoxDrawingEffect`;`DxFontInfo.h` 可见于[镜像](https://github.com/skyline75489/terminal/blob/4f5e4fca911a3322634174b5fd9c27dc183fa8f0/src/renderer/dx/DxFontInfo.h)。而整个 dx 目录已随 [#16278](https://github.com/microsoft/terminal/pull/16278) 删除)。
- 因此**合成粗体来自 DirectWrite 自身**:系统字体集合会为缺少 Bold/Italic 实体 face 的族**暴露"模拟 face"**。旁证很直观:[StackOverflow: DirectWrite lists regular, Oblique, Bold, Bold Oblique versions of Microsoft Sans Serif, but they all point to the same TTF file](https://stackoverflow.com/questions/76839913/directwrite-lists-regular-oblique-bold-bold-oblique-versions-of-microsoft-san)。这些 face 带 `DWRITE_FONT_SIMULATIONS_BOLD`,光栅化时做**算法加粗(algorithmic emboldening)**,见 [DWRITE_FONT_SIMULATIONS 文档](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ne-dwrite-dwrite_font_simulations);也可以显式构造:[IDWriteFontFaceReference::CreateFontFaceWithSimulations](https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/nf-dwrite_3-idwritefontfacereference-createfontfacewithsimulations)。
- **AtlasEngine 是否显式传 `DWRITE_FONT_SIMULATIONS_*`,还是完全依赖集合里已有的模拟 face:[未证实]**。加粗的具体算法参数(外扩量与字号的比例)DWrite 未公开 → **[未证实]**。
- 对比:conhost 的 GDI 渲染器走 `HFONT.lfWeight = FW_BOLD`,由 GDI 自己合成——同样不是终端在画。

**(c) `intenseTextStyle`(窗口/profile 级)**:值 `none` / `bold` / `bright` / `all`,分别决定 SGR 1 是不做、加粗、取 16 色亮色变体、两者都做。它落到 `RenderSettings` 的两个 mode 位上,再影响 §3(a) 与颜色查表(`TextColor::GetColor(..., brighten)`)。生态证据:很多终端把 bold 映射到亮色([psmux 文档描述](https://raw.githubusercontent.com/psmux/psmux/refs/heads/master/docs/configuration.md));conhost 至今不支持这个设置([issue #18919 "Intense text as bold option for conhost/openconsole"](https://github.com/microsoft/terminal/issues/18919)、[issue #19077](https://github.com/microsoft/terminal/issues/19077))。

---

## ④ 斜体

- SGR 3 → `TextAttribute` 的 italics 位 → run 的字体属性含 Italic → 选 italic 版 text format(`DWRITE_FONT_STYLE_ITALIC`)。**AtlasEngine 对 style 的处理仅止于"选哪个 text format"**,不做几何变换 **[高置信,未逐行证实]**。
- 字体无 italic face 时:DWrite 的 WWS 匹配会退到 `DWRITE_FONT_STYLE_OBLIQUE`,或使用带 `DWRITE_FONT_SIMULATIONS_OBLIQUE` 的模拟 face(算法斜切)。**斜切角度未公开文档化 → [未证实]**(经验值约 20°,即 shear ≈ 0.3;不要当事实用)。
- 关于 `CreateTextLayout` 的 fallback:AtlasEngine **不用 `IDWriteTextLayout` 画正文**,所以"TextLayout 里 italic 怎么 fallback"对 WT 并不适用;它自己调 `IDWriteFontFallback` + `IDWriteTextAnalyzer`(见 §6)。旧 DxEngine 也是自定义布局(`CustomTextLayout`),同样不是 TextLayout。
- 工程副作用:斜体/模拟斜体字形常越过 cell 右边界。WT 的应对是"字形可能溢出 cell"这一整套逻辑(缩放 [b6acacc]、脏区/重绘扩展),**具体溢出裁剪策略 [未证实]**。

---

## ⑤ 下划线 / 删除线:不是 DWrite 文本装饰,是引擎自绘

**结论:WT 不用 `IDWriteTextLayout::SetUnderline/SetStrikethrough`,而是自己画线。**

1. **通道**:`Renderer` 把 `TextAttribute` 翻成 `GridLineSet`(位集合),经 `IRenderEngine::PaintBufferGridLines(lines, gridlineColor, underlineColor, cchLine, coordTarget)` 下发。`GridLines` 枚举含 Top/Bottom/Left/Right/Underline/DoubleUnderline/Strikethrough/HyperlinkUnderline,以及 #16097 之后新增的 Dotted/Dashed/Curly 变体 **[具体枚举项名 [未证实]]**;`til::enumset` 化见 [commit dacff61](https://github.com/microsoft/terminal/commit/dacff61f8862fa7c28f0244e74555cb2658455ad)。
2. **AtlasEngine 侧实现**:先把每行的线段范围收集起来(per-row grid-line ranges),Backend 再统一绘制;补齐全部线型的 PR 是 [#13587 "AtlasEngine: Implement remaining grid lines"](https://github.com/microsoft/terminal/pull/13587)。另有优化:[commit 7d637b8 "Check if there are any lines to paint in the grid line renderer before…"](https://github.com/microsoft/terminal/commit/7d637b8f50a95e48811dfe210b18f1982b5b6013)。
3. **样式与颜色**:VT 侧 [PR #15795](https://github.com/microsoft/terminal/pull/15795)(SGR `4:0`–`4:5`、58/59),渲染侧 [PR #16097 / commit e268c1c "Support rendering of underline style and color"](https://github.com/microsoft/terminal/commit/e268c1c952f21c1b41ceac6ace7778d2b78620bf)。曲线下划线的绘制在 D3D 后端由**着色器**完成(shading type 分支),后续两次修正/改进:[PR #16444 "Fix curlyline rendering in AtlasEngine and GDIRenderer"](https://github.com/microsoft/terminal/pull/16444)、[commit 09aa541 "AtlasEngine: Improve appearance of curly underlines (#17501)"](https://github.com/microsoft/terminal/commit/09aa541d56dc4ab4650ff8803dfb9414f952ecd0)。**我记忆中的宏名 `SHADING_TYPE_CURLY_LINE` / `SHADING_TYPE_DOTTED_LINE` 本次搜索未命中 → [未证实]**。
4. **线参数来自字体,不是硬编码**:`DWRITE_FONT_METRICS` 提供 `underlinePosition` / `underlineThickness` / `strikethroughPosition` / `strikethroughThickness`(设计单位,需 `/designUnitsPerEm * fontSizeInDIP` 缩放,再钳到 ≥1px)——见 [DWRITE_FONT_METRICS](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/ns-dwrite-dwrite_font_metrics)。`_resolveFontMetrics` 把它们烘成 `FontSettings` 里的整数像素字段。**双下划线**由两条"细线"构成(我记忆中有 `doubleUnderline[2]` 与 `thinLineWidth` 字段)→ **[字段名与具体公式未证实]**。
5. **上划线** SGR 53 同走 grid line 通道([commit 70a7ccc](https://github.com/microsoft/terminal/commit/70a7ccc120d5d5a096e82aff16da299ec6c2ed06));**双删除线不存在**。
6. **超链接下划线**(OSC 8)是独立的 grid line 位:[PR #12225 "Add support for hyperlinks to AtlasEngine"](https://github.com/microsoft/terminal/pull/12225)。
7. **双宽/双高行**(`src/buffer/out/LineRendition.hpp`,[文件](https://github.com/microsoft/terminal/blob/3accdcfc/src/buffer/out/LineRendition.hpp))会让装饰线的坐标/长度按行倍率缩放;AtlasEngine 为此专门修过崩溃:[commit c2c5f41 "AtlasEngine: Fix a crash when drawing double width rows (#13966)"](https://github.com/microsoft/terminal/commit/c2c5f410f96c8eb3b8f4c53fc15a2b6da6fd8991)。

---

## ⑥ DWrite 在其中的确切职责

| 环节 | 谁做 | 证据 |
|---|---|---|
| 字体文件/集合解析 | DWrite:system font collection、custom collection(含"邻近字体")、font fallback builder | [#11764](https://github.com/microsoft/terminal/commit/4c364e9342ee090711e3d022c81e23bc2af00265)、[#16821](https://github.com/microsoft/terminal/commit/de7f931228312996a8b586e5348d5dda46610b84) |
| weight/stretch/style → face | DWrite WWS 匹配(含模拟 face) | [DirectWrite: Font selection](https://learn.microsoft.com/en-us/windows/win32/DirectWrite/font-selection) |
| 逐字符字体回退 | DWrite `IDWriteFontFallback::MapCharacters` | [API 文档](https://learn.microsoft.com/en-us/windows/win32/api/dwrite_2/nf-dwrite_2-idwritefontfallback-mapcharacters)、AtlasEngine.cpp 内 `mappedEnd = idx + mappedLength;` |
| 造型/连字/复杂脚本 | **WT 自己调 `IDWriteTextAnalyzer`**(`AnalyzeScript` → `GetGlyphs` → `GetGlyphPlacements`),**不用 TextLayout** | [PR #11623 里 lhecker 的注释:"DirectWrite seems 'reluctant' to segment text into clusters and I found no API which offers simply that"](https://github.com/microsoft/terminal/pull/11623)、[GetGlyphs 文档](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritetextanalyzer-getglyphs);组合字符修复 [commit 93be688 (#12307)](https://github.com/microsoft/terminal/commit/93be688e860a3540c58b28e553f99aca40566ee7) |
| 字形光栅化 | D2D/DWrite 把 glyph run 画进**图集纹理**,BackendD3D 再用实例化 quad 一次性贴出;ClearType 混合自己实现 | `src/renderer/atlas/BackendD3D.h`([文件](https://github.com/microsoft/terminal/blob/cec12bcf11e08a1e18b2cbb2952df1fcf3c55f58/src/renderer/atlas/BackendD3D.h))、[PR #12242 "AtlasEngine: Implement ClearType blending"](https://github.com/microsoft/terminal/pull/12242) |
| 框线/块元素字形 | **绕开字体,程序化绘制** | [commit a6a0e44 "Add support for custom box drawing and powerline glyphs (#16729)"](https://github.com/microsoft/terminal/commit/a6a0e44088ab768325665308367ac016a2534891)、[commit 94e74d2 "Make shaded block glyphs look even betterer (#16760)"](https://github.com/microsoft/terminal/commit/94e74d22c65ecec7fb3baacb837527f254bddf1f) |
| 装饰线 | **完全自绘**(矩形 / 像素着色器) | §5 |

**cell 网格映射**:等宽假设 → 每 cell 一个 advance;宽字符占 2 cell;造型结果按 cluster 对齐回 cell(这正是他们不用 TextLayout 的原因:需要 cluster 级控制);字形过宽则缩放([b6acacc]),cell 尺寸取整策略见 [#13833]。

---

## ⑦ 可借鉴的工程原理(面向自研 C/Odin 终端)

1. **三层切分,字体只出现在最后一层**
   - 语义层:每 run 一个位域 `style { intense, italic, underline_style:3, crossed_out, overlined, ... }` + 3 个颜色。**永远不要在缓冲区里存字体句柄**。
   - 策略层:`intense → bold?` / `intense → bright?` 是**渲染设置**,不是 VT 语义(WT 的 `intenseTextStyle` + `RenderSettings::Mode`)。自研时同样应做成一个 2-bit 开关,而不是在解析器里写死。
   - 渲染层:`(family, weight, style)` → face 的匹配交给平台字体栈(DWrite / FreeType+fontconfig),**终端不解析字体文件**。
2. **预建"变体槽",用位索引取,不要字符串查表**
   WT 的做法等价于 `format[bold | italic<<1]` 四个槽。DOD 化就是:`FontVariant variants[4]`(regular/bold/italic/bold_italic),run 属性直接算出索引 —— 热路径零查找、零分配。
3. **粗/斜的合成交给字体栈,自己只留降级方案**
   WT 完全不做双描;若自研用 FreeType,对应能力是 `FT_Outline_Embolden`(算法加粗)与 `FT_Matrix` shear(算法斜体)。**只有在字体栈也不合成时**才考虑 "x+1 双描",并注意它的两个代价:(a) advance 不变会导致字形相互侵占;(b) 会污染图集 key(必须把"是否合成"编入 key)。
4. **字形走图集,装饰走几何/着色器 —— 两条通道彻底分离**
   下划线/删除线**不要**烘进字形位图,否则 atlas key 会因线型/颜色组合爆炸,而且跨 cell 的连续线会断。WT 的 `GridLineSet` + per-row 线段范围是标准解法:一趟收集、一趟绘制。
   建议 atlas key = `(face_id, glyph_index, 渲染模式, 行倍率)`;**颜色绝不进 key**(颜色是顶点属性/uniform)。
5. **装饰线参数一律取自字体 metrics,再钳制到整数像素**
   `underlinePosition/Thickness`、`strikethroughPosition/Thickness` 从字体读,`thickness = max(1px, round(...))`;位置按 baseline 计算并对齐像素栅格,才能让相邻 cell 的线**首尾相接不断裂**。双下划线 = 两条细线,总占位不超过 cell 底部余量。
6. **曲线/点/虚线用着色器程序化生成**,不要预烘纹理:一个 `shading_type` 分支 + 段内相位即可(WT 的 curly underline 就迭代了三次才好看:#16097 → #16444 → #17501,说明"看起来对"的成本主要在相位/抗锯齿,不在架构)。
7. **框线/块元素自己画**:WT 用 `BuiltinGlyphs` 绕开字体(#16729/#16760)。自研终端同理——U+2500 区段与 U+2580 区段程序化绘制,能同时解决"字体没有该字形"和"不严格贴合 cell"两个问题。
8. **一次遍历只产出一种数据**(与本仓库 DOD 规范一致):第 1 趟把行内 attribute run 拆成 `glyph run` 工作表,第 2 趟拆成 `grid line` 工作表,第 3 趟提交绘制;不要在造型循环里顺手画线。

---

## 附:本报告的证实度清单

**已由搜索索引确认存在**(链接均在正文):PR/commit #6048、#6248、#6754、#10777(DRAFT)、#10778、#11623、#11764、#12225、#12242、#12252、#12304、#12307、#13577、#13587、#13833、#13906、#13966、#14210、#14255、#15795、#16097、#16278、#16444、#16729、#16760、#16821、#17501、#18919、#19077、#5634、#6000;文件 `src/renderer/atlas/AtlasEngine.h`、`AtlasEngine.cpp`、`BackendD3D.h`、`src/renderer/inc/IRenderEngine.hpp`、`src/buffer/out/LineRendition.hpp`、`src/renderer/dx/DxFontInfo.h`(历史);文档 `doc/specs/#1790 - Font features and axes-spec.md`。

**未证实(勿当事实)**:具体行号;标识符 `FontRelevantAttributes` / `_getTextFormat` / `textFormats[4]` / `FontSettings` 字段名(`underlinePos`、`doubleUnderline[2]`、`thinLineWidth`)/ `SHADING_TYPE_*` 宏名;cell 参考字形是否为 `"0"`;AtlasEngine 是否显式设置 `DWRITE_FONT_SIMULATIONS_*`;DWrite 算法加粗/斜切的具体参数与角度;`intenseTextStyle` 的默认值;`font.italic` 设置项(**大概率不存在**);`DxSynthesizedTextRenderer` 类(**大概率不存在**)。
