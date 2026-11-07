# Design — add-f-svg-m6

## Context

`f_svg` 是单包仓颉模块（`f_svg/src` 288 个源文件，其中 163 个测试文件）。M1–M5 已形成固定管线：`CssStyleSheet.parse` → `SvgStyleResolver.compute` → `SvgRenderTreeBuilder.build` → `SvgDisplayList` → `SvgRenderer.renderDisplayList` → `SvgBitmap`。当前基线为 **997** 条用例（`@TestCase` 计数）全绿，M1–M5 共 25 张渲染快照。

与本变更直接相关的现状：

- 选择器伪类只有结构类与 `:not()`（`CssSelector2.cj:95`），`cssPseudoMatches(pseudo, element)` 没有交互状态参数（`CssSelector2.cj:763`），`:hover` / `:focus` 目前被解析器拒绝。
- 计算样式属性表在 `SvgComputedStyle.cj:76`，表外属性不进入级联；`pointer-events` / `shape-rendering` / `font-stretch` 等均不在表中。`cursor` 只出现在 `SvgBuilder.cj:319` 的外部 URL 属性白名单里。
- 没有命中测试实现；`SvgElement` 已有 `getBBox`（`SvgElement.cj:333`），`SvgBounds` 提供 `union` / `intersect`（`SvgBounds.cj:23`）。
- `foreignObject` 当前只 warning 后跳过（`SvgRenderTree.cj:534`）；`<image>` 的 provider 模式可直接复用（`SvgImageResource.cj:64`）。
- `use` 只解析同文档片段（`SvgRenderTree.cj:700`），外部 `href` 在解析期按安全策略移除（`SvgBuilder.cj:319` 附近的 URL 属性检查）。
- 渐变采样是逐像素解析式（`SvgGradient.cj:207` → `sampleStops` `:525`），没有有限“采样点”概念；`color-interpolation-filters` 已在滤镜中单独处理（`SvgFilterRenderer.cj:135`）。
- 文本布局按「GSUB liga → kern/GPOS → bidi」顺序（`SvgTextRenderer.cj:1550` 起），GSUB 只收集 `liga` 的 Type 4（`SvgOpenTypeLayout.cj:142`），无 `OS/2` 解析。
- `SvgTimeline.sample(time)` 在深拷贝上求值（`SvgTimeline.cj:188`），`begin` / `end` 在构造期一次性解析（`:529`），事件型时间被忽略并 warning。
- `SvgRasterizer` 的曲线容差固定为 0.25（`SvgRasterizer.cj:118`），描边 join 只有 miter / round / bevel（`SvgStrokeOutliner.cj:318`），`SvgLineJoin` 是公开枚举（`SvgShape.cj:63`）。
- `SvgElement` 只有 `appendChild`（`SvgElement.cj:208`），没有 `insertBefore` / `removeChild`，文档也没有变更通知入口。

约束：不新增模块、子包或依赖；不改 M1–M5 公开方法签名与字段语义；未使用 M6 特性的文档输出与 M5 逐字节一致；`f_svg` 自身 0 warning；全部改动按 TDD 推进。

已核对的契约冲突：

- 设计文档 §11 写「M1–M5 的 987 条用例」，该数字取自 M5 修复前的中间态；现行 `verification.md` §9.4 与仓库实际 `@TestCase` 计数均为 **997**。本变更以 997 为基线。
- `svg-security` 的既有场景「事件型动画被忽略并 warning」与 M6 的 `fireEvent` 互斥；该要求按 M6 改写，不视为回归。
- 设计文档把 `color-rendering` 描述为「渐变采样点减半 / 加倍」，但现有采样器是解析式、无采样点。M6 以「量化级数」实现该属性，`auto` 保持解析式。

## Goals / Non-Goals

**Goals:**

- 新增能力全部在既有管线内挂接，默认路径用「空集合 / `None` / `auto`」短路，保证字节一致。
- 交互状态、渲染提示、字体特性都从计算样式读取，避免为每个特性另建配置通道。
- 上限检查前置到进入递归或分配大缓冲之前，与 M4 / M5 的降级口径一致。

