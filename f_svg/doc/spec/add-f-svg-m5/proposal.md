# add-f-svg-m5

## Why

M1–M4 已让 `fountain::f_svg` 覆盖 SVG 1.1 的文档模型、基础 CSS、几何、CPU 光栅、滤镜、图案、文本排版、TTF 与元素级几何查询。真实素材仍会在四类场景静默失真：

- **样式表达力不足**：选择器只有类型 / 类 / id，`@media`、属性选择器、结构伪类、兄弟组合器一律被整条丢弃；没有 CSS 变量与 `calc()`，响应式或主题化的 SVG 只能退化为预设颜色；
- **SVG 2 视觉特性缺失**：`paint-order` 无法调整描边压填充，`mix-blend-mode` / `isolation` 无法做图层混合，`feDropShadow` 只能手写四段滤镜，`transform-origin` 只能绕原点，`context-fill` / `context-stroke` 让 `use` 复用失效；
- **文本整形缺失**：TTF 的 `kern` / `GPOS` 字距与 `GSUB` 标准连字被忽略，`direction` / `unicode-bidi` 不生效，阿拉伯语或中英混排素材的字距与阅读顺序错误；
- **元素级 API 缺失**：调用方无法按元素取包围盒、CTM、屏幕 CTM 与路径长度，也无法用类名或选择器做命中测试与二次加工。

M5 按 `f_svg/doc/f_svg-M5设计.md`，以 **P1 CSS 扩展 → P2 SVG 2 渲染 → P3 文本整形 → P4 元素级 API** 顺序收口这四类能力。只增不改 M1–M4 公开 API 语义，未使用新特性的文档输出与 M4 逐字节一致，不新增模块、子包或第三方依赖。

## What Changes

**P1 CSS 扩展**

- **M5-P1-1 属性选择器**：`[attr]` / `=` / `~=` / `|=` / `^=` / `$=` / `*=`，支持 `i` 大小写不敏感标志。
- **M5-P1-2 结构伪类**：`:root`、`:first-child`、`:last-child`、`:only-child`、`:nth-child(An+B)`、`:first-of-type`、`:last-of-type`、`:nth-of-type`、`:only-of-type`、`:empty`。
- **M5-P1-3 否定伪类**：`:not(<简单选择器>)` 单层，不接受嵌套。
- **M5-P1-4 兄弟组合器**：`A + B` 相邻兄弟、`A ~ B` 一般兄弟。
- **M5-P1-5 `@media`**：`screen` / `all`、`(min-width: Npx)` / `(max-width: Npx)`、`and`、逗号列表；宽度取渲染视口宽度。
- **M5-P1-6 `@font-face`**：只把 `font-family` 别名映射到已注册字体；`src` 忽略并记 warning，不加载任何文件。
- **M5-P1-7 CSS 变量**：`--name: value` 声明与继承，`var(--name, fallback)`，嵌套上限 8 层，循环使声明无效。
- **M5-P1-8 `calc()`**：长度四则运算与括号，支持 `px` / `%` / `em`，仅用于长度属性。

**P2 SVG 2 渲染**

- **M5-P2-1 `paint-order`**：`fill` / `stroke` / `markers` 任意子集，缺省 `fill stroke markers`，marker 位置随序列移动。
- **M5-P2-2 `mix-blend-mode`**：12 种混合模式（`normal` 到 `exclusion`），在预乘 RGBA 上逐像素合成。
- **M5-P2-3 `isolation`**：`auto` / `isolate`；`isolate` 或非 `normal` 混合时建立隔离组。
- **M5-P2-4 `feDropShadow`**：blur + offset + flood + merge 的复合原语，复用既有模糊与合并实现。
- **M5-P2-5 `transform-origin` / `transform-box`**：长度 / 百分比 / 关键字原点，`view-box` / `fill-box` 参考盒；矩阵变为 `T(origin) × M × T(-origin)`。
- **M5-P2-6 `context-fill` / `context-stroke`**：`use` 实例内解析为被引用元素的画笔，无上下文回退 `none`。

**P3 文本整形**

