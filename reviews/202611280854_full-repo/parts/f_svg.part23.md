# f_svg 模块审查报告（模块第 23/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg`（本部分 14 个 `.cj` + 0 个 `.md`，共 14 个文件；覆盖文本基线 / 装饰线 / 文本元素模型 / textPath 排版与对应测试）
- **基线**：工作区快照（master 与 sts/1.3.x 同为 `120fd2542`，`git diff` 为空；全部记为「存量」）
- **审查重点**：SVG/XML 解析与序列化边界、注入与转义、递归与栈溢出、OOM、死代码、重复逻辑（本轮专项）；本部分实际落在「属性值解析边界 / 装饰线段生成放大 / 重复实现」
- **报告版本**：v1

## 发现

### [严重][存量] `dotted` / `dashed` 装饰线的段数由 `text-decoration-thickness` 与字形 advance 之比决定，没有上界：一个属性值即可让渲染挂死并撑爆堆

- **位置**：`f_svg/src/SvgTextDecoration2.cj:182-189`（`Dotted`：`step = safeThickness * 2.0`，`while (x < width) { … x += step }`）、`f_svg/src/SvgTextDecoration2.cj:190-198`（`Dashed`：`x += dash + gap`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界增长 / 按不可信数值放大的循环」、§6.4「复杂度由外部参数放大」
- **证据**：静态确定 —— `safeThickness`（`:168`）只保证 `> 0`，没有下界；`thickness` 来自 `text-decoration-thickness`（`f_svg/src/SvgTextRenderer.cj:946-967`，同样只校验 `isFiniteSvgNumber(value) && value > 0.0`）；`width` 是该字形的 `advance`（`SvgTextRenderer.cj:851-857`，随 `font-size` 线性）。迭代次数 = `advance / (2 · thickness)`，每轮还追加 5 条 `SvgPathCommand`（`SvgTextDecoration2.cj:219-236`）
- **描述**：`<text font-size="10" text-decoration="underline" style="text-decoration-style:dotted;text-decoration-thickness:0.0000001px">A</text>` 让单个字形的迭代次数达到 `5 / 2e-7 = 2.5e7`，即 1.25 亿条路径命令：先是内存暴涨（每条命令一个 `Array<Float64>`），再是长时间占用 CPU；把厚度再缩小两个数量级就是事实上的挂死。同一份 SVG 里放 10 个这样的元素即可拖垮进程。触发不需要任何越权，只要渲染外部 SVG 就成立（`SvgRenderer.render` 对输入不做厚度下限校验）。`Dotted` 与 `Dashed` 是同源问题，两处都在
- **建议**：在 `appendSvgDecorationSegments` 入口把厚度钳到与字号相关的下界（如 `max(thickness, fontSize / 100)`，需要把 `fontSize` 传进来），并对段数设硬上限（`let maxSegments = 256`，超限退化为 `Solid` 或直接截断并记一次 warning）；`svgDecorationThicknessPx` 侧也补同一条下限，避免两个调用点各写一套

### [一般][存量] 无样式树时 `text-underline-position` 的继承被静默丢弃：既不沿用已继承的计算值，也不像另外四个属性那样向上找最近声明