**Non-Goals:**

- 不实现设计文档 §「M6 明确不做」列出的能力。
- 不改变 M5 的 `sample(time)`、`getBBox`、`SvgFont` 接口与默认渲染顺序。
- 不为新增能力引入跨调用缓存；单次渲染内的缓存随显示列表生命周期结束。

## Decisions

### D1 交互状态：解析器字段 + 重载，不建平行选择器

新增 `SvgInteractionState`（`hoveredIds: Array<String>`、`focusedIds: Array<String>`，内部预计算 `focusedId: ?String` 与 `hoveredSet: HashMap<String, Bool>`）。`SvgStyleResolver` 增加 `compute(root, interaction!, mediaWidth!, mediaHeight!)` 与 `computeElement(..., interaction!)` 重载，原签名委托空状态；`CssSelector.matches(element, interaction!)` 同理，原 `matches(element)` 委托空状态。

`cssPseudoMatches` 增加可选 `interaction` 参数，`Hover` / `Focus` 分支读取预计算集合；`Not(inner)` 递归时透传同一状态。`:focus` 在构造状态时按 `focusedIds` 顺序调用 `elementById`，取第一个成功解析的 id，其余忽略。

理由：选择器索引 `CssSelectorIndex` 按 id / 类 / 类型索引选择器，不缓存匹配结果；把状态放在 resolver 字段可在 `cascade` 内任何深度读取，避免给 10 余个内部函数逐一加参数。备选「新增 `CssSelector2` 平行模型」会分裂 `querySelectorAll` 与样式匹配，M5 已否决同类方案。

`:hover` 的样式规则与普通规则共用 `(important, origin, specificity, order)` 级联，不改变特异性计算。

### D2 命中测试：DOM 遍历 + 解析几何，不经过显示列表

`SvgHitTest` 先从 `SvgRenderOptions` 构造 `SvgViewportTransform`，把设备点除以 DPR 后乘矩阵逆得到用户空间点。遍历从根开始，按文档顺序递归；先访问子节点再判定自身，使返回列表天然是「后绘制者在前」。

每个元素的有效矩阵复用 `svgElementCtm`（`SvgGeometry.cj`）的带样式路径；命中判定按 `pointer-events` 分派：

- `none`：跳过自身与整棵子树；
- `bounding-box`：`getBBox` 矩形包含点；
- `fill` / `visibleFill` / `painted` / `visiblePainted`：点落在填充内。填充判定复用 `flattenPathData`（`SvgRasterizer.cj:461`）得到轮廓，再按 `fill-rule` 做射线 / 环绕判定；
- `stroke` / `visibleStroke`：点到扁平化中心线的距离 ≤ `stroke-width / 2`，`stroke-linecap` 只在端点影响结果；
- `all`：忽略 `visibility` 与画笔；
- `visible`：要求 `visibility != hidden`，命中内区或描边几何，不要求 `fill` / `stroke` 非 `none`。

`image` 用矩形，`text` 用字形轮廓（`SvgTextRenderer` 的布局结果），容器只用包围盒且仅当 `pointer-events` 为 `all` / `bounding-box` 时参与。备选「渲染 1×1 覆盖率」需要完整光栅化，成本高且无法返回元素链，否决。

### D3 pointer-events / cursor：只进计算样式

`pointer-events` 注册为可继承属性，归一化为 `SvgPointerEvents` 后以规范字符串存入计算样式；`SvgComputedStyle` 增加 `pointerEvents()` 类型化 getter。`cursor` 保持字符串，按 CSS 关键字白名单校验；`url(...)` 与未知值回退 `auto` 并 warning。两者都不进入 `SvgRenderTree` 的绘制判定，除 D2 的命中测试外无消费点。

### D4 foreignObject：构建期回调，复用 Image 指令

