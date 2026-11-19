# add-f-svg-m4

## Why

M1–M3 已让 `fountain::f_svg` 覆盖 SVG 1.1 的模型、CSS、几何、CPU 光栅、滤镜框架、图案、位图、SVGZ、textPath 与 marker。但真实素材仍会在三处静默失真：

- **渲染保真**：`clip` / `overflow` / `vector-effect` 未实现，7 类常用滤镜原语（分量传递、形态学、卷积、湍流、位移、图像、光照）缺失，`pattern` 没有 `viewBox`，矢量素材的裁剪、描边与效果被丢掉；
- **文本排版**：基线、装饰线、竖排、`textPath` 的 `side` / `method` / `spacing` 不支持，也没有 TrueType 字体解析，中文与排版型素材只能回退占位；
- **文档与 API**：`view`、`switch` 条件、`a` 链接查询、路径长度与 CTM 查询缺失，调用方无法做命中测试、布局换算与分视图导出。

M4 按 `f_svg/doc/f_svg-M4设计.md` 收口这三类剩余能力。只增不改 M1–M3 公开 API 语义，不新增模块、子包或第三方依赖，默认渲染输出与 M3 保持一致。

## What Changes

**A 包：渲染保真**

- **M4-A1 `clip` 属性**：解析 `clip: rect(t, r, b, l)`（四边支持长度与 `auto`），用户空间矩形裁剪；与 `clip-path` 叠加时先 `clip` 后 `clip-path`；非法值 warning 并忽略。
- **M4-A2 `overflow` 裁剪**：`symbol` / `marker` / `pattern` / 嵌套 `svg` 的视口裁剪，缺省 `hidden`，`visible` 放行；marker 视口为 `markerWidth × markerHeight`。
- **M4-A3 `vector-effect`**：`non-scaling-stroke` 按设备空间解释描边宽度与虚线长度，换算系数为 CTM 平均缩放 `sqrt(|det|)`；其他取值 warning 并按 `none` 处理。
- **M4-A4 `feComponentTransfer` + `feFuncR/G/B/A`**：`identity` / `table` / `discrete` / `linear` / `gamma` 五种传递函数，逐通道计算并钳制。
- **M4-A5 `feMorphology`**：`erode` / `dilate` 的矩形核局部极值，半径按 `primitiveUnits` 换算。
- **M4-A6 `feConvolveMatrix`**：二维卷积，支持 `order` / `kernelMatrix` / `divisor` / `bias` / `targetX` / `targetY` / `edgeMode` / `preserveAlpha`，`order` 上限 9×9。
- **M4-A7 `feTurbulence`**：`fractalNoise` / `turbulence` 两类 Perlin 风格噪声，`seed` 保证确定性，`numOctaves` 上限 8。
- **M4-A8 `feDisplacementMap`**：按 `in2` 选定通道偏移 `in` 的采样坐标。
- **M4-A9 `feImage`**：仅接受 `data:image/png` 与注入 `SvgImageResourceProvider`，复用 M3 解码预算；不可用时透明 + warning。
- **M4-A10 `feDiffuseLighting` / `feSpecularLighting`**：由 alpha 求法线的 Lambert / Blinn-Phong 光照，配 `feDistantLight` / `fePointLight` / `feSpotLight`。
- **M4-A11 `pattern` 视口**：`viewBox` + `preserveAspectRatio` 定义 tile 内容坐标系，有 `viewBox` 时忽略 `patternContentUnits`。

**B 包：文本排版**

- **M4-B1 基线**：`dominant-baseline` / `alignment-baseline` / `baseline-shift`（长度、百分比、`baseline` / `sub` / `super`），按「基线表 → dominant 偏移 → baseline-shift」计算。
- **M4-B2 装饰线**：`text-decoration` 的 `underline` / `overline` / `line-through` / `none` 与组合，颜色取 `fill`，厚度与偏移按确定性公式，随字形旋转。
- **M4-B3 书写模式**：`writing-mode: lr-tb` / `tb` / `tb-rl`，竖排逐列从右到左、字形顺时针旋转 90°，`text-anchor` 沿列生效。
- **M4-B4 `textPath` 扩展**：`side`（`left` / `right`）、`method`（`align` / `stretch`）、`spacing`（`auto` / `exact`）。
- **M4-B5 TrueType 字体**：`SvgTrueTypeFont` 解析 `cmap`(4/12) / `glyf`（简单 + 复合）/ `hmtx` / `head` / `hhea` / `maxp` / `loca`，CFF/OTF 抛 `Unsupported`。

**C 包：文档与 API**

- **M4-C1 `view` 元素**：`SvgView` 类型化元素，`SvgDocument.views()` / `view(id)`，`SvgViewport.forView` 计算视口变换。
- **M4-C2 `switch` 条件**：按子元素顺序求值 `requiredFeatures` / `requiredExtensions` / `systemLanguage`，`SvgRenderOptions.languages` 控制语言匹配。
- **M4-C3 `a` 链接模型**：`SvgDocument.anchors()` 返回 `(element, href, target)`，渲染仍按容器，不联网、不导航。
- **M4-C4 路径长度 API**：`SvgPathData.totalLength(tolerance!)`、`pointAtLength(distance, tolerance!)`，与 `textPath` 共用同一弧长实现。
- **M4-C5 变换 API**：`SvgGeometry.ctm(element)` 与 `screenCTM(element, viewport)`。

## Capabilities

### New Capabilities