- **M5-P3-1 字距调整**：`kern` format 0 与 `GPOS` Pair Adjustment format 1/2，仅 x advance。
- **M5-P3-2 标准连字**：`GSUB` Lookup Type 4 format 1（`liga`）。
- **M5-P3-3 双向文本**：UAX#9 子集（L / R / AL / EN / AN / WS / ON / B），按段落方向分段重排。
- **M5-P3-4 `direction` / `unicode-bidi`**：`ltr` / `rtl`；`normal` / `embed` / `bidi-override`。
- **M5-P3-5 `font-kerning`**：`auto` / `normal` / `none`，缺省 `auto`（有表时启用）。

**P4 元素级 API**

- **M5-P4-1 `SvgElement.getBBox(options!)`**：用户空间包围盒，支持 `stroke` / `clipped` / `fonts` 选项。
- **M5-P4-2 `SvgElement.getCTM()`**：元素到根用户空间矩阵。
- **M5-P4-3 `SvgElement.getScreenCTM(viewport!)`**：元素到设备空间矩阵（含 DPR）。
- **M5-P4-4 `SvgPath.getTotalLength()` / `getPointAtLength(d)`**：复用 `SvgPathData` 的弧长实现。
- **M5-P4-5 `getElementsByClassName()` / `querySelectorAll()`**：复用 P1 选择器引擎，按文档顺序返回。

## Capabilities

### New Capabilities

无。M5 的全部行为归入既有能力域；元素级 API 是既有几何与文档模型的增量，不为同一概念新建近似重复的 spec。

### Modified Capabilities

- `svg-css`：改写「CSS 规则集解析」与「选择器模型与匹配」两条既有要求（从拒绝 `@media` / 伪类 / 属性选择器 / 兄弟组合器改为支持），新增属性选择器、结构伪类、`@media`、`@font-face`、CSS 变量、`calc()` 与 M5 属性注册要求。
- `svg-value-types`：新增混合模式、绘制顺序、变换参考盒、文本方向与字距枚举及其字符串回退规则。
- `svg-text`：改写「文本布局」与「M3 文本边界」两条既有要求（整形后的字形序列、基础双向文本），新增 `kern` / `GPOS` / `GSUB`、双向重排、`direction` / `unicode-bidi` / `font-kerning` 与字体别名要求。
- `svg-geometry`：新增元素级 `getBBox`、`getCTM` / `getScreenCTM` 与路径长度薄封装要求。
- `svg-document-model`：新增元素查询 API 与 `feDropShadow` 类型化原语要求。
- `svg-render-pipeline`：新增 `paint-order` 命令顺序、混合 / 隔离的合成位置、`transform-origin` 应用顺序与媒体宽度来源要求。
- `svg-paint-and-clip`：新增混合模式 / 隔离组的合成语义与 `context-fill` / `context-stroke` 解析要求。
- `svg-rasterization`：新增混合模式的预乘 RGBA 像素公式与钳制要求。
- `svg-filter`：新增 `feDropShadow` 原语行为要求。
- `svg-security`：新增 M5 上限表（CSS 变量 / `calc()` / 选择器长度 / `kern` / `GPOS` / `GSUB` / 连字）及超限降级方式。

## Impact