新增 `SvgForeignObjectRenderer` 接口与 `SvgRenderOptions.foreignObjectRenderer`。`SvgRenderTreeBuilder` 在遇到 `foreignObject` 时按 `x/y/width/height` 求逻辑尺寸，调用 renderer；返回的位图存入 `SvgDisplayCommand` 新增字段 `bitmap: ?SvgBitmap`，指令仍用 `Image` kind，`href` 为 `None`。

理由：`SvgDisplayCommandKind` 是公开枚举，新增构造器会让下游穷尽 `match` 编译失败；复用 `Image` 并加可选字段只增不改。构建期调用让「未提供 / 返回 None / 缺尺寸」的降级在同一处完成，光栅化阶段只需按矩形缩放位图。备选「光栅化期回调」需要把 `SvgElement` 与 options 传入指令，扩大显示列表契约。

不解析 XHTML 子节点；`foreignObject` 的内部文本 / 元素一律不遍历。

### D5 外部文档：构建期解析 + 单次渲染缓存

`SvgExternalDocumentProvider.resolveHref(href)` 只在 `use` 的 href 非 `#` 片段时调用。构建器维护：

- `HashMap<String, SvgDocument>` 按 href 缓存成功解析结果；
- `HashMap<String, Bool>` 缓存 provider 返回 `None` 的负结果，同一 href 单次渲染只询问一次；
- `HashMap<String, Bool>` 记录本次渲染的 provider 调用链，命中即 warning 并停止；
- 单文档字节数组长度超过 16 MiB 抛 `Limit`。`SVG_EXTERNAL_MAX_DEPTH` 与
  `svgExternalDepthAllows` 仅作异常路径的防御性检查保留，外部文档不递归加载，正常渲染不触达。

外部文档用 `SvgParser.parse(bytes, SvgParseOptions(security: 主文档 security 的副本, strict: 主文档 strict))` 解析；其中 `allowExternalReferences` 与 `unsafePolicy` 强制为
`false` / `Remove`，因此外部文档内部的不安全内容（含外部 `href`）一律移除并 warning，
不随调用方的 `Reject` / `Keep` 改变，也不会二次触发 provider。除这两项外，`allowScript`、
`allowEventAttributes`、`allowDataImages`、`maxElements`、`maxDepth`、`maxDecompressedBytes`
与 `strict` 均沿用主文档。目标元素用 `document.elementById(fragment)` 或根。

重要边界：解析期 `SvgBuilder` 会按 `allowExternalReferences` 移除外部 `href`；因此外部 `use` 只有在主文档解析时显式放行外部引用后才可用。这一点写入 README 与任务备注。

### D6 initialView：替换根视口矩阵，不改输出尺寸

`SvgRenderTreeBuilder.build` 在解析 `initialView`（去掉前导 `#`）后调用 `SvgDocument.view(id)`；命中且含 `viewBox` 时用 `SvgViewport.forView(view, logicalWidth, logicalHeight)` 生成矩阵，替代 `SvgViewport.from(...).transform(root)`。输出宽高仍取 `options.width` / `height` / 根尺寸，`viewTarget` 忽略。

### D7 渲染提示：样式携带，渲染器按指令取值

四个属性进入计算样式并可继承。`SvgRenderer` 在 `renderCommand` 处从 `command.style` 读取：

- `shape-rendering` → 传给 `SvgRasterizer` 的 `toleranceScale`（`geometricPrecision` 0.25）与 `antiAliasOverride`（`optimizeSpeed` 关闭、`crispEdges` 关闭）；`crispEdges` 时描边中心线按设备像素网格取半像素对齐；
- `text-rendering` → 由 `SvgTextRenderer` 在布局时读取（容差倍率与连字 / 字距开关）；
- `color-rendering` → 传给 `SvgGradientSampler` 的量化级数：`auto` 不量化，`optimizeSpeed` 128，`optimizeQuality` 512；
- `color-interpolation` → 传给 `SvgGradientSampler`。

