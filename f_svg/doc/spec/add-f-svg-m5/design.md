# Design — add-f-svg-m5

## Context

`f_svg` 是单包仓颉模块（`f_svg/src` 190 个源文件，含测试），M1–M4 已形成固定管线：`CssStyleSheet.parse` → `SvgStyleResolver.compute` → `SvgRenderTreeBuilder.build` → `SvgDisplayList` → `SvgRenderer.renderDisplayList` → `SvgBitmap`。当前基线为 710 条用例全绿、17 张渲染快照（M1–M3 13 张、M4 4 张）。

与本变更直接相关的现状：

- 选择器模型是「复合部分 + 组合符」：`CssSelectorPart` 只含 `typeName` / `id` / `classes` / `combinator`（`CssSelector.cj:43`），解析器遇到 `:` / `[` 直接抛错，`CssStyleSheet.parse` 对 at-rule 整段跳过（`CssStyleSheet.cj:108` 起），因此 `@media` / `@font-face` / 伪类 / 属性选择器 / 兄弟组合器目前全部不可用。
- 级联按 `(important, origin, specificity, order)` 逐属性取胜出值，核心在 `SvgStyleResolver.cascade` 与 `normalizeValue`（`SvgStyleResolver.cj:356`）；属性元数据表在 `SvgComputedStyle.cj:76`，表外属性不进入计算样式。
- `SvgElement` 只有私有的兄弟序号计算（`SvgElement.cj:421`），没有元素兄弟遍历 API；结构伪类需要新增内部辅助。
- 渲染顺序固定为「填充 → 描边 → marker」（`SvgRenderTree.cj:719` 的 `addShape` 与 `:810` 的 `addMarkers`）；容器只有在 `opacity < 1` / 滤镜 / 裁剪时才建组（`SvgRenderTree.cj:490` 附近），合成统一走 `SvgGroupCompositor.composite`（`SvgClipMask.cj:149`），只支持整层 `source-over`。
- 文本布局按码点逐个取 `advance` 与 `glyphPath`（`SvgTextRenderer.cj:227`），`SvgFont` 接口只有 5 个码点级方法（`SvgFont.cj:26`）；`SvgTrueTypeFont` 已能读 `cmap` / `glyf` / `hmtx` / `head` / `hhea` / `maxp` / `loca`，但没有 `kern` / `GPOS` / `GSUB`。
- `SvgBlendMode` 目前只有 5 个取值，服务于 `feBlend`；直接扩展会破坏下游穷尽 `match`。
- 既有元素级 API 只有 `SvgGeometry.ctm` / `screenCTM`（`SvgGeometry.cj:179` / `:225`）与 `SvgPathData.totalLength` / `pointAtLength`（`SvgPathData.cj:308` / `:313`），没有挂到 `SvgElement` / `SvgPath` 上。

约束：不新增模块、子包或依赖；不改 M1–M4 公开方法签名与字段语义；未使用新特性的文档输出与 M4 逐字节一致；`f_svg` 自身 0 warning；全部改动按 TDD 推进。

已核对的契约冲突：`CssStyleSheet_test.atRulesAreSkipped` 与 `unsupportedSelectorsAreSkipped` 直接断言 M2「`@media` / `@font-face` / 属性选择器一律跳过」，与 M5 的 MODIFIED 要求互斥。M5 按新契约改写这两条用例，其余 708 条保持不变；设计文档中的「710 条零回归」按此口径执行。

## Goals / Non-Goals

**Goals:**

- P1 在既有词法 / 级联 / 属性表上增量扩展，选择器引擎同时服务样式匹配与 `querySelectorAll`。
- P2 在不改变默认渲染路径的前提下，为 `paint-order`、混合 / 隔离、`feDropShadow`、`transform-origin`、`context-*` 提供确定性实现。
- P3 把文本管线从「逐码点」升级为「双向分段 → 整形 → 定位」，但 `SvgFont` 接口零改动。
- P4 元素级 API 只做薄封装，复用既有几何与查询实现，不引入跨调用状态。