无。M4 的全部行为都归入既有能力域，避免为同一概念拆分近似重复的 spec。

### Modified Capabilities

- `svg-filter`：新增 7 类滤镜原语与光照模型、新的图连接参数与上限。
- `svg-text`：新增基线、装饰线、书写模式、`textPath` 三个新属性与 TrueType 字体；改写「`side` 被忽略」的既有要求。
- `svg-document-model`：新增 `view` 类型化元素、`views()` / `view(id)`、`anchors()` 查询与 `SvgAnchorInfo`。
- `svg-paint-and-clip`：新增 `clip` 属性与视口 `overflow` 裁剪语义，`pattern` 增加 `viewBox` / `preserveAspectRatio`。
- `svg-rasterization`：新增 `vector-effect: non-scaling-stroke` 的描边宽度与虚线换算。
- `svg-render-pipeline`：新增 `switch` 条件求值、效果展开顺序中的 `clip` / `overflow` / `vector-effect`、`SvgRenderOptions.languages`。
- `svg-geometry`：新增路径长度测量（`totalLength` / `pointAtLength`）与 `ctm` / `screenCTM`。
- `svg-css`：注册 M4 新属性及其继承性与初始值，扩展值归一化与非法值降级。
- `svg-value-types`：新增 M4 枚举与值类型（书写模式、基线、装饰线、`vector-effect`、`overflow`、滤镜参数枚举等）。
- `svg-security`：新增 M4 上限表（卷积核、湍流倍频、TTF 表数 / 表长 / 点数 / 复合深度、`feImage` 预算）。

## Impact

- **Affected code**（全部位于 `f_svg/src` 单包，不新建模块或子包）：
  - 新增 `SvgClipProperty.cj`、`SvgOverflow.cj`、`SvgVectorEffect.cj`、`SvgFilterPrimitives2.cj`、`SvgFilterLighting.cj`、`SvgTrueTypeFont.cj`、`SvgTrueTypeTables.cj`、`SvgTextBaseline.cj`、`SvgTextDecoration.cj`、`SvgTextWritingMode.cj`、`SvgView.cj`、`SvgSwitch.cj`、`SvgAnchor.cj`、`SvgPathMeasure.cj` 及对应 `*_test.cj`；
  - 修改 `SvgTag.cj`（`view` / 新 `fe*` 标签）、`SvgBuilder.cj`（元素分派与校验）、`SvgStyleResolver.cj` / `SvgComputedStyle.cj`（新属性）、`SvgRenderTree.cj`（`clip` / `overflow` / `vector-effect` / `switch`）、`SvgRenderer.cj`（描边与滤镜分派）、`SvgFilterRenderer.cj`（原语注册）、`SvgPatternSampler.cj`（`viewBox`）、`SvgMarkerExpander.cj`（视口裁剪）、`SvgTextRenderer.cj`（基线 / 装饰 / 竖排 / textPath 扩展）、`SvgTextPathLayout.cj`（复用路径测量）、`SvgTextPath.cj`（`side` / `method` / `spacing`）、`SvgDocument.cj`（`views` / `anchors`）、`SvgOptions.cj` / `SvgBitmap.cj`（`languages`）、`SvgPathData.cj`（长度 API）、`SvgGeometry.cj` / `SvgViewport.cj`（CTM / 视图 API）；
  - `f_svg/testdata/render/` 新增 `m4-*` 场景与期望图；`f_svg/testdata/fonts/` 新增手工构造的最小 TTF fixture 与损坏 / 超限 fixture；
  - 更新 `f_svg/README.md` / `README_en.md`、`f_svg/doc/perf-baseline.md` 与包注释。
- **不修改**：M1–M3 的公开方法签名与字段语义；`f_xml` / `f_base` 公开 API；根 `cjpm.toml`、`.modules`、聚合根 shim；`f_svg/cjpm.toml` 不新增依赖。
- **兼容性**：
  - `SvgRenderOptions` 只新增 `languages: Array<String> = ["en"]`；
  - `SvgPathData` / `SvgGeometry` / `SvgDocument` 只新增方法或查询，不改既有签名与文档结构；
  - `clip`、`overflow`、`vector-effect`、基线、装饰、书写模式在未声明时按 M3 语义输出；`overflow` 的缺省 `hidden` 只影响内容越出 marker / symbol / pattern 视口的文档（M1–M3 的 6 个场景与 M3 的 5 个快照不含该情形，保持逐字节一致）；
  - 现有 533 条用例零回归，`f_svg` 自身 0 warning。
- **验收锚点**：每个 Requirement 至少一个可执行 Scenario；滤镜新原语、TTF 字形、基线 / 装饰 / 竖排、`clip` / `overflow` / `vector-effect` 均有像素或几何断言；所有上限均有负向用例；`cjpm test` 全绿，`openspec validate --strict` 通过。

## Non-goals

- `<script>`、`on*` 事件、链接激活与交互、`:hover`。
- 外部 URL 资源；`feImage` 也只接受 `data:` 与 provider。
- `foreignObject` 内部 XHTML。
- SVG Fonts（`font` / `glyph` / `hkern`）、`altGlyph*`、`tref`。
- `cursor`、`color-profile`、ICC 颜色管理。
- CSS 属性选择器 / 伪类 / `@media` / CSS 动画。
- GPU 后端与任何新的 native 依赖。
- 浏览器逐像素一致；仅保证设计文档定义的 SVG 1.1 语义与自有快照稳定。
