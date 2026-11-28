# f_svg 模块审查报告（第 24/26 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_svg/`（本部分 12 个文件：`SvgTextRenderer` / `SvgTimeline` / `SvgTransform` / `SvgTransformBox` / `SvgTransformOrigin` / `SvgTextWritingMode` 及其 6 个测试文件）
- **基线**：工作区快照（`120fd2542`，`git diff` 为空）⇒ 全部问题来源记「存量」
- **审查重点**：SVG 序列化边界、递归与栈溢出、OOM、死代码、重复逻辑（专项）；同时按 §11 核对存量 BUG
- **报告版本**：分部分报告（主 Agent 合并后另存 `f_svg_v2.md`）

## 发现

### [严重][存量] `discard` 无 href 时 `sample()` 直接改源文档，跨帧丢元素

- **位置**：`f_svg/src/SvgTimeline.cj:249-267`（`applyDiscards`，关键行 `:253` `case None => element.parent`、`:259-262` `parent.children.removeIf(...)`、`:263` `element.parent = None`；`discards` 采集自源文档 `:167`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源/状态不对称、契约与实现不符）、§12.1（发布可变状态）；对照类注释 `SvgTimeline.cj:146`「`sample` 深拷贝文档后在副本上求值…原文档不被修改」
- **证据**：静态确定 —— `init` 把 `document.root` 里的 `discard` 元素收进 `this.discards`（`:167`），`applyDiscards` 遍历的仍是这批**源文档**元素；`readSvgHref` 返回 `None` 时分枝取 `element.parent`，得到的 `parent` 属于源文档，随后 `parent.children.removeIf` 与 `element.parent = None` 全部作用在源树上。快照分支（href 存在）才取 `snapshot.elementById`
- **描述**：`<g><discard begin="1s"/><rect/></g>` 这类（合法，`SvgDiscardM6_test.cj:48` 也把「无 href 的 discard」当受支持输入）文档在 `t ≥ 1` 后会被 `sample()` 从**调用方文档**里删掉整棵 `g`，并把该元素的 `parent` 置空。后果：① 违反 `sample` 的「不改原文档」契约；② 第二次 `sample(0.0)` 拿到的快照也缺这个元素（源树已被破坏），时间轴不再可回放；③ 同一实例的 `sample` 变成有副作用的不可重入操作
- **建议**：`case None =>` 分支改用快照侧定位（`snapshot.elementById(spec/元素 id)` 或按 `elementPath()` 在 `snapshot` 上找同名兄弟），删除目标时只操作 `snapshot` 的 `children`；`svgDiscardNestingDepth` 也应在快照树上算。补一条「无 href 的嵌套 discard 连续采样两次」用例

### [一般][存量] `repeatDur` 被 `repeatCount`/`dur` 为 `indefinite` 的早退覆盖，活动时长永不结束

- **位置**：`f_svg/src/SvgTimeline.cj:116-128`（`totalDuration`，`dur` 早退 `:117-119`、`repeatCount` 早退 `:124-126`）；同一逻辑复制在 `:768`（`animationStateAt`）
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）、§2（同一判定两处各写一遍）
- **证据**：静态确定 —— 代码先按 `min(repeatDur, dur*repeatCount)` 算出 `total`（`:120-123`），紧接着 `if (isInfSvg(this.repeatCount)) { return Float64.Inf }` 把刚被 `repeatDur` 截断的结果丢弃；`dur` 为 `indefinite` 时 `:117` 更早返回 `Inf`
- **描述**：`dur="1s" repeatCount="indefinite" repeatDur="10s"` 的 SMIL 语义是活动期 10s，实现返回 `Inf` ⇒ 动画永不结束、`freeze` 永不生效、`duration()`（`:191-199` 跳过 `Inf`）返回 0，播放器无法确定总时长
- **建议**：先判 `repeatDur` 是否有限（有限则 `total = repeatDur` 并直接返回），再判 `repeatCount`/`dur` 是否无限；把 `:768` 的重复计算改为调用 `totalDuration()`

### [一般][存量] 长度单位换算四处各写一遍，`em`/`ex`/`dpi` 基准互相矛盾