- **位置**：`f_svg/src/SvgTextDecoration2.cj:255`（`var underlinePosition = style.textUnderlinePosition()`）、`f_svg/src/SvgTextDecoration2.cj:356-362`（`if (first) { underlinePosition = match (node.attr("text-underline-position")) { Some → … ?? Auto; None → Auto } }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「语义与注释不符」「边界 / 空值未处理」；同函数注释 `f_svg/src/SvgTextDecoration2.cj:238-241` 明确写着「`text-underline-position` 直接读取已继承的计算值」
- **证据**：静态确定 —— 进入 `styles.isNone()` 分支且 `first == true` 时，无论元素有没有该属性都会重新赋值：有属性就解析，没有就写死 `Auto`。`:255` 读到的继承值在 `None` 分支被覆盖；循环体在 `first == false` 时不再读该属性，所以祖先元素上的声明同样看不到。属性表本身就把它标成继承属性（`f_svg/src/SvgComputedStyle.cj:150`，`SvgPropertySpec("text-underline-position", true, "auto")` 的第二参 `true`）
- **描述**：`<g text-underline-position="under"><text text-decoration="underline">A</text></g>` 走 `decorationOutline(text, style: …)`（`styles` 默认 `None`，`f_svg/src/SvgTextRenderer.cj:899-904`）时，下划线位置会从 `under` 退化成 `Auto`，线与字形的间距随之改变。同一份规格在渲染器的另一条路径上行为不同：`svgDecorationSpecFromAttributes`（`SvgTextRenderer.cj:1008` 取 `parent.underlinePosition`、`:1040-1044` 仅在子元素显式声明时覆盖），说明这里不是「有意如此」，而是两条实现漂移
- **建议**：`if (first)` 分支只在 `attr` 命中时覆盖（`case None => ()`），保留 `style.textUnderlinePosition()`；若确实要按属性走，就把该属性并入上方的 `have*` 机制，与其他四个属性共用「最近声明祖先」逻辑

### [一般][存量] `text-decoration` 有两套解析实现，public 的严格版与模块实际使用的宽松版语义已漂移

- **位置**：`f_svg/src/SvgTextDecoration.cj:70-117`（`SvgTextDecoration.tryParse`，严格）、`f_svg/src/SvgComputedStyle.cj:635-658`（`parseSvgDecorationLines`，宽松）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「重复逻辑导致的行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— 两者都是「按空白切 token → 映射 underline/overline/line-through」，差异可逐条列出：① 未知 token：严格版 `:104` 直接 `return None`，宽松版 `:651` 忽略；② `none` 与其它值并存：严格版 `:107-112` 返回 `None`，宽松版只认整串等于 `"none"`（`:640`），`"none underline"` 得到 `underline`；③ 分隔符：严格版认空格与逗号（`:83`、`:90` 的 `b','`），宽松版走 `splitCssWhitespaceWords`（`f_svg/src/CssSelector2.cj:889-906`，只按 CSS 空白切，不认逗号）；空白集合本身也不同（严格版用 `isSvgSpace`，`f_svg/src/SvgNumber.cj:68-70`；宽松版用 `isCssSpace`，`f_svg/src/CssLexer.cj:220-222`，多一个 `0x0C`）。模块内部（`:301`、`:310` 的属性回退、`SvgComputedStyle.textDecoration()`）全部走宽松版，严格版只有 `SvgValueTypesM4_test.cj:72-84` 在用
- **描述**：对外导出的 `SvgTextDecoration.tryParse("underline dotted")` 返回 `None`，而同一个库渲染 `text-decoration="underline dotted"` 时按 `underline` 处理；调用方若用 public API 校验属性值，会与渲染结果不一致。两套实现各自维护 token 表，后续加关键字（如 `spelling-error`）必然只改一处
- **建议**：保留宽松版为唯一扫描实现（关键字表提成 `const` 数组），严格版改为「先 `parseSvgDecorationLines`，再校验 token 全部被消费」的薄包装；两处空白集合统一到 `isCssSpace`（CSS 语义更完整），避免 SVG/CSS 两条分词口径分叉

### [一般][存量] `SvgTextPathLayout.place` 不可重入：`warnings` / `pathEmpty` / `stretchScale` 是实例可变状态，既不清理也不加锁

- **位置**：`f_svg/src/SvgTextPathLayout.cj:55`（`public let warnings`）、`:57`（`internal var pathEmpty`）、`:59`（`internal var stretchScale`）、`:74-75`（`place` 只重置自身两个字段，不清 `warnings`）、`:84` / `:168`（`warnings.add`）、`:101`（`stretchScale = factor`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护」「发布逸出」，§5「无界容器」
- **证据**：静态确定 —— `place` 无任何同步，且 `stretchScale` 要在 `place` 返回之后由调用方读取（`SvgTextRenderer.cj:705` `glyphScaleX = scaleX * pathLayout.stretchScale`、`:711` `pathLayout.pathEmpty`），即「先写后读」跨两次访问；`warnings` 从不清空。仓内每次 `layout` 都 `SvgTextPathLayout()` 新建（`SvgTextRenderer.cj:662`），所以本仓不触发；触发条件是外部把同一个实例复用于多次/多线程排版
- **描述**：public 类暴露可变状态却把「正确性」寄托在调用方每次新建实例上：① 复用同一实例排两段文本，第二段的 `warnings` 会带走第一段的告警（重复上报，长生命周期实例上无界增长）；② 两个线程同时 `place` 时，A 读到的 `stretchScale` 可能来自 B 的 `stretch` 计算，字形被错误缩放，`pathEmpty` 也可能被覆盖成另一条路径的状态。证据等级：竞争本身静态确定，是否存在这样的调用方为 `待确认`（本仓无）
- **建议**：把 `warnings` / `pathEmpty` / `stretchScale` 收进 `place` 的返回值（新增 `SvgTextPathLayoutResult { placements, warnings, pathEmpty, stretchScale }`），让类本身无状态；若要保留现有签名，至少在 `place` 入口 `warnings.clear()`，并在类注释里写明「非线程安全，不可多线程复用」

### [轻微][存量] `SvgDecorationStyle.none()` 全仓零引用

- **位置**：`f_svg/src/SvgTextDecoration2.cj:117-119`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal class` 的静态方法，非 public 顶层声明，全项目搜引用）
- **证据**：静态确定 —— 全仓 grep `SvgDecorationStyle` 只命中定义处、`resolveSvgDecorationStyle` 的构造（`:367`）与 `SvgTextRenderer` 的字段/构造，没有任何 `SvgDecorationStyle.none()` 调用；`SvgDecorationStyle` 是 `internal class`（`:96`），成员对外不可达
- **描述**：与 `SvgTextDecoration.none`（struct 静态值，被广泛使用）重名但用途不同的空实现残留，容易让人误以为装饰规格有统一的「none」入口。建议删除，或让 `SvgTextRenderer` 的默认值改用它以消除重复
- **建议**：删除该方法；若保留，把 `SvgTextRenderer.cj:63` / `:179` 的 `SvgDecorationStyle(lines: decoration)` 改为经过它构造