**Non-Goals:**

- 不实现设计文档「M5 明确不做」列出的能力（CSS 动画 / 过渡、伪元素、复杂脚本整形、上下文替换、`plus-lighter`、GPU 后端等）。
- 不做浏览器逐像素对齐；只保证本变更 spec 与自有快照。
- 不为新特性改变既有默认值、级联顺序或效果顺序。

## Decisions

### D1 选择器模型：保留旧字段，新增复合视图

`CssSelectorPart` 增加 `simples: Array<CssSimpleSelectorKind>`，同时继续填充既有 `typeName` / `id` / `classes`（取复合选择器中的首个类型、首个 id、全部类名）。`CssSimpleSelectorKind` 与 `CssAttributeSelector` / `CssPseudoClass` 按设计文档 §2.1 定义。

理由：既有 spec 把 `typeName` / `id` / `classes` 作为公开契约，直接替换会破坏 M1–M4 调用方；复合视图让新匹配器与旧字段并存。备选「新增 `CssSelector2` 平行类型」被否决：会导致两套选择器与两套 `matches`，`querySelectorAll` 与样式匹配容易分叉。

解析器从「遇到 `:` / `[` 抛错」改为状态机：类型 / `*` → 循环消费 `#id`、`.class`、`[attr op value i]`、`:pseudo(...)`，组合符识别 `>`、`+`、`~` 与空白。简单选择器计数超过 256 时整条规则跳过并 warning（D12）。

匹配仍是「最右部分起、向左回溯」；新增 `AdjacentSibling` / `GeneralSibling` 两个分支。兄弟判定复用新增的内部 `elementSiblingIndex` / `previousElementSibling`，只统计 `ElementNode`。`:root` 用 `parent == None`；`:empty` 把全空白文本视为空。

特异性按设计文档 §2.1：id +100、类 / 属性 +10、类型 / 伪类 +1，`*` 不计。`:not()` 按伪类自身计 1 次，参数不另计，与设计文档的伪类计数口径一致。

### D2 @media：规则携带条件，求值推迟到级联

`CssRule` 增加 `media: ?CssMediaQuery`（内部构造，公开字段只读）。`CssStyleSheet.parse` 遇到 `@media` 时解析 query-list，递归解析块内规则并把条件挂到每条规则上，仍写入同一个 `rules` 数组，`order` 按展开后的源顺序递增；`@font-face` 解析为独立的 `CssFontFaceRule` 列表，不进入 `rules`。

理由：级联依赖全局源顺序，若把媒体规则放进单独列表，合并时要重新排序，容易破坏 `order` 语义。备选「解析期直接按固定宽度过滤」被否决：同一 `CssStyleSheet` 可能被不同视口复用。

`SvgStyleResolver` 新增 `compute(root, mediaWidth!: Float64)` 重载与 `computeElement(element, parent, mediaWidth!: Float64)` 重载，原 `compute(root)` / `computeElement(element, parent)` 保留并等价于传入 300；媒体过滤发生在 `considerSheet` 阶段，`prepare` 仍只做一次规则收集。渲染树构建器在样式计算前先算逻辑宽度（`SvgViewport.from` + `SvgRenderOptions.width`），再传给解析器；`render(element, w, h)` 直接传 `w`。这样 `@media` 不进入 `normalizeValue`，也不影响无媒体规则文档。

### D3 CSS 变量与 calc()：展开在归一化之前

自定义属性不进入 `SVG_PROPERTY_TABLE`，而是作为独立的继承值集合保存在 `SvgComputedStyle` 的 values 中（键保留原始大小写）。级联阶段先算出本元素的 `--*` 映射（继承父映射后覆盖），再对每个普通属性的胜出值做 `var()` 展开，最后交给 `normalizeValue`。

