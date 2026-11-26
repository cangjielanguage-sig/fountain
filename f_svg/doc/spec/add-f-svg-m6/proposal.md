# add-f-svg-m6

## Why

M1–M5 已让 `fountain::f_svg` 覆盖 SVG 1.1 的文档模型、CSS 选择器与级联、几何、CPU 光栅、滤镜、图案、文本整形与元素级查询。剩余的非脚本能力仍集中在七个方向：没有命中测试与 `pointer-events` / `cursor`，调用方无法做静态交互；`foreignObject`、外部文档引用、`view` 片段与根属性缺失，嵌入场景只能退化为占位；渲染提示与颜色插值不生效，同一素材无法在速度与精度之间取舍；字体细节（stretch / small-caps / size-adjust / feature / 装饰长属性 / GSUB 5-6 / pathLength）缺失导致排版失真；动画只能在显式时间轴上采样，无法响应 `begin="indefinite"` 或事件；DOM 查询、工厂方法与变更通知缺失；SVG 2 的 `vector-effect` 扩展、`miter-clip` / `arcs` 与 `width/height: auto` 未实现。

M6 按 `f_svg/doc/f_svg-M6设计.md`，以 **P1 静态交互 → P2 文档与嵌入 → P3 渲染提示 → P4 文本与字体 → P6 动画 → P7 DOM API → P8 SVG 2** 顺序收口上述能力。只增不改 M1–M5 公开 API 语义，未使用 M6 特性的文档输出与 M5 逐字节一致，不新增模块、子包或第三方依赖。

## What Changes

**P1 静态交互（无脚本）**

- **M6-P1-1 `pointer-events`**：解析 `auto` / `none` / `visiblePainted` / `visibleFill` / `visibleStroke` / `visible` / `painted` / `fill` / `stroke` / `all` / `bounding-box`，新增 `SvgHitTest` 提供设备坐标命中，`none` 连同子树退出命中。
- **M6-P1-2 `cursor`**：解析为计算样式字符串，非法值回退 `auto` 并 warning；不加载光标资源。
- **M6-P1-3 `:hover` / `:focus`**：选择器引擎新增交互伪类，通过 `SvgRenderOptions.hoveredIds` / `focusedIds` 静态求值；未提供时永不匹配。

**P2 文档与嵌入**

- **M6-P2-1 `foreignObject` 注入**：新增 `SvgForeignObjectRenderer` 与 `SvgRenderOptions.foreignObjectRenderer`；未提供时透明占位 + warning，不解析 XHTML。
- **M6-P2-2 外部文档引用**：新增 `SvgExternalDocumentProvider` 供 `use` 指向外部 SVG；深度 ≤ 4、单文档 ≤ 16 MiB、循环引用 warning 后停止。
- **M6-P2-3 `initialView`**：`SvgRenderOptions.initialView` 按命中 `view` 的 `viewBox` / `preserveAspectRatio` 覆盖初始视口，未命中 warning 后回退根视口。
- **M6-P2-4 根属性**：`SvgDocument.baseProfile()` / `version()` / `zoomAndPan()` 暴露根属性；`zoomAndPan` 只存值不影响渲染。

**P3 渲染提示与颜色**

- **M6-P3-1 `shape-rendering`**：`auto` / `optimizeSpeed` / `crispEdges` / `geometricPrecision`，映射到采样倍数、描边 AA 与曲线扁平化容差。
- **M6-P3-2 `text-rendering`**：映射到连字 / 字距开关与曲线容差。
- **M6-P3-3 `color-rendering`**：`auto` 保持解析采样；`optimizeSpeed` / `optimizeQuality` 使用更粗 / 更细的渐变量化步长。
- **M6-P3-4 `color-interpolation`**：`linearRGB` 时渐变 stop 在线性光空间插值后再转回 sRGB；`auto` / `sRGB` 保持现状。
- **M6-P3-5 `@color-profile`**：解析声明与 `color-profile` 属性；仅 sRGB 生效，其他 profile 回退 sRGB + warning。