- **位置**：`f_svg/src/SvgTextRenderer.cj:946-967`（`svgDecorationThicknessPx`）；`f_svg/src/SvgTransformOrigin.cj:132-151`（`resolveOriginComponent`）；对照既有公共实现 `f_svg/src/SvgLength.cj:205-226`（`toUserUnits` + `SvgLengthContext.dpi/fontSize`）与 `f_svg/src/SvgStyleResolver.cj:958-964`（`resolveFontRelativeLength`）
- **来源**：存量
- **判据**：review-checklist §2（换算复制、只改类型名的重复实现）、§11（语义与规格不符）
- **证据**：静态确定 —— `toUserUnits` 用 `context.dpi`（默认 96，可配）与 `context.fontSize`；`svgDecorationThicknessPx` 把 `In/Cm/Mm/Pt/Pc` 硬编码成 `96.0`、`Ex` 用 `fontSize/2`；`resolveOriginComponent` 却用 `Em → 16.0`、`Ex → 8.0` 固定值
- **描述**：`transform-origin="1em 1em"` 在 `font-size: 40` 的元素上应得到 (40,40)，实现固定得到 (16,16)，旋转中心偏移；同时 `text-decoration-thickness: 1in` 在配置了非 96 dpi 的渲染上下文里与其它长度属性不一致（同一文档两种物理单位口径）
- **建议**：统一走 `toUserUnits`：`effectiveElementTransform` 增补 `fontSize`/`dpi`（可从 `style.fontSize().value` 与渲染选项取），`svgDecorationThicknessPx` 改用 `toUserUnits(length, Horizontal, SvgLengthContext(...))`；两处删掉手写 `match (length.unit)`

### [一般][存量] `x` 与 `dx` 同时出现时 `dx` 被丢弃

- **位置**：`f_svg/src/SvgTextRenderer.cj:561-575`（`match (char.xOverride) { case Some(value) => pen = value … }`）；`dx` 的写入点 `:1250-1261`（tspan）、`:1337-1348`（根 `dx` 列表）
- **来源**：存量
- **判据**：review-checklist §11（边界/语义与 SVG 文本定位规则不符）
- **证据**：静态确定 —— `xOverride` 命中时把 `pen` 直接赋值为 `x`，`char.dx` 完全不参与；而 `dx` 已在 `:1252`/`:1339` 累加进 `char.dx`
- **描述**：SVG 中 `dx` 是在 `x` 建立的当前位置上再偏移（`<text x="10" dx="5">` 应落在 15），实现落在 10。`tspan` 上「x 列表 + dx」的组合同样失效，且无测试覆盖该组合（`SvgTextRenderer_test.cj:60-112` 只测了纯 `x` 与纯 `dx`）
- **建议**：`case Some(value) => pen = value + char.dx`（`x` 为绝对基准，`dx` 叠加），并补 `x`+`dx` 组合用例

### [一般][存量] warning 无去重、无上限：逐帧/逐字符/每次缓存重放都追加

- **位置**：`f_svg/src/SvgTimeline.cj:232`（`applyDiscards` 每次 `sample` 都 `warnings.add`）；`f_svg/src/SvgTextRenderer.cj:2027`（`applyFontSizeAdjust` 在逐字循环内 `add`）、`:444-446`（每个缺字体字符 `add`）、`:329-331`（布局缓存命中时把同一批 warning 再复制一遍）
- **来源**：存量
- **判据**：review-checklist §5（无界容器随请求增长）、§2（同一文案重复产生）
- **证据**：静态确定 —— 均为 `ArrayList<String>` 无容量上限、无 `contains` 去重、无 `clear`；`SvgTimeline.warnings`（`:150`，`public let`）随 `sample()` 调用次数单调增长
- **描述**：60 fps 驱动同一个 `SvgTimeline` 时，每条命中分支的 warning 每帧 +1（约 1 条字符串/帧/规格 ≈ 6 KB/s，一小时约 20 MB，且永不回收）；文本侧每次 `layout` 对同一字符重复 `add`（`hasDecoration` + `decorationOutline` + `outline` 会各走一次 layout，缓存命中还会重放一遍），同一条告警在一次渲染里出现 3–4 次，日志噪声大
- **建议**：warning 收敛为「去重集合」或在 `sample` 起始处清空本帧告警；循环内告警按「元素 + 属性」聚合成一条（带上计数）；`layout` 缓存命中只回放尚未见过的条目