### [轻微][存量] `SvgDecorationStyle` 与 `SvgTextDecorationSpec` 是字段逐项相同的双表示

- **位置**：`f_svg/src/SvgTextDecoration2.cj:96-120`（internal，5 个 `let` + 同一组默认值）与 `f_svg/src/SvgTextDecoration2.cj:123-157`（public，同样 5 个 `let` + 同一组默认值，仅多一个 `toString`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名」的重复表示
- **证据**：静态确定 —— 两个构造函数的 5 个具名参数、默认值、赋值顺序逐行对应；`SvgTextDecorationSpec` 只由 `SvgComputedStyle.textDecorationSpec()`（`f_svg/src/SvgComputedStyle.cj:537-539`）产出，渲染链路实际消费的是 `SvgDecorationStyle`（`SvgTextRenderer.cj:38`、`:200`）
- **描述**：新增一个装饰属性（例如 `text-decoration-skip-ink`）要同时改两个类型、两个构造、两个默认值，漂移几乎必然。目前 public 版本只产出不被内部消费，属于「对外契约与内部模型并行」
- **建议**：让 `SvgTextDecorationSpec` 成为唯一表示（把 `SvgDecorationStyle` 换成 `type` 别名或直接复用），或给 `SvgTextDecorationSpec` 增加 `toStyle()` 并让 `SvgComputedStyle.textDecorationSpec()` 之外只保留一条路径

### [轻微][存量] 「是否声明了装饰属性」判定与属性名清单两处各写一遍，判定口径已不同

- **位置**：`f_svg/src/SvgTextDecoration2.cj:377-385`（`svgDecorationDeclares`，专用名 `text-underline-position` 返回 `false`）与 `f_svg/src/SvgTextRenderer.cj:984-997`（`svgDecorationStyleDeclared`，5 个名字统一判断，含 `text-underline-position`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「字面量复制（同一组属性名散落多处）」
- **证据**：静态确定 —— 两处都硬编码 `text-decoration-line/-style/-color/-thickness`（+ `text-decoration` 简写），第三份同类清单在 `f_svg/src/SvgComputedStyle.cj:146-150` 的属性表；`svgDecorationDeclares` 对 `text-underline-position` 特判返回 `false`，另一份不含该特判
- **描述**：三份清单靠人工同步；`text-underline-position` 的差异已经让两条路径对「是否声明」给出不同答案（配合上面第 2 条，就是继承丢失的另一半原因）
- **建议**：在 `SvgComputedStyle` 侧导出一个 `static let DECORATION_PROPERTIES: Array<String>`（含简写），两处判定改为遍历它；`text-underline-position` 的特殊性用参数表达（`includeUnderlinePosition!: Bool`）