`SvgRasterizer` 的 `fill` / `stroke` 增加可选参数并保留原默认值，原调用输出不变。量化通过「把 `t` 四舍五入到 1/N 网格后查 stop」实现，不引入 LUT 缓冲。

### D8 线性光插值：stop 预转换

`SvgGradientSampler` 增加 `colorInterpolation` 与可选 `styles` 参数。`linearRGB` 时在 `resolveStops` 返回前把每个 stop 的 RGB 转为线性值，`sampleStops` 在线性域插值，输出前一次性转回 sRGB；alpha 始终线性插值。转换函数放 `SvgColor` 附近，带 256 项查表缓存避免逐像素 `pow`。`auto` / `sRGB` 走原分支，保证字节一致。

`sRGB` 端点经两次转换后可能有 ±1/255 误差；实现上在 `t` 恰为 stop 偏移时直接返回原 stop 颜色，避免端点漂移。

### D9 @color-profile：解析成独立列表，属性只做白名单

`CssStyleSheet` 新增 `colorProfiles: Array<CssColorProfileRule>`（`name` + `src: ?String`）；解析器按 `@font-face` 的模式处理，跳过而不进入 `rules`。`color-profile` 属性归一化时保留名称字符串；`SvgStyleResolver` 在 `prepare` 后构建已声明名称集合，未声明的名称改写为 `sRGB` 并 warning（同一名称每次解析只记一次）。

渲染侧只读取「是否 sRGB」：非 sRGB 按 sRGB 计算并 warning。不做 ICC。

### D10 pathLength：单一比例，两个消费点

`SvgPathLength.ratio(element, actualLength)` 读取 `pathLength` 并返回 `actualLength / pathLength`；非法值返回 1 并 warning。两个消费点：

- `SvgStrokeOutliner` 的 dash 切分：`dasharray` / `dashoffset` 先乘比例；
- `SvgTextPathLayout`：`startOffset` 长度与字形累计弧长乘比例；百分比仍按实际弧长。

`SvgPathData.totalLength` / `getPointAtLength` 保持实际弧长，不乘比例。

### D11 字体匹配与合成

`SvgFontRegistry` 增加 `register(family, font, stretch!)` 与 `resolve(family, weight, style, stretch!)` 重载；内部键扩展为 `family|weight|style|stretch`，原 `register` / `resolve` 委托 `"normal"` / 100。匹配规则：先精确百分比，再取已注册 stretch 中与目标差值最小者；无匹配回退 100%。

`font-stretch` 为百分比且最终使用 100% 字体时，`SvgTextRenderer` 用现有 `scalePathX`（`SvgTextRenderer.cj:1187`）对字形路径与 advance 做水平缩放。

small-caps：小写码点经 `cmap` 取大写字形；新增 `scalePathUniform(path, factor)`（现有 `scalePathX` 只缩放 x，不能用于两轴缩放），并同步缩放 advance。合成在 `font-size-adjust` 之后、`textLength` 之前。

`font-size-adjust`：`SvgTrueTypeFont` 新增内部 `xHeightRatio()`，解析 `OS/2` 表 `sxHeight`（offset 86）与 `unitsPerEm`；缺表返回 `None`，布局层忽略 + warning。`SvgFont` 接口不变。

### D12 OpenType 特性：把 GSUB 规则按特性分组

`SvgOpenTypeLayout` 目前只收集 `liga` 的 Type 4 子表。M6 改为：解析 FeatureList 时为每个特性名（`liga` / `clig` / `dlig` / `hlig` / `calt` / `kern`）建立独立的 `SvgGsubFeatureSet`，每个 set 保存其 lookup 图；`SvgGsubLigatures` 变为「按特性名查询规则」的门面，`ligatureAt` 增加特性名参数，默认 `liga` 以保持 M5 行为。

GSUB Type 5/6 解析为 `SvgGsubContextRule`（覆盖表、回溯 / 输入 / 前瞻序列、替换 lookup 列表）。应用时维护 lookup 调用栈，深度超过 8 停止并 warning；替换 lookup 只允许 Type 1（single）与 Type 4（ligature）。Type 6 的嵌套调用复用同一栈。