### [一般][存量] `begin`/`end` 引用解析无深度上限，链长由文档决定

- **位置**：`f_svg/src/SvgTimeline.cj:709-752`（`resolveAnimationTime` 自递归 `:733-737`），调用点 `:175-187`
- **来源**：存量
- **判据**：review-checklist §4（无界递归，深度由输入决定）
- **证据**：静态确定 —— 递归深度 = `begin="a.end"` 链长度，`visiting` 只做环检测、不做层数限制；同文件的 `mpath` 解析（`:668`）显式 `depth > 64` 抛 `SvgErrorKind.Limit`，此处没有对应保护
- **描述**：一份含 N 个 `animate` 元素、`begin` 互指成链（无环）的文档，构造 `SvgTimeline` 时递归 N 层；N 只受文档元素数限制（解析期 `maxDepth` 限的是树深，不限兄弟数量），足够大时构造期栈溢出
- **建议**：加 `depth` 参数并在超过常量（与 `mpath` 的 64 对齐）时抛 `Limit`；或改显式栈迭代

### [一般][存量] `textPath` 只识别直接子元素，嵌在 `tspan` 内时静默降级为直线排版

- **位置**：`f_svg/src/SvgTextRenderer.cj:1497-1513`（`findTextPathElement`），调用点 `:387`
- **来源**：存量
- **判据**：review-checklist §11（能力与规范不符）、§14.1（只做了一半的分支）
- **证据**：静态确定 —— 只检查 `text` 自身与 `text.children` 一层；`SvgTextPath <: SvgTextElement`（`SvgTextPath.cj:159`）、`SvgTspan <: SvgTextElement`（`SvgTspan.cj:19`），SVG 允许 `textPath` 作为 `tspan` 的内容子元素
- **描述**：`<text><tspan><textPath href="#p">A</textPath></tspan></text>` 中字形仍被 `collectSvgTextChars` 收集（`:1124` 起按 `SvgTextElement` 递归），但路径几何完全被忽略，输出为普通水平文本，且**没有任何 warning**，使用者无从发现
- **建议**：`findTextPathElement` 改为深度优先遍历（带深度上限），命中后统一走 `:649` 的 textPath 分支；或至少在未命中但子树中存在 `textPath` 时给出 warning

### [轻微][存量] `SvgAnimationSpec.target` 写了不读

- **位置**：`f_svg/src/SvgTimeline.cj:29`（字段声明）、`:85`（唯一赋值点）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死字段）
- **证据**：静态确定 —— `SvgAnimationSpec` 为 `private class`，全仓仅本文件可见；`spec.target` 在 `SvgTimeline.cj` 内除 `:85` 赋值外无读取（`:205/:295/:303` 读的是 `targetId`/`targetPath`）
- **描述**：死字段，保留只会让读者误以为运行期还持有目标元素引用（实际目标每次 `sample` 都重新在快照里解析）
- **建议**：删除字段，构造参数只用于派生 `targetId`/`targetPath`

### [轻微][存量] 字形缓存键缺实际命中的字体面（`font-stretch`）

- **位置**：`f_svg/src/SvgTextRenderer.cj:925-942`（键构造在 `:926`）
- **来源**：存量
- **判据**：review-checklist §11（缓存键与取值来源不匹配）
- **证据**：静态确定（键内容）＋待确认（是否真的命中不同面）——键为 `family|weight|style|fontSize|codePoint`，而字形来自 `registry.resolveDetailed(..., stretch: char.stretch)` 返回的具体 `font`；同一 `family/weight/style` 下不同 `stretch` 会解析到不同面
- **描述**：`<text font-stretch="normal">A<tspan font-stretch="condensed">A</tspan></text>` 在同一 text 内会让第二个 `A` 复用第一个面的轮廓，再被 `applyFontStretchSynthesis`（`:1946-1968`）二次缩放，宽度与形状都对不上；默认字体注册表只有单一面时观察不到
- **建议**：键里加上 `char.matchedStretch`（或 `font` 的稳定标识）；补一条多 `font-stretch` 面的用例

### [轻微][存量] 布局缓存键只含样式树 `version`，不含样式树身份