`var()` 展开器用「深度 + 访问栈」检测循环；深度上限 8。fallback 在找不到变量时递归展开。展开结果保留原单位文本，交给既有 `normalizeValue` 处理，因此 `fill: var(--c)` 仍走画笔解析，`stroke-width: var(--w)` 仍走长度解析。

`calc()` 用递归下降解析为受限值：`Number` 或 `SvgLength`。只允许 `+` / `-` / `*` / `/` 与括号，`*` / `/` 的一侧必须是数字；`em` 按当前计算字号转 `px`；同单位族才能合并，百分比与绝对长度混用视为无效。结果字符串再进入既有长度归一化。备选「在渲染期保留表达式」需要改动所有长度消费点，成本高且会破坏 `SvgLength` 契约。

`normalizeValue` 增加 `calc(` 入口与 `var(` 前置展开；解析失败沿用既有「回退父值或初始值 + warning」路径。

### D4 @font-face：派生注册表，不修改调用方输入

`@font-face` 解析为 `CssFontFaceRule(family, weight, style, srcPresent)`。渲染树构建器收集样式表中的字体别名，构造一次性的派生注册表：`SvgFontRegistry.derived(base, aliases)` 返回新实例，内部先按别名把 family 映射到目标 family，再委托 base 的 `resolve`；base 不被写入。

派生注册表随 `SvgDisplayList` 传给渲染器与文本布局（内部字段），保证构建期几何计算与渲染期文本使用同一套字体。独立调用 `SvgGeometry.bounds` 的用户不经过样式表，仍使用传入 / 默认注册表，这是可接受边界。

备选「直接调用 `register(alias, font)` 写入调用方注册表」被否决：会污染跨渲染状态并破坏确定性；备选「文本渲染器内部维护别名」会让 `getBBox(text)` 与渲染字体不一致。

`src` 只产生一条 warning，不读取文件、不联网，符合既有安全边界。

### D5 混合模式：新枚举 + 合成器重载，不扩展 SvgBlendMode

新增 `SvgMixBlendMode`（12 值）；`SvgBlendMode` 保持 5 值，避免现有 `feBlend` 用户与内部穷尽 `match` 失效。

`SvgGroupCompositor` 增加 `composite(destination, layer, opacity, mode!)` 重载，原三参数版本委托新版本并传 `Normal`，既有调用与输出不变。混合函数放在 `SvgBlend.cj`，输入预乘 `SvgRgba`，按 D5 公式还原非预乘颜色、求混合色、再预乘并钳制。

渲染树需要为元素携带 `mixBlendMode` 与 `isolation`：`SvgDisplayCommand` 增加 `blendMode: SvgMixBlendMode = Normal` 与 `isolated: Bool = false`（内部构造，默认值保持既有构造调用可用）。单元素在 `needsLayer` 判定中追加「混合非 normal」；容器在 `grouped` 判定中追加「混合非 normal 或 isolation isolate」。`GroupEnd` 时把命令上的混合模式传给合成器。

注意：隔离组必须真正离屏，否则子元素会读到父层像素；因此 `isolation: isolate` 即使没有透明度 / 滤镜也要建组，这会改变该文档的命令流，但只在显式声明时发生。

### D6 paint-order：按元素缓冲命令后重排

`addShape` 当前直接向全局 `commands` 追加填充、描边、marker。改为：先向本元素的临时 `ArrayList` 追加三类命令（marker 仍由 `addMarkers` 派生，派生逻辑与顺序不变），再按 `paint-order` 的层序把临时列表拼接到 `commands`。缺省层序与实际追加顺序完全一致，保证默认输出逐字节不变。

`addMarkers` 增加一个「输出列表」参数（或在调用处先收集），不改变 marker 的派生、朝向、上限与 warning。`paint-order` 非法时按默认层序，warning 在样式层已产生，渲染树不重复记。

### D7 feDropShadow：模型 + 复用原语