### [轻微][存量] `offset()` 用 `0.0 * fontSize` 表达「无偏移」，`fontSize` 非有限时把 0 变成 NaN

- **位置**：`f_svg/src/SvgTextBaseline.cj:231`（`case Auto | Alphabetic => 0.0 * fontSize`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「边界 / 浮点」、可读性（无意义的乘法）
- **证据**：静态确定 —— `0.0 * Infinity = NaN`、`0.0 * NaN = NaN`；调用链 `baselineOffsetFor`（`f_svg/src/SvgTextRenderer.cj:1073-1097`）把结果直接加进字形 `y`，没有 `isFinite` 兜底
- **描述**：`font-size="1e400"` 之类的属性值如果被解析成 `Infinity`（`SvgLength.tryParse` 未做上限校验），字形 `y` 变成 `NaN`，整段文本静默消失且无 warning。写成 `0.0` 既不影响正常路径，也避免这条 NaN 通道
- **建议**：直接返回 `0.0`；若想保留「随字号缩放」的表达，改成 `0.0`（这两个基线本就不依赖字号），或在 `SvgLength` 解析层统一拒绝非有限值

### [轻微][存量] 三处测试断言偏弱或直接下标取字形，失败时报越界 panic 而不是断言失败

- **位置**：`f_svg/src/SvgTextLayoutCacheM4_test.cj:103`（`@Assert(decoratedCalls * 2 <= plainCalls * 3)`）、`f_svg/src/SvgTextBaselineM4_test.cj:52`、`:128`、`:142`、`:151`、`:155`（`layout.glyphs[0]`）、`f_svg/src/SvgTextPathLengthM6_test.cj:56`（`document.elementsByTag("text")[0]`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「可测试性」、§11「边界（空集合）」
- **证据**：静态确定 —— `plainCalls` 恒为 1，`2 * decorated ≤ 3` 允许 1.5× 放大，与用例名「不得放大布局次数」的意图不符；`glyphs` 为空时 `[0]` 抛越界，测试报错信息里看不到期望值
- **描述**：布局次数回归到 1.5× 也能通过；字形未生成时（例如 textPath 全部被截断）测试以 panic 中断，定位成本高于 `@Assert(glyphs.size == n)`。这些不影响产品质量，但会削弱本模块最关键的「装饰线不放大布局」与「textPath 落位」回归网
- **建议**：`@Assert(decoratedCalls == plainCalls)`；用 `@Assert(layout.glyphs.size > 0)` 或 `@Expect` 先断言规模再取下标

## 可见性建议

- `SvgTextDecoration.tryParse`（`f_svg/src/SvgTextDecoration.cj:70`）：对外可达的 `public`，但仓内只有 `SvgValueTypesM4_test.cj` 引用；按硬原则一**不判死代码**。若确认没有下游依赖，建议收窄到 `internal` 并在 README 中去掉，或按上面第 3 条改成宽松解析的严格包装后再保留。
- `SvgDominantBaseline.fromNameOrWarn`（`f_svg/src/SvgTextBaseline.cj:76-91`）：`internal`，仓内仅 `SvgValueTypesM4_test.cj:157` 引用（生产路径用的是 `fromName`）。按 §1「仅测试使用」处理，不判死代码；如需清理，可删测试或改测试走 `fromName`。

## 范围外提示