**P4 文本与字体细节**

- **M6-P4-1 `font-stretch`**：9 个关键字 + 百分比，参与字体匹配；无匹配时按 100% 使用，百分比可合成水平缩放。
- **M6-P4-2 `font-variant: small-caps`**：小写字母取大写字形并缩放到 `0.8 × fontSize`。
- **M6-P4-3 `font-size-adjust`**：按 `OS/2.sxHeight / unitsPerEm` 修正字号；缺表时忽略 + warning。
- **M6-P4-4 `font-feature-settings`**：`"liga" 0` / `"kern" 1` 等 tag 开关透传到整形，条目上限 64。
- **M6-P4-5 `font-variant-ligatures`**：`none` / `common-ligatures` / `discretionary-ligatures` / `historical-ligatures` / `contextual`；与 `font-feature-settings` 合并时后者优先。
- **M6-P4-6 `text-decoration` 长属性**：`-line` / `-style` / `-color` / `-thickness` 与 `text-underline-position`，简写展开为长属性。
- **M6-P4-7 GSUB Type 5/6**：Context / ChainContext format 3 子集，链式 lookup 深度 ≤ 8，只做单字形替换与连字替换。
- **M6-P4-8 `pathLength`**：按 `pathLength / actualLength` 校准 `stroke-dasharray` / `stroke-dashoffset` 与 `textPath` 弧长；非法值忽略 + warning。

**P6 动画控制**

- **M6-P6-1 `begin="indefinite"`**：`SvgTimeline.begin(id)` / `end(id)` 显式触发；触发前不活动。
- **M6-P6-2 事件式 begin / end**：`fireEvent(id, name)` 显式触发 `click` / `mouseover` / `accessKey` / `wallclock`；不接 UI 事件循环。
- **M6-P6-3 时间 API**：`currentTime()` / `setCurrentTime(t)` / `pause()` / `unpause()`；`sample(time)` 语义不变。
- **M6-P6-4 `attributeType`**：`CSS` 写入内联样式覆盖层，`XML` 写属性（默认）。
- **M6-P6-5 `min` / `max`**：活动时长钳制；`min > max` warning 后忽略。
- **M6-P6-6 `discard`**：到达 `begin + dur` 后从采样快照移除目标元素，不做嵌套传播。

**P7 DOM API**

- **M6-P7-1 命中查询**：`getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure`，基于 `getBBox` 并由 `pointer-events` / `visibility` 筛选。
- **M6-P7-2 工厂方法**：`SvgPoint.create` / `SvgMatrix.create` / `SvgTransform.create` 静态工厂，不改变既有类型。
- **M6-P7-3 视图状态**：`SvgViewState`（`currentScale` / `currentTranslate`）可作为 `SvgRenderOptions.viewState` 传入。
- **M6-P7-4 变更监听**：`SvgDocument.addMutationListener` / `removeMutationListener`，在 `setAttr` / `removeAttr` / `appendChild` / `removeChild` / `insertBefore` 后同步通知；监听异常捕获为 warning；监听器上限 32。

**P8 SVG 2 收尾**

- **M6-P8-1 `vector-effect` 扩展**：`non-scaling-size` / `non-rotation` / `fixed-position`，按声明顺序组合应用。
- **M6-P8-2 `stroke-linejoin` 扩展**：`miter-clip` 超限截断、`arcs` 以 `stroke-width / 2` 圆弧连接。
- **M6-P8-3 `width` / `height: auto`**：根按内容包围盒与 `viewBox` 比例确定，嵌套 `svg` 按父视口 100%，无法确定时 warning。

## Capabilities

### New Capabilities

无。M6 的全部行为归入既有能力域；命中测试、嵌入、渲染提示、字体细节、动画控制、DOM API 与 SVG 2 收尾都是既有能力域的增量，不为同一概念新建近似重复的 spec。