- **位置**：`f_svg/src/SvgTextRenderer.cj:320-347`（键构造 `:326`）
- **来源**：存量
- **判据**：review-checklist §11（缓存键不足导致的错误命中）
- **证据**：待确认 —— `SvgTextLayoutCache` 由 `SvgDisplayList` 持有并被多次 `SvgGeometry.renderBounds/renderClipBounds` 复用（`SvgGeometry.cj:125`、`:150`）；键 `text.identity|styleTree.version|rootIdentity` 在「同一文本元素、换了一棵样式树但 `version` 相同（新树从 0 开始）」时会命中旧条目。仓内当前调用点都是「一次渲染一棵树」，故未观察到实际错配
- **描述**：键缺少样式树对象身份，属于潜在的跨树误命中面；一旦上游改成「复用 cache + 重建样式树」，排版结果会静默错误
- **建议**：键里加入样式树的对象标识（或 `SvgComputedStyleTree` 全局自增 id），与 `text.identity` 同源生成

### [轻微][存量] 竖排 `direction: rtl` 时列的 `x` 被重排，显式 `x` 不再按绝对坐标生效

- **位置**：`f_svg/src/SvgTextRenderer.cj:617-635`（`visualIndex` / `columnPositions.add(sortedColumns[visualIndex])`）
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/文档不符）
- **证据**：待确认 —— 代码不用字符自身的 `xOverride`（`key`），而用 `sortedColumns[visualIndex]`；`rtlColumns` 时 `visualIndex = size-1-rank`，于是 `x=20` 的字符被放到 `x=10`。`SvgTextWritingModeM4_test.cj:62-79` 只覆盖默认 `ltr`
- **描述**：若「显式 `x` 是绝对坐标」是契约，则 rtl 竖排会把两列的 x 互换；若「`x` 表示列序」是有意设计，则与 `columnPositions` 命名及 LTR 行为不一致。缺少规格与用例，无法定论
- **建议**：二选一并写进注释：绝对坐标 → 用 `key`；列序 → 明确「rtl 时 `x` 只用于确定列序」，并补两条方向的断言

### [轻微][存量] 只改类型名的重复实现（`permuteBidi*` ×3、`max*` ×2）

- **位置**：`f_svg/src/SvgTextRenderer.cj:1715-1746`（`permuteBidiValues<T>` / `permuteBidiOptionalPaths` / `permuteBidiFonts` 函数体逐行相同，只有 `ArrayList<T>` 元素类型不同）；`f_svg/src/SvgTimeline.cj:921-923`（`maxAnimationNumberSize`）与 `:1213-1215`（`maxFloat`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复逻辑）
- **证据**：静态确定 —— 三个 `permute` 的输入-输出-副作用完全一致：按 `order` 重建 `ArrayList`；泛型版本 `permuteBidiValues<T>` 已可承载 `?SvgPathData` 与 `Option<SvgFont>`
- **描述**：`:505`/`:508` 完全可以调用泛型版本，两处特化只增加维护面（改一处漏两处）；两个 `max` 同理
- **建议**：删除 `permuteBidiOptionalPaths`/`permuteBidiFonts`，改调 `permuteBidiValues`；`max*` 合并为一个泛型/一个具体类型（等价性由现有 `SvgTextBidi*_test` 与动画测试保证）

### [轻微][存量] 「均匀 keyTimes」同一段算法写了三遍

- **位置**：`f_svg/src/SvgTimeline.cj:947-951`（`effectiveKeyTimes`）、`:976-981`（`pacedKeyTimes` 的 `total <= 0` 回退）、`:1125-1129`（`resolveMotionProgress` 的 `keyPoints` 均匀分布）
- **来源**：存量
- **判据**：review-checklist §2（换控制流/复制同一换算）
- **证据**：静态确定 —— 三处都是 `times[i] = Float64(i) / Float64(count - 1)`，仅容器不同
- **描述**：三份实现都隐含 `count > 1` 的前提，靠调用点各自保证；任一处被改动（例如改成 `count-1 == 0` 的保护）都会漂移
- **建议**：抽 `private func uniformSvgTimes(count: Int64): Array<Float64>`（内部处理 `count <= 1`），三处替换

## 优化可行性方案

> 以下均非缺陷；无改前基线的只能作为下一轮补数据的对象。