新增 `SvgFeDropShadow <: SvgFilterPrimitive`，字段 `dx` / `dy` 为 `?SvgLength`（缺省 2），`stdDeviation` 复用 `SvgNumberList`（缺省 2），`floodColor` / `floodOpacity` 按既有颜色与透明度解析。`SvgTag.create` / `isKnown` 注册标签；`SvgFilterRenderer` 在 `apply` 的分派里新增分支，实现顺序为：输入 alpha → 既有高斯模糊 → 偏移 → 既有 flood 着色 → 与原图合并。滤镜区域在既有 `region` 结果上按 `|dx| + 3σ`、`|dy| + 3σ` 外扩，并受 `filterUnits` 约束。

理由：设计文档明确要求不新增像素算法；复用 M3/M4 的模糊、flood、merge 可保证与既有滤镜一致的边界与确定性。备选「在解析期展开成四个原语」会改变 `primitives` 数量与往返结构，不可取。

### D8 transform-origin / transform-box：统一有效变换入口

新增内部函数 `effectiveElementTransform(element, style!, bounds!, viewportWidth!, viewportHeight!)`：先取 `transform.toMatrix()`，再按 `transform-box` 选参考盒（`view-box` 用最近视口宽高，`fill-box` 用元素几何包围盒），解析原点后返回 `T(origin) × M × T(-origin)`。当 `transform-origin` 为 `0 0` 且 `transform-box` 为 `view-box` 时直接返回原矩阵，避免额外乘法与浮点差异。

渲染树、`SvgClipMask` 的 `elementTransformMatrix`、`SvgGeometry.ctm` / `absoluteBounds` 统一走该入口；后两者需要样式上下文，因此增加可选参数 `styles!: ?SvgComputedStyleTree = None`，缺省时只按呈现属性解析原点（保持 M4 行为）。`SvgElement.getCTM` / `getScreenCTM` 先在元素所属根上计算一次样式树，再调用带样式的重载。

`fill-box` 需要元素包围盒；只有 `transform-box == FillBox` 或原点含百分比 / 关键字时才计算，避免给默认路径增加 `bounds` 开销。百分比相对参考盒宽高，关键字映射按 spec。

### D9 context-fill / context-stroke：use 实例帧

`SvgPaintKind` 增加 `ContextFill` / `ContextStroke`，`SvgPaint.parse` 识别两个字面量。`currentColor` 与 `context-*` 的替换时机不同：`currentColor` 在级联归一化时替换，`context-*` 必须保留到渲染树展开 `use` 之后再解析。

`expandUse` 在进入被引用子树前压入一个上下文帧，保存被引用元素的计算 `fill` / `stroke`；解析画笔时若遇到 `ContextFill` / `ContextStroke`，取最近帧的对应画笔；无帧或帧内画笔仍是 `context-*` 时回退 `None` 并 warning。帧随 `use` 递归出栈，天然处理嵌套 `use` 与循环深度。

备选「用 `SvgPaint.Reference` 加保留 id」会污染引用解析与安全校验，不采用。

### D10 文本整形：旁路接口，不改 SvgFont

新增 `SvgShapingFont` 接口（`shape(glyphIds: Array<Int64>, fontSize, features): SvgShapedRun`），`SvgTrueTypeFont` 实现它；`SvgFont` 保持 5 个方法不变，第三方字体实现零改动。布局时用类型判断决定是否走整形路径；非整形字体仍走原逐码点路径，输出不变。

`SvgShapedRun` 含字形 id 序列、每个字形的 advance、集群映射与可选连字来源。`SvgTrueTypeFont` 内部新增 `glyphId(codePoint)` 与 `glyphPathById(gid, fontSize)`（内部可见），供整形路径使用；`advance(codePoint)` / `glyphPath(codePoint)` 的公开语义不变。