`font-feature-settings` 与 `font-variant-ligatures` 在样式层合并为 `SvgFontFeatures`（`HashMap<String, Bool>`），布局层传给它；`font-kerning` 最后覆盖 `kern`。默认集合与 M5 等价（`liga` / `clig` 开，`dlig` / `hlig` 关）。

### D13 装饰线长属性：线型规格与几何分离

保留 `SvgTextDecoration` 表示三条线开关；新增 `SvgTextDecorationSpec`（`lines: SvgTextDecoration`、`style: SvgTextDecorationStyle`、`color: ?SvgColor`、`thickness: ?Float64`、`underlinePosition: SvgTextUnderlinePosition`）承载长属性。文本布局把 spec 附着到每个字形，`decorationRuns` 按 spec 生成：

- `dotted` / `dashed`：沿装饰线方向按厚度生成等距短段；
- `double`：生成两条平行细线，总厚度等于 `thickness`；
- `wavy`：以 `thickness` 为振幅生成正弦折线；
- 颜色缺省取字形 `fill`，厚度缺省 `max(1, fontSize / 14)`。

简写 `text-decoration` 在 `normalizeValue` 时展开为长属性，长属性再参与级联；未声明长属性时读取简写值。

### D14 动画控制：时间源、触发表与采样快照

`SvgTimeline` 增加内部状态：

- `explicitTime: ?Float64`、`pausedAt: ?Float64`、`timeOffset: Float64`；
- `triggeredBegin: HashMap<String, Float64>`、`endedAt: HashMap<String, Float64>`。

`currentTime()` = `explicitTime ?? (pausedAt ?? (clock.now() + timeOffset))`。`pause()` 先取当前时间写入 `pausedAt`；`unpause()` 把 `timeOffset` 调整为 `pausedAt - clock.now()` 后清空 `pausedAt`。

`begin(id)` 仅对 `begin="indefinite"` 或事件型 `begin` 生效，记录 `currentTime()`；`end(id)` 记录 `endedAt`。`fireEvent` 按 `;` 拆分时间项，事件名比较不区分大小写；匹配 `begin` 项走 `begin`，匹配 `end` 项走 `end`。

`sample` 用「触发时刻优先、否则构造期解析值」计算有效 begin / end；排序改用有效 begin。`min` / `max` 在 `animationStateAt` 中钳制活动时长。`discard` 在应用完全部动画后处理：按 `begin + dur` 判断，移除目标；嵌套深度由 `discard` 元素的祖先链计算，超过 1 只处理最外层。

`attributeType="CSS"`：在快照元素上调用新的 `svgSetInlineStyleProperty(element, name, value)`，重写同名声明而保留其他内联声明；解析后的级联自然让内联样式高于样式表。

理由：所有状态都在 `SvgTimeline` 实例内，`sample(time)` 仍是无状态纯函数；备选「修改 clock」会破坏调用方对 `SvgManualClock` 的控制。

### D15 DOM API：文档级 hub，元素沿 parent 链查找

`SvgDocument` 持有 `internal let mutationHub`；`SvgRoot` 在构造时无 hub，由 `SvgDocument.init` 注入根上的 `internal var mutationHub`。`SvgElement` 在变更后沿 `parent` 链上溯到根，若根带 hub 则同步通知。未挂载子树不通知。

`insertBefore(node, reference)` / `removeChild(node)` 维护 `children`、`parent`，并对 `appendChild` 补通知。监听器列表上限 32，超限抛 `InvalidValue`；通知时逐个 `try` 捕获异常，warning 写入文档 `warnings`。

命中查询 `getIntersectionList` / `getEnclosureList` 在根上计算一次样式树，遍历 `reference` 后代，按 `getBBox` 判定并过滤 `pointer-events: none` / `visibility: hidden`。`check*` 复用同一判定函数，避免两套语义。