### [堆内存] `sample()` 每帧深拷贝整棵文档

- **现状**：每次 `sample(time)` 调 `cloneSvgDocument`（`SvgTimeline.cj:212`、`:1261-1307`）复制全部元素、属性、文本节点与 prolog/epilog；60 fps 下每秒 60 份完整文档副本，单帧存活期 = 一次渲染
- **方案**：① 允许调用方传入可复用的目标文档/对象池（`sampleInto(target)`），只重置被动画写过的属性；② 或按「动画覆盖集合」做写时复制：只深拷贝 `specs` 涉及的子树 + 祖先链
- **预期**：单帧分配量从 O(文档节点数) 降到 O(被动画元素数 + 祖先链)，节点数 1 万、动画 10 个的文档可降两个数量级（需实测确认）
- **代价**：`sample` 的「返回独立文档」契约需要保留旧入口；写时复制要维护共享子树与 `parent` 指针的正确性（本模块已有 `cloneSvgElement`，改动面集中在 `SvgTimeline`）
- **验证**：`getAllocatedHeapSize()` 差值 / RSS + 每帧耗时中位数（`-O2`，同文档、同 300 帧序列，取 P50/P95）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `sample()` 每帧 O(n²) 排序 + 每个动画重新扁平化路径

- **现状**：`sortedAnimationSpecsByBegin`（`SvgTimeline.cj:1193-1211`）是 O(n²) 选择排序并每次新建 `Array<Bool>` + `ArrayList`，每帧调用一次（`:213`）；`sampleMotion`（`:1145-1184`）每个动画每帧 `flattenPathData(path, …, 0.1)` 全量重算折线
- **方案**：① `init` 里排一次序并缓存（`begin` 只在显式 `begin()/fireEvent` 时才变，可失效重建）；② 把扁平化后的折线按 `spec` 缓存（路径与容差不变即可复用），`sampleMotion` 只在折线上做线性推进
- **预期**：排序从每帧 O(n²) 降为一次 O(n log n)；路径扁平化从每帧 O(段数 × 1/容差) 降为一次（需实测确认占比）
- **代价**：需要失效逻辑（`begin` 触发后重建排序；路径缓存随 `AnimateMotion` 规格生命周期）
- **验证**：`cjprof record` 跑 300 帧、10/100/1000 个动画三档，比较 `sample` 自耗时与帧 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 竖排分列用线性查找 + 选择排序，整体 O(n·k + k²)