管线顺序：按 bidi 层级切 run → 字符到字形（cmap）→ GSUB `liga` → GPOS / `kern` → 得到 `SvgShapedRun` → 交给定位器。`font-kerning` 只控制第二段是否执行字距；`liga` 不受 `font-kerning` 影响。

表读取复用 `SvgTtfTableReader` 的边界检查；`kern` format 0、GPOS PairPos format 1/2、GSUB LigatureSubst format 1 各自实现为独立读取器，超限按 D12 降级。

### D11 双向文本：UAX#9 子集 + 显式嵌入栈

`SvgBidi.cj` 提供：字符方向类别表（手写区间表，覆盖设计文档 8 类）、段落层级求解、显式嵌入栈（`embed` / `bidi-override`，深度上限沿用 64 的既有渲染守卫口径或在模块内设 16 并 warning）、弱类型 W1–W7 子集、中性 N1–N2、隐式 I1–I2、L2 视觉重排。数字与中性规则按 spec 场景；成对括号做单层镜像表（`(`↔`)`、`[`↔`]`、`{`↔`}`、`<`↔`>`）。

重排在整形之前按字符层级切 run，整形在每个 run 内完成，最后按视觉顺序拼接。`x` / `y` / `dx` / `dy` / `rotate` 列表在逻辑字符上绑定，重排只移动字形；连字簇消费首个字符的列表项。`textPath` 与 bidi 同时存在时，按视觉顺序逐字取弧长落位，切线角仍按路径。

`unicode-bidi: bidi-override` 跳过弱 / 中性解析，直接按段落方向赋层级；`direction` 与 `writing-mode: tb-*` 组合时只决定列顺序。

### D12 上限与降级：警告而非硬失败

按设计文档 §7 建表：变量 8 层、`calc()` 16 层、选择器 256 个简单选择器、`kern` 65536 条、GPOS pair 65536 条、GSUB 深度 8、连字输入 4 个。全部在进入循环或分配大缓冲前检查，超限走 warning + 跳过 / 忽略，不抛 `Limit`（与 M4 的硬失败表区分）。

理由：这些上限属于「单个特性不可用」，不应让整篇文档渲染失败；而 M4 的滤镜 / TTF 上限是内存安全边界，继续硬失败。

### D13 元素级 API：按根计算样式，不缓存跨调用

`getBBox` / `getCTM` / `getScreenCTM` 需要计算样式与字体。实现为：从元素向上找根（`parent` 链），在根上调用 `SvgStyleResolver().compute(root)`，取本元素快照；元素无根（未挂载）时 `getCTM` 返回 identity，`getBBox` 仍可用呈现属性与默认字体计算。叶子元素直接复用 `SvgGeometry.bounds` / `strokeBounds`；容器按文档顺序并集后代包围盒并乘子元素有效变换；`use` 解析 `href` 后把目标包围盒平移 `x` / `y`；`image` 取矩形；定义型元素返回 `None`。`SvgBBoxOptions.clipped` 只与有效视口裁剪矩形求交（根视口、嵌套 `svg`、`viewport` 类元素），不处理 `clip-path` / `mask`，避免为查询引入光栅化。

`getScreenCTM(viewport: None)` 用 `SvgViewport.from(root, 300, 150)` 与 `devicePixelRatio = 1` 构造；调用方可传入显式 `SvgViewportTransform` 覆盖。

`getElementsByClassName` / `querySelectorAll` 只遍历后代，按文档顺序收集；`querySelectorAll` 直接复用 `CssSelector.parse` + `matches`，非法选择器抛 `InvalidValue`（与 CSS 解析一致），避免静默返回错误集合。返回新 `ArrayList`，不缓存、不修改文档。

`SvgPath.getTotalLength` / `getPointAtLength` 只做空值保护后转调 `SvgPathData`，不复制弧长算法。

### D14 文件与改动映射