工厂方法只转调既有构造器；`SvgViewState` 提供 `toMatrix()`，渲染时插在根视口矩阵之后。

### D16 vector-effect 扩展：分解矩阵后逐项修正

新增 `SvgVectorEffect2.apply(matrix, effects)`：由 `a,b,c,d,e,f` 分解出平移、旋转 `atan2(b, a)`、尺度 `hypot(a,b)` / `hypot(c,d)`。按 `non-scaling-size` → `non-rotation` → `fixed-position` 顺序重建矩阵：

- `non-scaling-size`：尺度置 1，保留旋转与平移；
- `non-rotation`：旋转置 0，保留尺度与平移；
- `fixed-position`：丢弃祖先累积矩阵，只保留元素自身变换。

多值组合时对结果矩阵逐项再分解。`non-scaling-stroke` 仍走既有描边缩放，不参与该函数。

### D17 自动尺寸：只认显式 auto

`width` / `height` 的 `auto` 只在属性文本为 `auto` 时生效；缺失属性仍走 M5 的 `SvgViewport.from` 推导，避免改变既有输出。

根：先用样式树与 `svgBBoxOf` 求内容包围盒；有 `viewBox` 时按 `viewBox` 宽高比从另一轴推导缺失轴；两轴都 auto 时取内容包围盒尺寸并按 `viewBox` 比例修正。嵌套：显式 auto 取父视口对应轴。无法确定时回退 M5 缺省并 warning。

### D18 文件与改动映射

按设计文档 §9 建 15 个新文件（原计划 18 个，其中 `SvgColorProfile.cj` 并入 `SvgRenderingHints.cj`、`SvgLineJoin2.cj` 并入 `SvgShape.cj` / `SvgStrokeOutliner.cj`、`SvgAnimationControl.cj` 并入 `SvgTimeline.cj`）；测试文件同名加 `_test.cj` 或按阶段拆分为 `*M6_test.cj`。

- 解析 / 样式层：`SvgPointerEvents.cj`、`SvgCursor.cj`、`SvgRenderingHints.cj`、`SvgFontVariant.cj`、`SvgTextDecoration2.cj` 只被 `CssStyleSheet` / `SvgStyleResolver` / `SvgComputedStyle` 引用；
- 渲染层：`SvgHitTest.cj`、`SvgForeignObject.cj`、`SvgExternalDocument.cj`、`SvgInitialView.cj`、`SvgVectorEffect2.cj`、`SvgAutoSize.cj` 只被 `SvgRenderTree` / `SvgRenderer` / `SvgRasterizer` / `SvgStrokeOutliner` 引用；
- 文本层：`SvgGsubContext.cj`、`SvgPathLength.cj` 只被 `SvgTextRenderer` / `SvgTextPathLayout` / `SvgStrokeOutliner` 引用；
- DOM / 动画层：`SvgHitQueries.cj`、`SvgMutation.cj` 只被 `SvgTimeline` / `SvgDocument` / `SvgElement` 引用。

公开方法声明写在既有类体内（`SvgElement` / `SvgDocument` / `SvgTimeline` / `SvgPoint` / `SvgMatrix` / `SvgTransform`），避免扩展对私有状态的可见性问题；新文件只放内部实现与公开枚举 / 结构体。

### D19 M6 快照语义

9 张 `m6-*` 快照各自绑定一项能力，不以“字节稳定”代替语义覆盖：

- `m6-interaction`：`hoveredIds` / `focusedIds` 经样式级联改变输出；
- `m6-foreign-object`：注入 2×2 位图按 `foreignObject` 区域绘制；
- `m6-initial-view`：`initialView="#detail"` 覆盖根视口；
- `m6-rendering-hints`：`shape-rendering` 三档与 `text-rendering` 组合；
- `m6-color-interpolation`：两条红蓝渐变分别声明 `sRGB` / `linearRGB`，中点颜色必须不同；
- `m6-font-details`：`font-stretch` / `small-caps` / 装饰线可见；
- `m6-animation-control`：固定 `sample(2.0)` 后渲染；
- `m6-hit-queries`：渲染前真实调用 `SvgHitTest.elementsAt`，把命中 id 注入 `hoveredIds`，再由 `rect:hover` 改变像素；
- `m6-svg2`：`miter-clip` / `arcs` 描边，以及带祖先 `scale(2)` 的 `non-scaling-size` 矩阵修正。