### Modified Capabilities

- `svg-css`：新增 `/focus` 交互伪类与 `pointer-events` / `cursor` / 四个渲染提示 / `color-profile` / `font-stretch` / `font-size-adjust` / `font-feature-settings` / `font-variant-ligatures` / `text-decoration` 长属性的注册与归一化；改写「CSS 规则集解析」支持 `@color-profile`。
- `svg-value-types`：新增 `SvgPointerEvents`、`SvgCursor`、`SvgShapeRendering`、`SvgTextRendering`、`SvgColorRendering`、`SvgColorInterpolation`、`SvgZoomAndPan`、`SvgFontStretch`、`SvgTextDecorationStyle`、`SvgTextUnderlinePosition`、`SvgViewState` 与三类工厂方法；扩展 `SvgVectorEffect`、`SvgLineJoin`。
- `svg-geometry`：新增 `SvgHitTest` 命中测试、`pathLength` 校准比例、`vector-effect` 扩展的几何矩阵语义。
- `svg-document-model`：新增根属性查询、P7 命中查询 API、变更监听与 `insertBefore` / `removeChild`；`discard` 元素模型。
- `svg-render-pipeline`：新增 `SvgRenderOptions` 的 M6 字段、`foreignObject` 注入、外部文档 `use`、`initialView`、`width/height: auto`、`vector-effect` 与 `viewState` 的应用位置。
- `svg-rasterization`：改写「抗锯齿」与「join 与 dash 规则」，加入 `shape-rendering` / `color-rendering` 映射、`miter-clip` / `arcs` 与 `pathLength` 的像素语义。
- `svg-paint-and-clip`：新增 `color-interpolation` 与 `@color-profile` 对渐变插值的要求。
- `svg-text`：改写「文本布局」「文本装饰线」「textPath 路径与起点」，加入 `font-stretch` / small-caps / `font-size-adjust` / 特性开关 / GSUB 5-6 / 装饰长属性与 `pathLength`。
- `svg-animation`：改写「时间模型」，加入触发 / 时间控制 API、`attributeType`、`min` / `max`、`discard`。
- `svg-security`：新增 M6 上限表（外部文档深度与字节、GSUB 链式深度、特性条目、监听器数、`discard` 嵌套深度、命中测试元素数）及超限方式。

## Impact

- **Affected code**（全部位于 `f_svg/src` 单包，不新建模块、子包或依赖）：
  - 新增 `SvgPointerEvents.cj`、`SvgHitTest.cj`、`SvgCursor.cj`、`SvgForeignObject.cj`、`SvgExternalDocument.cj`、`SvgInitialView.cj`、`SvgRenderingHints.cj`、`SvgColorProfile.cj`、`SvgFontVariant.cj`、`SvgTextDecoration2.cj`、`SvgGsubContext.cj`、`SvgPathLength.cj`、`SvgAnimationControl.cj`、`SvgHitQueries.cj`、`SvgMutation.cj`、`SvgVectorEffect2.cj`、`SvgLineJoin2.cj`、`SvgAutoSize.cj` 及对应 `*_test.cj`；
  - 修改 `CssSelector2.cj` / `CssStyleSheet.cj` / `SvgStyleResolver.cj` / `SvgComputedStyle.cj`（交互伪类、`@color-profile`、M6 属性注册与归一化）、`SvgElement.cj`（`insertBefore` / `removeChild` / 命中查询入口）、`SvgDocument.cj`（根属性、命中查询、变更监听）、`SvgBitmap.cj`（`SvgRenderOptions` 字段）、`SvgRenderTree.cj`（交互状态、`foreignObject`、外部 `use`、`initialView`、`vector-effect`、auto 尺寸）、`SvgRenderer.cj` / `SvgRasterizer.cj`（渲染提示与光栅参数）、`SvgGradient.cj`（颜色插值 / profile / 量化步长）、`SvgStrokeOutliner.cj`（`miter-clip` / `arcs`）、`SvgPathData.cj` / `SvgPathMeasure.cj`（`pathLength` 比例）、`SvgTextRenderer.cj` / `SvgTextPathLayout.cj` / `SvgTextDecoration.cj`（字体细节与装饰长属性）、`SvgTrueTypeFont.cj` / `SvgTrueTypeTables.cj`（`OS/2`、特性开关、GSUB 5/6）、`SvgTimeline.cj`（触发 / 时间 / `discard`）、`SvgShape.cj` / `SvgVectorEffect.cj`（枚举扩展）、`SvgFont.cj`（stretch 匹配）、`SvgUse.cj`（外部 href）；
  - `f_svg/testdata/render/` 新增 `m6-*` 场景与期望图；`f_svg/testdata/fonts/` 新增 `OS/2` 与 GSUB 5/6 fixture；
  - 更新 `f_svg/README.md` / `README_en.md`、`f_svg/doc/perf-baseline.md` 与 `CHANGELOG`。