- `f_svg/src/SvgTextRenderer.cj:679-683`：只有 `side` 属性**存在**时才填 `sideOffsets`，于是默认（未写 `side`）与显式 `side="left"` 的视觉结果不同 —— 默认值与其显式写法不等价，属另一部分的接线问题。
- `f_svg/src/SvgTextRenderer.cj:1000-1052`（`svgDecorationSpecFromAttributes`）与本部分 `SvgTextDecoration2.cj:242-374`（`resolveSvgDecorationStyle`）是「属性 → 装饰规格」的两套实现，只是入口不同（tspan 子节点 / 文本根节点），建议合并（已计入 §2）。
- `f_svg/README.md:639`、`:643`：成员清单漏 `SvgTextDecorationSpec.style` / `.color` 与 `SvgTextPlacement.x` / `.y`（README 属另一部分，未计入本部分统计）。

## 优化可行性方案

### [堆内存] `SvgTextElement` 的 11 个 `SvgValueCache` 常驻对象改为按需创建

- **现状**：每个 `text` / `tspan` / `textPath` 元素构造时就分配 11 个 `SvgValueCache<T>` 实例（`f_svg/src/SvgTextElement.cj:98-108`），每个实例 3 个字段（`version: Int64` / `cached: ?T` / `hasCached: Bool`，`f_svg/src/SvgElement.cj:28-41`），典型文本只用得到 `x` / `y` / `textAnchor` / `fontSize` 中的少数几个
- **方案**：改成 `private var xCache: ?SvgValueCache<Array<SvgLength>> = None`，`get` 时判空惰性创建（或者用一个 `SvgValueCache` 按 key 分槽），把「11 个对象」压到「实际用到的 2-4 个」
- **预期**：元素对象图从 11N+1 个堆对象降到 ≤5N+1（对象数静态可推），10k 个 tspan 的文档少约 6 万个短命对象；峰值/常驻字节收益需实测
- **代价**：每个 getter 多一次 `Option` 判空与首次赋值（纳秒级）；`?SvgValueCache<T>` 的读写需要 `mut` 语义，代码量略增
- **验证**：同一 10k-tspan 文档，`cjpm` `-O2`，改前/改后各 5 轮取中位数，比较 `getAllocatedHeapSize()` 与 RSS 峰值
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `place()` 去掉多余的一次 advance 复制，并预分配结果容器