`m6-color-interpolation`、`m6-hit-queries`、`m6-svg2` 在本轮功能修正后重新生成，原因记录在 `verification.md`；M1–M5 的 25 张快照保持逐字节不变。

## Risks / Trade-offs

- **字节一致性被默认路径破坏** → 所有新行为用「空集合 / `None` / `auto` / 缺失属性」短路；M1–M5 全部快照加入逐字节回归；新增 `m6-*` 快照单独管理。
- **交互状态与样式缓存** → `CssSelectorIndex` 只缓存选择器结构，不缓存匹配结果；`SvgStyleResolver` 每次 `compute` 重跑级联，状态只影响伪类分支。
- **`SvgLineJoin` 新增构造器破坏下游穷尽 `match`** → 在 README / CHANGELOG 标注为「新增构造器」；`f_svg` 内部所有 `match` 同步补分支；不做默认分支掩盖。
- **`foreignObject` 位图进入显示列表** → 位图受 `maxPixels` 与 `maxElements` 约束；构建期分配前校验尺寸，超限抛 `Limit`。
- **外部文档依赖解析期放行** → README 明确「provider 仅在 `allowExternalReferences=true` 时可用」；未放行时按缺失引用 warning，不静默回退。
- **`color-rendering` 与设计文档措辞不一致** → 以「量化级数」实现并在 README 说明 `auto` 是解析式；不伪造不存在的采样点。
- **linearRGB 逐像素 `pow` 开销** → stop 预转换 + 256 项查表；只在声明 `linearRGB` 时进入该分支。
- **GSUB 特性分组重构可能改变 M5 连字输出** → 默认特性集合与 M5 完全等价；M5 的 `SvgGsubM5_test` / `SvgKerningLayoutM5_test` 作为硬门禁，任何差异按回归处理。
- **小写转大写字形可能缺字** → 缺大写字形时保留原字形并 warning，不做二次回退。
- **命中测试每元素 `getBBox` 可能慢** → 只在显式调用时发生；`perf-baseline.md` 记录 1000 元素单次耗时；不进入渲染热路径。
- **自动尺寸改变默认布局** → 只认显式 `auto`；缺失属性路径完全不动。
- **动画 CSS 覆盖层与 `!important` 的优先级** → 内联样式低于 `!important`；README 说明 `attributeType="CSS"` 不覆盖 `!important`，与浏览器一致。
- **`discard` 移除元素影响后续动画** → 在全部动画应用后统一移除，避免中途删除导致目标解析失败。

## Migration Plan

1. 从当前工作基线切 `feature/f-svg-m6`，跑 `cjpm test` 确认 997 条全绿并记录耗时。
2. 按 P1 → P2 → P3 → P4 → P6 → P7 → P8 分组实现，每组先写失败用例、再实现、再重构，组末全绿后独立提交。
3. 每组结束跑一次 M1–M5 快照逐字节比对；新增 `m6-*` 快照只在对应组内生成并复核。
4. 全部完成后更新 README / `perf-baseline.md` / CHANGELOG，跑 `cjpm test`、`cjpm build`（0 warning）与 `openspec validate --strict`。
5. 回滚策略：本变更无数据迁移；按提交组 revert 即可，快照文件随组提交，回滚后 M5 输出不受影响。

## Open Questions

无。设计文档未明确但影响实现的细节（合成缩放方式、`color-rendering` 量化口径、`begin(id)` 适用范围、`fixed-position` 的矩阵定义、`auto` 仅显式生效）已在上文决策中定稿；若后续需要偏离，应另开变更修改 spec。