- **现状**：`logicalColumns` 去重（`SvgTextRenderer.cj:595-600`，`containsTextColumn` 线性扫描）、列排序（`:601-615` 选择排序）、每字符 `textColumnIndex`（`:620`，再次线性扫描）；n = 字形数，k = 不同 `x` 列数
- **方案**：用 `HashMap<Float64, Int64>` 一次遍历完成去重与「列 → 序号」映射，列序直接 `Array.sort()`；`textColumnIndex` 改为查表
- **预期**：k≈n 时从 O(n²) 降到 O(n log n)；单段竖排文本 5000 字、5000 列的场景比较 layout 耗时中位数
- **代价**：`Float64` 作 `HashMap` 键需与现有 `==` 语义一致（当前就是精确相等比较，语义不变）
- **验证**：`cjpm bench -O2`，输入 100/1000/5000 字三档，对比 layout 中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sample()` 的整树克隆是动画播放的主开销 | `f_svg/src/SvgTimeline.cj:212` | 克隆占总耗时比例、每帧分配字节数 | `cjprof record`，300 帧、文档节点数 1k/10k |
| 2 | 竖排多列文本的 O(n²) 列处理在长文本上可观测 | `f_svg/src/SvgTextRenderer.cj:595-635` | 不同 n 下的 layout 耗时曲线与自耗时占比 | 构造 n 列竖排文本，`cjpm bench -O2` 分 100/1000/5000 字三档 |
| 3 | `layout` 内大量逐元素 `ArrayList`（`advances/paths/baselineOffsets/ascentValues/resolvedFonts`）适合 local mode | `f_svg/src/SvgTextRenderer.cj:409-492` | 峰值内存与 local region 容量 | 开 `--experimental --enable-local-mode` 前后对照峰值 `getUsedHeapSize()`/RSS；先按 `mem §1` 排除长期引用 |
| 4 | 字形缓存（按 renderer 实例）在同文本重复字符上命中率足够 | `f_svg/src/SvgTextRenderer.cj:301` | 命中率与单次 miss 代价 | 加计数埋点，跑含重复字符的典型文档 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_svg/src/SvgTextRenderer.cj` | .cj | ✅ | 见发现 #3/#4/#5/#7/#9/#10/#11/#12；2053 行全读 |
| 2 | `f_svg/src/SvgTextRenderer_test.cj` | .cj | ✅ | 布局/定位/tspan/降级/光栅化用例，未见断言空缺 |
| 3 | `f_svg/src/SvgTextToleranceM6_test.cj` | .cj | ✅ | 容差与 `optimizeSpeed` 关连字用例，与实现一致 |
| 4 | `f_svg/src/SvgTextWritingMode.cj` | .cj | ✅ | 枚举 + `fromName`/`fromNameOrWarn`；后者仅测试引用（见 §1 说明） |
| 5 | `f_svg/src/SvgTextWritingModeM4_test.cj` | .cj | ✅ | 只覆盖 ltr 与单列 rtl（见发现 #11 的覆盖缺口） |
| 6 | `f_svg/src/SvgTimeline.cj` | .cj | ✅ | 见发现 #1/#2/#5/#6/#8/#13；1376 行全读 |
| 7 | `f_svg/src/SvgTransform.cj` | .cj | ✅ | 解析/序列化边界核对，未发现缺陷；`isNumberStart` 仓内唯一外部引用在 `SvgTransform.cj:201` |
| 8 | `f_svg/src/SvgTransformBox.cj` | .cj | ✅ | 枚举解析与回退，公开 API 无缺陷 |
| 9 | `f_svg/src/SvgTransformBoxM5_test.cj` | .cj | ✅ | 解析与样式回退用例齐全 |
| 10 | `f_svg/src/SvgTransformOrigin.cj` | .cj | ✅ | 见发现 #3（`resolveOriginComponent` 单位换算） |
| 11 | `f_svg/src/SvgTransformOriginM5_test.cj` | .cj | ✅ | 原点矩阵用例；未覆盖 `em/ex` 单位（对应发现 #3） |
| 12 | `f_svg/src/SvgTransformOriginRenderM5_test.cj` | .cj | ✅ | 渲染/CTM/包围盒接通用例，与实现一致 |