- **Affected code**（全部位于 `f_svg/src` 单包，不新建模块、子包或依赖）：
  - 新增 `CssSelector2.cj`、`CssMedia.cj`、`CssVariables.cj`、`CssCalc.cj`、`SvgBlend.cj`、`SvgPaintOrder.cj`、`SvgTransformOrigin.cj`、`SvgContextPaint.cj`、`SvgOpenTypeLayout.cj`、`SvgBidi.cj`、`SvgElementApi.cj` 及对应 `*_test.cj`；
  - 修改 `CssSelector.cj`、`CssStyleSheet.cj`、`CssLexer.cj`（如需要）、`SvgStyleResolver.cj`、`SvgComputedStyle.cj`（选择器、`@media`、`@font-face`、变量、`calc()`、新属性）、`SvgTag.cj` / `SvgBuilder.cj`（`feDropShadow`）、`SvgElement.cj`（元素 API）、`SvgPath.cj`（长度 API）、`SvgGeometry.cj`（可选样式上下文的 CTM / 屏幕 CTM）、`SvgRenderTree.cj`（`paint-order` / 混合 / 隔离 / 原点）、`SvgRenderer.cj` / `SvgClipMask.cj`（隔离层与混合合成）、`SvgTextRenderer.cj`（整形、bidi、方向属性）、`SvgFont.cj`（别名注册、整形侧接口）、`SvgTrueTypeFont.cj` / `SvgTrueTypeTables.cj`（`kern` / `GPOS` / `GSUB`）、`SvgFilterRenderer.cj` / `SvgFilterPrimitive.cj`（`feDropShadow`）、`SvgPaint.cj`（`context-*`）；
  - `f_svg/testdata/render/` 新增 `m5-*` 场景与期望图；`f_svg/testdata/fonts/` 新增含 `kern` / `GPOS` / `GSUB` 的最小 TTF fixture 与损坏 / 超限 fixture；
  - 更新 `f_svg/README.md` / `README_en.md`、`f_svg/doc/perf-baseline.md` 与包注释。
- **公开 API 增量**：
  - `SvgElement` 新增 `getBBox` / `getCTM` / `getScreenCTM` / `getElementsByClassName` / `querySelectorAll`；`SvgPath` 新增 `getTotalLength` / `getPointAtLength`；
  - `CssSelectorPart` 新增 `simples` 复合视图，既有 `typeName` / `id` / `classes` 字段保留并保持原语义；`CssCombinator` 新增 `AdjacentSibling` / `GeneralSibling`；
  - `CssStyleSheet` 新增 `fontFaces`；`SvgStyleResolver` 新增可选媒体宽度入口；`SvgFontRegistry` 新增别名与派生入口；
  - `SvgPaintKind` 新增 `ContextFill` / `ContextStroke`（既有构造器语义不变；下游对 `SvgPaintKind` 的穷尽 `match` 需补分支）；
  - `SvgGeometry.ctm` / `screenCTM` 新增可选计算样式上下文重载，原签名行为不变。
- **兼容性**：
  - 所有新属性 / 新选择器只在文档实际声明时生效；未声明时输出与 M4 逐字节一致；
  - `paint-order` 缺省 `fill stroke markers`、`mix-blend-mode` 缺省 `normal`、`isolation` 缺省 `auto`、`transform-origin` 缺省 `0 0`、`transform-box` 缺省 `view-box`、`font-kerning` 缺省 `auto` 但仅在字体含表时生效；
  - 不修改 `f_xml` / `f_base` 公开 API、根 `cjpm.toml`、`.modules` 与聚合根 shim；`f_svg/cjpm.toml` 不新增依赖。
- **验收锚点**：既有 710 条用例中 708 条保持不变；`CssStyleSheet_test.atRulesAreSkipped` 与 `unsupportedSelectorsAreSkipped` 编码的是 M2「`@media` / `@font-face` / 属性选择器一律跳过」的旧契约，按本变更的 MODIFIED 要求改写，不视为回归；M1–M3 的 13 张与 M4 的 4 张快照逐字节一致；每个 Requirement 至少 1 个可执行 Scenario；选择器、`@media`、变量、`calc()`、混合、`feDropShadow`、`transform-origin`、整形、bidi、元素 API 均有独立断言；所有上限有负向用例；`cjpm test` 全绿且 `f_svg` 自身 0 warning；`openspec validate --strict` 通过。

## Non-goals

- CSS 动画 / 过渡、`@supports`、`@layer`、`@container`、伪元素（`::before` / `::after`）。
- 阿拉伯 / 印度系复杂脚本整形、上下文替换（GSUB Type 5/6）、竖排连字、完整 UAX#9 行级重排。
- `mix-blend-mode: plus-lighter` 与 CSS 颜色空间混合；GPU 后端。
- 外部 URL 资源、`foreignObject`、脚本 / 事件、JPEG / WebP / GIF（沿用 M1–M4 边界）。
- 浏览器逐像素一致；只保证设计文档定义的 SVG 2 / OpenType 子集语义与自有快照稳定。