按设计文档 §6 建 11 个新文件；`CssSelector2.cj` 承担扩展解析与匹配辅助，`CssMedia.cj` / `CssVariables.cj` / `CssCalc.cj` 只被样式解析层引用，`SvgBlend.cj` / `SvgPaintOrder.cj` / `SvgTransformOrigin.cj` / `SvgContextPaint.cj` 只被渲染层引用，`SvgOpenTypeLayout.cj` / `SvgBidi.cj` 只被文本层引用。

`SvgElementApi.cj` 只放内部辅助（包围盒并集、查询遍历、视口裁剪求交），公开方法声明写在 `SvgElement.cj` / `SvgPath.cj` 的类体内，避免依赖扩展（`extend`）对私有状态的可见性；`SvgElement.cj` / `SvgPath.cj` 只增加方法，不改既有签名。既有文件其余部分只做最小接线：注册属性、分派标签、调用新模块。

## Risks / Trade-offs

- **字节一致性被默认路径破坏** → 所有新行为用「属性缺省值 / 空表 / 无别名」短路；M1–M4 快照加入逐字节回归；新增 `m5-*` 快照单独管理。
- **两条 M2 用例与新契约冲突** → 仅改写 `atRulesAreSkipped` 与 `unsupportedSelectorsAreSkipped`，并在任务与验收中显式列出；其余 708 条保持原样，避免把契约变更伪装成零回归。
- **`@media` 与样式缓存** → 解析结果不因宽度变化；缓存键仍是样式文本，媒体求值发生在每次 `compute`，避免跨视口复用错误结果。
- **`SvgPaintKind` / `CssCombinator` 扩展导致下游穷尽匹配失败** → 在 README / CHANGELOG 标注为「新增构造器」；f_svg 内部所有 `match` 同步补分支；备选方案不成立（引用哨兵会污染安全语义，另立组合符类型会让同一选择器模型分裂）。
- **`SvgBlendMode` 若被扩展会破坏 feBlend 用户** → 明确新建 `SvgMixBlendMode`，不碰旧枚举。
- **bidi / OpenType 复杂度高** → 只实现 spec 声明的子集；未覆盖字符按 L 处理；所有表读取有边界检查与上限；以「基础拉丁 / 希伯来 / 阿拉伯字母 + 数字」场景锁定行为。
- **`transform-origin` 使 `ctm` 与渲染不一致** → 统一走 `effectiveElementTransform`，`getCTM` 传样式树；缺省 `0 0` 时短路，M4 行为不变。
- **getBBox 每次重算样式树可能慢** → 只在显式调用时发生，不进入渲染热路径；`perf-baseline.md` 记录单次耗时，不做跨调用缓存。
- **混合模式的预乘 / 反预乘量化误差** → 在预乘浮点域完成混合，只在写回时量化一次；测试用不透明场景锁定精确值，半透明场景用容差。
- **`feDropShadow` 区域外扩导致大画布** → 外扩量受 `maxPixels` 与既有滤镜区域上限约束，先校验再分配。

## Migration Plan

1. 从当前工作基线切 `feature/f-svg-m5`，跑 `cjpm test` 确认 710 条全绿并记录耗时。
2. 按 P1 → P2 → P3 → P4 分组实现，每组先写失败用例、再实现、再重构，组末全绿后独立提交。
3. 每组结束跑一次 M1–M4 快照逐字节比对；新增 `m5-*` 快照只在对应组内生成并复核。
4. 全部完成后更新 README / `perf-baseline.md` / 包注释，跑 `cjpm test`、`cjpm build`（0 warning）与 `openspec validate --strict`。
5. 回滚策略：本变更无数据迁移；按提交组 revert 即可，快照文件随组提交，回滚后 M4 输出不受影响。

## Open Questions

无。设计文档未明确但影响实现的细节（`:not` 特异性、calc 单位混合、`clipped` 语义、非法选择器抛错、bidi 与列表交互）已在上文决策中定稿；若后续需要偏离，应另开变更修改 spec。