- **公开 API 增量**：
  - `SvgRenderOptions` 新增带默认值的 `hoveredIds` / `focusedIds` / `initialView` / `foreignObjectRenderer` / `externalDocuments` / `viewState`；
  - `SvgDocument` 新增 `baseProfile` / `version` / `zoomAndPan` / 四个命中查询 / 两个变更监听；`SvgElement` 新增 `insertBefore` / `removeChild`；
  - `SvgTimeline` 新增 `begin` / `end` / `fireEvent` / `currentTime` / `setCurrentTime` / `pause` / `unpause`；
  - `SvgPointerEvents` / `SvgShapeRendering` 等新枚举，`SvgVectorEffect` 新增 3 个静态取值、`SvgLineJoin` 新增 2 个构造器；
  - `SvgPoint.create` / `SvgMatrix.create` / `SvgTransform.create` 与 `SvgViewState`；
  - `CssPseudoClass` 新增 `Hover` / `Focus`；`CssStyleSheet` 新增 `colorProfiles`。
- **兼容性**：
  - 未使用 M6 特性的文档输出与 M5 逐字节一致；`pointer-events` / `cursor` 只进计算样式；`:hover` / `:focus` 在未提供集合时永不匹配；`initialView` 缺省 `None`；四个渲染提示缺省 `auto`；字体新属性缺省不改变既有选择；动画新 API 不改变 `sample(time)`；
  - `SvgRenderOptions` 只新增带默认值字段；`SvgVectorEffect` 是类 + 静态常量，新增取值不破坏下游 `match`；`SvgLineJoin` 是枚举，新增构造器需下游穷尽 `match` 补分支，在 README / CHANGELOG 标注；
  - 不修改 `f_xml` / `f_base` 公开 API、根 `cjpm.toml`、`.modules` 与聚合根 shim；`f_svg/cjpm.toml` 不新增依赖。
- **验收锚点**：当前基线为 **997** 条用例（设计文档写的 987 取自 M5 修复前，晚于该数字的 `verification.md` 已记录 997）；M1–M5 全部用例与既有 25 张渲染快照逐字节一致；每个 Requirement 至少 1 个可执行 Scenario；七类特性各至少 1 个像素或几何断言；所有上限有负向用例；`cjpm test` 全绿且 `f_svg` 自身 0 warning；`openspec validate --strict` 通过。

## Non-goals

- `<script>`、`on*` 事件属性、事件监听、链接激活；`:hover` / `:focus` 只做静态状态求值。
- `foreignObject` 内部 XHTML 语义（只提供注入接口）、ICC 颜色变换（只解析声明并回退 sRGB）。
- JPEG / GIF / WebP / SVG-as-image（M7）、`mesh` / `hatch` 渐变（M7）、GPU 后端。
- 浏览器逐像素一致；只保证设计文档定义的 SVG 2 / OpenType 子集语义与自有快照稳定。