- **现状**：`f_svg/src/SvgTextPathLayout.cj:91-94` 先 `Array<Float64>(advances.size, repeat: 0.0)` 再逐元素拷贝；`method != Stretch` 时这次复制纯属浪费（`advances` 全程只读）；`:122` 的 `ArrayList<SvgTextPlacement>()` 未按字形数预分配，n 个字形会触发多次扩容
- **方案**：改为 `let adjusted = if (method == Stretch) { advances.clone() } else { advances }`（`stretch` 分支仍写 `adjusted[index] = …`，需要 `var adjusted` 与克隆）；`ArrayList<SvgTextPlacement>(advances.size)` 预分配
- **预期**：每次 textPath 排版少一次 O(n) 复制与 O(log n) 次扩容复制（n = 字形数）；端到端收益需 bench 证明
- **代价**：`adjusted` 的别名关系要写清（非 stretch 路径不得原地修改），语义无变化
- **验证**：`cjpm bench -O2`，输入 1k / 10k 字形、路径 100/1000 段的 textPath 排版，改前改后各 5 轮取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `dotted` / `dashed` 的段生成在正常厚度下也是热点（每字形 5 命令/段） | `f_svg/src/SvgTextDecoration2.cj:182-198` | 自耗时占比 | `cjprof record` 渲染 1k 个 `underline dotted` 的 text（font-size 20），看 `appendSvgDecorationRect` / `SvgPathCommand` 构造占比 |
| 2 | `resolveSvgDecorationStyle` 对每个文本元素走完整祖先链（4 属性 × 2 次 `sourceOf` × 深度），深树 + 大量 tspan 时放大 | `f_svg/src/SvgTextDecoration2.cj:258-366` | 调用次数与自耗时 | 构造 10k tspan、深度 50 的文档，`cjprof record`；对照「四标志全命中即 break」的改动前后耗时 |
| 3 | 11 个缓存对象的首次解析闭包分配是文本布局的主要分配来源 | `f_svg/src/SvgTextElement.cj:98-108` | 分配量与峰值 | `cjprof heap` + `getAllocatedHeapSize()`，1k/10k tspan 两档，按「优化方案 1」改造前后对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgTextBaseline.cj` | .cj | ✅ | `0.0 * fontSize` 的 NaN 通道（#8）；基线表与 `shift` 语义与 CSS 一致，`fromNameOrWarn` 属可见性建议 |
| 2 | `f_svg/src/SvgTextBaselineM4_test.cj` | .cj | ✅ | 基线偏移与 shift 覆盖完整；多处 `glyphs[0]` 无规模断言（#9） |
| 3 | `f_svg/src/SvgTextDecoration.cj` | .cj | ✅ | 严格版 `tryParse` 与宽松版漂移（#3）；`toString` 的 `text +=` 循环在 n ≤ 3 下不构成问题 |
| 4 | `f_svg/src/SvgTextDecoration2.cj` | .cj | ✅ | 本部分主要缺陷集中地：#1（段数放大）、#2（继承丢失）、#5（死代码）、#6（双类型）、#7（属性名清单重复） |
| 5 | `f_svg/src/SvgTextDecorationM4_test.cj` | .cj | ✅ | 像素级断言与渐变按字形断言设计合理；`ancestorPropagation` 走的就是 `styles == None` 分支，但没有覆盖 `text-underline-position` 继承，所以 #2 没被暴露 |
| 6 | `f_svg/src/SvgTextElement.cj` | .cj | ✅ | 11 个缓存的常驻分配（优化方案 1）；`fontFamily`/`fontWeight`/`fontStyle` 不走缓存属实现不一致，无功能影响 |
| 7 | `f_svg/src/SvgTextElement_test.cj` | .cj | ✅ | 属性读写往返、非法值回退覆盖到位；`SvgTextPath_test` 同时覆盖 href 双写法 |
| 8 | `f_svg/src/SvgTextLayoutCacheM4_test.cj` | .cj | ✅ | 「装饰线不放大布局」的断言允许 1.5×（#9） |
| 9 | `f_svg/src/SvgTextPath.cj` | .cj | ✅ | `path` 优先于 `href` 的注释与 `resolveTextPathData`（`SvgTextRenderer.cj:1516-1534`）一致；`side`/`method`/`spacing` 非法值静默回退到默认，有测试覆盖 |
| 10 | `f_svg/src/SvgTextPathExtensionM4_test.cj` | .cj | ✅ | side/method/spacing 与 stretch/exact 的主力回归；`defaultsMatchM3` 用等价性锁定默认值 |
| 11 | `f_svg/src/SvgTextPathLayout.cj` | .cj | ✅ | 段数无放大；截断/clamp 与 warning 语义自洽；实例可变状态（#4）、多余复制（优化方案 2） |
| 12 | `f_svg/src/SvgTextPathLayout_test.cj` | .cj | ✅ | 水平/45°/截断/空路径/降级覆盖到位；`:285` 类声明与文档注释同行，纯格式问题，未单列 |
| 13 | `f_svg/src/SvgTextPathLengthM6_test.cj` | .cj | ✅ | pathLength 校准起点与字形弧长的唯一回归；`elementsByTag("text")[0]` 无空检查（#9） |
| 14 | `f_svg/src/SvgTextPathModel_test.cj` | .cj | ✅ | `path` 属性读写往返覆盖；无缺陷 |

合计：`.cj` 14 个 / `.md` 0 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 #2、设计 #4/#6、语言特性 #8（`0.0 * fontSize`）、可读性 #9、安全性 #1（外部输入放大为 DoS）；本部分不拼接 SQL/命令、不写 HTML，无注入面 |
| §1 死代码 | 1 | 逐个 private / internal / protected 符号搜引用：`SvgDecorationStyle.none` 全仓零引用（#5）；`appendSvgDecorationRect`、`svgDecorationDeclares`、`readLengthArray` 等均有调用者；`SvgTextElement` 的 `public mut prop` 属对外可达 public 不判；`SvgTextDecoration.tryParse`、`SvgDominantBaseline.fromNameOrWarn` 仅测试引用，记可见性建议 |
| §2 重复逻辑 | 3 | `tryParse` vs `parseSvgDecorationLines`（#3）、`SvgDecorationStyle` vs `SvgTextDecorationSpec`（#6）、属性名清单与「是否声明」判定（#7）；另把 14 个文件里的函数体两两比对过，`fromNameOrWarn` 有 4 处同构实现（`SvgTextPath.cj:48`、`:94`、`:140` 与 `SvgTextBaseline.cj:76`），确属重复，但泛型化只能靠「解析函数 + 默认值」双参数注入，收益不抵抽象成本，仅记入此格不单列 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`case None => ()` 均为「可选属性缺失」的正常分支（`:294`、`:307-316`），有 `@Assert` 覆盖降级行为 |
| §4 栈溢出 | 0 | 本部分无递归：`resolveSvgDecorationStyle` 是显式 `while` 沿 `parent` 上溯，深度由 DOM 深度决定且为迭代；`appendSvgDecorationSegments` 的 4 个分支都是定步长循环（`Wavy` 固定 32 步）。唯一风险是父指针成环导致死循环，但环只能由程序化 `appendElement` 构造，解析产出的树无环，未定为缺陷 |
| §5 OOM | 1 | #1（`dotted`/`dashed` 段数随 `text-decoration-thickness` 放大，每段 5 条命令 + 数组）；`place()` 的结果数组上界由字形数决定，有界 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，任何「热点」结论不成立，已列待验证假设 1-3 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`；唯一共享可变状态是 #4 的实例字段，按 §12 计 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 线程池 |
| §6.4 低效算法 | 0 | 无嵌套循环、无热点 `contains`、无 `remove(at: 0)`；`dotted`/`dashed` 的复杂度放大已在 #1 按 §5 计数，不重复计；`SvgTextDecoration.toString` 的 `text +=` 循环上界为 3，不构成 |
| §7 降堆内存方案 | 1 | 优化方案「11 个 `SvgValueCache` 改按需创建」，`无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案「`place()` 去多余复制 + 预分配」，`无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分产生的 `SvgTextPlacement` / `SvgPathCommand` / 结果数组全部逃逸（作为返回值或写入显示列表），`@local` 不成立；只有 `place()` 内的 `adjusted` 数组不逃逸，收益需峰值内存对照，已并入待验证假设，不出改造建议 |
| §11 现有代码的 BUG（存量） | 4 | #2 继承丢失、#3 解析契约漂移、#8 NaN 偏移、#9 测试断言/越界；#1 按 §5 计。`place()` 的锚点负偏移钳制在测试里有明确语义（`startOffsetForms`「负值 / 超长钳制」），按有意设计处理，未报 |
| §12 并发安全与锁粒度 | 1 | #4（`SvgTextPathLayout` 三处实例可变状态无同步）；`SvgTextElement` 的 11 个 `SvgValueCache` 也是无同步的「检查-然后-写入」（实现见 `f_svg/src/SvgElement.cj:33-40`），但只在「并发读 + 同时改属性」下才有害，且属 `SvgElement.cj` 那部分，此处只作提示 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；`SvgTextPath` 的 `path`/`href` 优先级、`side`/`method`/`spacing` 均已接线（`SvgTextRenderer.cj:649-724`），未发现「承诺未实现」或半成品；README 成员清单遗漏见范围外提示 |
| 文件覆盖（§13 等） | 14/14 | 本部分清单 14 个文件全部读完，无缺失；本部分不含 `.md`，§13 的文档一致性由其他部分覆盖 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

文本栈的模型层（`SvgTextElement` 的属性/缓存、`SvgTextPath` 的枚举与属性、`SvgTextPathLayout` 的弧长映射）结构清楚，默认值与非法值回退都有测试锁定，`place()` 的截断与降级语义也和渲染器接线一致，是本模块里质量较高的一段。阻塞项只有一个但足够重：`dotted` / `dashed` 装饰线的段数完全由用户可控的厚度值放大，单个属性值就能把渲染拖成挂死/内存暴涨，必须在对外渲染前加下限与段数上限。其余需要排期的是三处「同一件事两种实现」造成的漂移：`text-decoration` 的严格/宽松两套解析、装饰规格的两个类型、以及两处「是否声明装饰属性」的判定——它们已经导致 `text-underline-position` 的继承在无样式树路径上丢失。测试侧只需要补强两处断言（布局次数、字形规模）即可，其余覆盖是扎实的。本部分 9 条发现全部为存量，是否纳入修复待用户决定。