合计：`.cj` 12 个 / `.md` 0 个 / 共 12 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | #1（状态泄漏）、#2（时长语义）、#4（`x`+`dx`）、#7（textPath 嵌套）；本部分无 XML 反序列化入口，注入/转义不在本轮范围（`setAttr` 转义由序列化层负责） |
| §1 死代码 | 1 | #8 `SvgAnimationSpec.target`；逐一对本部分 `private`/`internal` 符号做全仓/包内搜索：`parseTransformArgs`、`buildOperation`、`expectArgCount`、`resolveOriginComponent`、`normalizeCssTransformOrigin`（被 `SvgStyleResolver.cj:803` 引用）、`effectiveElementTransform`（`SvgClipMask`/`SvgElementApi`）、`splitSvgSemicolon`（`SvgAnimation.cj:119`）、`resolveTextRotations`（测试）、Timeline 全部私有函数、TextRenderer 全部私有函数均有调用者；`SvgWritingMode.fromNameOrWarn` 仅测试引用 → 按 §1 只记可见性提示，不算死代码；对外可达 `public`（`SvgTimeline`/`SvgTextRenderer`/`SvgTextLayout`/`SvgTextGlyph`/`SvgTransform*`）不判 |
| §2 重复逻辑 | 3 | #3（单位换算 4 处）、#12（`permute`×3、`max`×2）、#13（均匀 keyTimes×3）；另两两比对本部分 40+ 函数体：`addAnimationNumberLists` 与 `accumulateAnimationValue` 语义不同（相加 vs 累加差值），`charFontAscent`/`charFontDescent` 仅两行且分支不同，均不构成重复 |
| §3 空实现 | 0 | 逐个函数体核对：无空体、无 `TODO`/`FIXME`、无 `catch {}`；`case None => ()` 均为可选属性缺省回退（如 `:116`、`:426`、`:529`），有明确降级语义 |
| §4 栈溢出 | 1 | #6 `resolveAnimationTime` 递归深度无上限；`cloneSvgElement`/`collectAnimationSpecs`/`cloneSvgNode` 的递归深度受解析期 `maxDepth`（`SvgBuilder.cj:127`，默认 512）约束，不计；`resolveMotionPath` 已有 64 层上限 |
| §5 OOM | 1 | #5 warning 无界累积（`SvgTimeline.warnings` 随帧增长）；`values` 已有 10000 条上限（`:493`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile/bench 数据，热点结论不成立，已列入待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无 `synchronized`/`Mutex`/锁内 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无线程池、无任务提交 |
| §6.4 低效算法 | 2 | 两处 O(n²)（`sortedAnimationSpecsByBegin`、竖排列处理）复杂度静态可判，但缺耗时占比数据，按铁律归入「优化可行性方案（无基线）」而不是缺陷 |
| §7 降堆内存方案 | 1 | 方案「`sample()` 每帧深拷贝」；warnings 的容量问题已在 #5 按缺陷处理，不重复计入 |
| §8 降 CPU 方案 | 2 | 方案「排序 + 路径扁平化缓存」「竖排列处理降复杂度」，均标 `无基线` |
| §9 local mode 可行性 | 0 | `layout` 内临时 `ArrayList` 满足「函数内创建、函数内用完」，但收益必须以峰值内存前后对照证明，暂无数据 → 待验证假设 #3。约束：实验特性、需 `--enable-local-mode`、local region 共享 `cjLocalRegionMaxSize` |
| §11 现有代码的 BUG（存量） | 6 | #1/#2/#3/#4/#7/#9；本部分读到的 60+ 函数边界（空列表、`count-1` 除零、`frames.size==1`、`placed.size` 截断、`parseSvgTimeValue` 的 `None`）均已逐一核对，除上述外无缺陷 |
| §12 并发安全与锁粒度 | 0 | 本部分无可证的多线程共享路径：`SvgTextRenderer`/`SvgTimeline` 均为单次渲染内实例，无可变全局；但 `SvgTimeline.sample` 修改 `this.warnings` 与源文档（#1），使同一实例不可重入/不可并发调用，视为 #1 的次要后果 |
| §14 功能完备性与 README 覆盖 | 1 | #7（textPath 嵌套未接线）；本部分无 `.md`，模块 README 的公开 API 覆盖由含 README 的部分核对 |
| 文件覆盖（§13 等） | 12/12 | 无缺失；本部分无 `.md`，§13 文档一致性不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分代码整体质量偏高：文本排版（`x/y/dx/dy`、`textLength`、竖排分列、bidi 重排、GSUB 连字/上下文整形、装饰线）的分支都有明确降级路径与 warning，`SvgTransform.parse` 的错误消息与边界（多余逗号、参数个数、非有限值）覆盖完整，`SvgTransformOrigin` 的 `0 0 + view-box` 短路也保住了历史输出的逐字节稳定。

阻塞项只有一个：`SvgTimeline.sample()` 在「无 href 的嵌套 `discard`」路径上改写调用方文档（#1），既违反类注释的契约，也让时间轴跨帧不可回放，应优先修。其次是时间语义类问题（#2 `repeatDur` 被覆盖、#4 `x`+`dx` 丢偏移）与一组「同一套换算/缓存键」漂移（#3、#9、#10），它们不会崩溃但会让渲染结果与规范/其它属性口径不一致，建议排期。warning 无界累积（#5）与递归无上限（#6）属于长跑与极端输入下的稳定性问题，成本低、收益明确，可一并处理。

性能侧的两处 O(n²)（每帧排序、竖排列处理）与每帧整树克隆都是结构性开销，但当前没有任何 profile/bench 数据，按铁律只进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。

存量缺陷 13 条（严重 1 / 一般 6 / 轻微 6），是否纳入修复待用户决定。

范围外提示：`SvgAnimation.cj:106-133` 的 `parseSvgTimeReference`/`isSvgEventTime` 只识别整串 `.begin`/`.end`，不支持 `a.end+2s` 偏移与 `0; click` 混合列表，`SvgTimeline` 的 `begin`/`end` 语义因此受限（该文件不在本部分清单内，未展开）。
