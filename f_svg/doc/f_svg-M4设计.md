# f_svg M4 —— 渲染保真 / 文本排版 / 文档与 API

> 定位：M4 补齐 M1–M3 之后仍缺失的 SVG 1.1 常用能力，按 **A 渲染保真 → B 文本排版 → C 文档与 API** 顺序实施。
> 一个 OpenSpec 变更 `add-f-svg-m4` 覆盖三个包；只增不改 M1–M3 公开 API 语义，默认渲染输出保持逐字节一致。

## 0. M4 特性清单

### A 包：渲染保真

| 编号 | 特性 | 说明 |
|---|---|---|
| M4-A1 | `clip` 属性 | `clip: rect(t, r, b, l)` / `auto`，用户空间矩形裁剪；`auto` 不裁剪 |
| M4-A2 | `overflow` 裁剪 | `symbol` / `marker` / `pattern` / 嵌套 `svg` 的 `overflow`（`hidden` 默认）裁剪到视口 |
| M4-A3 | `vector-effect` | `non-scaling-stroke`：描边宽度按设备空间计算，不随变换缩放 |
| M4-A4 | 组件传递 | `feComponentTransfer` + `feFuncR/G/B/A`（`identity` / `table` / `discrete` / `linear` / `gamma`） |
| M4-A5 | 形态学 | `feMorphology`（`erode` / `dilate`，矩形核） |
| M4-A6 | 卷积 | `feConvolveMatrix`（`order` / `kernelMatrix` / `divisor` / `bias` / `targetX` / `targetY` / `edgeMode`） |
| M4-A7 | 湍流 | `feTurbulence`（`fractalNoise` / `turbulence`、`baseFrequency`、`numOctaves`、`seed`、`stitchTiles`） |
| M4-A8 | 位移 | `feDisplacementMap`（`scale` / `xChannelSelector` / `yChannelSelector`） |
| M4-A9 | 图像原语 | `feImage`（仅 `data:image/png` 与注入 provider，复用 M3 图像资源） |
| M4-A10 | 光照 | `feDiffuseLighting` / `feSpecularLighting` + `feDistantLight` / `fePointLight` / `feSpotLight` |
| M4-A11 | `pattern` 视口 | `pattern` 的 `viewBox` / `preserveAspectRatio`，内容按视口映射到 tile |

### B 包：文本排版

| 编号 | 特性 | 说明 |
|---|---|---|
| M4-B1 | 基线 | `dominant-baseline` / `alignment-baseline` / `baseline-shift`（长度、百分比、`baseline` / `sub` / `super`） |
| M4-B2 | 装饰线 | `text-decoration`（`underline` / `overline` / `line-through` / `none`），颜色取 `fill`，厚度与偏移确定性定义 |
| M4-B3 | 书写模式 | `writing-mode: lr-tb` / `tb-rl` / `tb`，竖排逐列从右到左，字形旋转 90° |
| M4-B4 | `textPath` 扩展 | `side`（`left` / `right`）、`method`（`align` / `stretch`）、`spacing`（`auto` / `exact`） |
| M4-B5 | TrueType 字体 | `SvgTrueTypeFont`：解析 `cmap`（4/12）、`glyf`（简单 + 复合）、`hmtx`、`head`、`hhea`、`maxp`、`loca`；CFF/OTF 记 warning 回退 |

### C 包：文档与 API

| 编号 | 特性 | 说明 |
|---|---|---|
| M4-C1 | `view` 元素 | `SvgView` 类型化元素；`SvgDocument.views()` / `view(id)`；`viewBox` + `preserveAspectRatio` 解析 |
| M4-C2 | `switch` 条件 | `requiredFeatures` / `requiredExtensions` / `systemLanguage` 求值；`SvgRenderOptions.languages` 控制语言匹配 |
| M4-C3 | `a` 链接模型 | `SvgDocument.anchors()` 返回 `(element, href, target)`；渲染仍按容器；不联网、不触发导航 |
| M4-C4 | 路径长度 API | `SvgPathData.totalLength(tolerance!)`、`pointAtLength(distance, tolerance!)` |
| M4-C5 | 变换 API | `SvgGeometry.ctm(element)`（元素 → 根用户空间）、`SvgGeometry.screenCTM(element, viewport)` |

### M4 明确不做

- `<script>`、`on*` 事件、链接激活与交互、`:hover`；
- 外部 URL 资源（`feImage` 也只接受 `data:` 与 provider）；
- `foreignObject` 内部 XHTML；
- SVG Fonts（`font` / `glyph` / `hkern`）、`altGlyph*`、`tref`；
- `cursor`、`color-profile`、ICC 颜色管理；
- CSS 属性选择器/伪类/`@media`/CSS 动画；
- GPU 后端。

## 1. 与既有里程碑的关系

| 层 | M1 | M2 | M3 | M4 |
|---|---|---|---|---|
| 模型 | 值类型 + DOM | — | filter/pattern/marker/fe* | `view`、`feFunc*`、光源、`text-decoration` 等属性 |
| 渲染 | — | CSS + 光栅 + PNG + 动画 | 滤镜/图案/位图/SVGZ/textPath/marker/AA | clip/overflow/vector-effect、7 类原语、pattern viewBox |
| 文本 | — | Hershey + 可插拔字体 | textPath + rotate | 基线/装饰/竖排/TTF |
| API | 模型与值 | 渲染/动画 | 图像/滤镜 | 长度/变换/锚点/视图 |

**兼容性约束**

- `SvgRenderOptions` 只新增带默认值字段（`languages`），默认输出与 M3 逐字节一致；
- `SvgPathData.totalLength` / `pointAtLength` 为新增方法，不改既有签名；
- `SvgDocument.views()` / `anchors()` 为新增查询，不改文档结构；
- `clip`、`overflow`、`vector-effect`、基线、装饰、书写模式在**未设置**时行为不变。

## 2. A 包：渲染保真

### 2.1 `clip` 属性（M4-A1）

- 解析 `clip: rect(<top>, <right>, <bottom>, <left>)`，四个分量支持长度与 `auto`；`auto` 表示该边不裁剪；
- 坐标系为用户空间，按元素当前 CTM 变换后裁剪；
- 与 `clip-path` 同时存在时：先应用 `clip` 矩形，再应用 `clip-path`；
- 非法值记 warning 并忽略；
- 仅对已渲染的图形/文本/图像/组生效（CSS 规范限定 viewport 元素，本模块放宽到任意元素并在文档中说明）。

**测试**：矩形四边裁剪；`auto` 单边；旋转 45° 下的裁剪；非法值 warning；与 `clip-path` 叠加。

### 2.2 `overflow`（M4-A2）

- `symbol` / `marker` / `pattern` / 嵌套 `svg`：`overflow` 缺省 `hidden`，按视口矩形裁剪；`visible` 不裁剪；
- `marker` 的视口为 `markerWidth × markerHeight`；
- 裁剪在内容坐标系内完成，再参与外层合成。

**测试**：默认裁剪 marker 溢出；`visible` 不裁剪；`symbol` 嵌套 `use` 裁剪。

### 2.3 `vector-effect`（M4-A3）

- 支持 `none`（默认）与 `non-scaling-stroke`；
- 公开 API 为 `SvgVectorEffect.NoEffect` / `SvgVectorEffect.NonScalingStroke`，以类 + 静态属性建模，避免与 `Option.None` 的枚举构造器同名；字符串形式仍为 `none` / `non-scaling-stroke`；
- `non-scaling-stroke` 时描边宽度按设备空间计算：`deviceWidth = strokeWidth`，换算到用户空间时除以 CTM 的平均缩放 `sqrt(|det|)`；
- 虚线长度同样按设备空间解释；
- 其他取值记 warning 并按 `none` 处理。

**测试**：`scale(2)` 下描边宽度不变；`scale(2,1)` 用几何平均；虚线段长不缩放。

### 2.4 新增滤镜原语（M4-A4 ~ M4-A10）

| 原语 | 参数 | 算法 |
|---|---|---|
| `feComponentTransfer` | `feFuncR/G/B/A` 的 `type` + `tableValues` / `slope` / `intercept` / `amplitude` / `exponent` / `offset` | 逐通道查表/线性/gamma，结果钳制 |
| `feMorphology` | `operator`（erode/dilate）、`radius` | 矩形核的局部最小/最大；半径按 `primitiveUnits` 换算 |
| `feConvolveMatrix` | `order`、`kernelMatrix`、`divisor`、`bias`、`targetX`、`targetY`、`edgeMode`、`preserveAlpha` | 可分离性不做假设，直接二维卷积；`edgeMode` 支持 duplicate/wrap/none |
| `feTurbulence` | `baseFrequency`、`numOctaves`、`seed`、`stitchTiles`、`type` | Perlin 风格噪声，`seed` 决定确定性；输出 RGBA（噪声值映射到 0–255） |
| `feDisplacementMap` | `scale`、`xChannelSelector`、`yChannelSelector` | 用 `in2` 的选定通道偏移 `in` 的采样坐标 |
| `feImage` | `href` / `preserveAspectRatio` | 仅 `data:image/png` 与 provider；资源不可用输出透明 + warning |
| `feDiffuseLighting` / `feSpecularLighting` | `surfaceScale`、`diffuseConstant`、`specularConstant`、`specularExponent`、`lighting-color` + 光源子元素 | 由 alpha 计算法线，Lambert / Blinn-Phong；光源支持 distant/point/spot |

**共同要求**：
- 所有原语输出与输入同尺寸（滤镜区域），越界按透明处理；
- 输入尺寸为 0 时输出透明 + warning；
- 参数非法（非有限、维度不符、核大小超限）→ warning + 该原语直通或输出透明；
- `feConvolveMatrix` 的 `order` 上限 9×9；`feTurbulence` 的 `numOctaves` 上限 8；
- `feImage` 与 `<image>` 共享解码预算。

### 2.5 `pattern` 视口（M4-A11）

- `viewBox` + `preserveAspectRatio` 定义 tile 内容坐标系；
- 有 `viewBox` 时 `patternContentUnits` 被忽略（按 SVG 1.1）；
- tile 尺寸仍由 `width` / `height` 与 `patternUnits` 决定；
- 视口映射复用 `SvgViewport`。

**测试**：`viewBox="0 0 10 10"`、tile 20×20 → 内容放大 2 倍；`slice` 裁剪；无 `viewBox` 时行为不变。

## 3. B 包：文本排版

### 3.1 基线（M4-B1）

- `dominant-baseline`：`auto` / `alphabetic` / `ideographic` / `middle` / `central` / `hanging` / `mathematical` / `text-before-edge` / `text-after-edge`；
- `alignment-baseline`：`auto` / `baseline` / `before-edge` / `text-before-edge` / `middle` / `central` / `after-edge` / `text-after-edge` / `ideographic` / `alphabetic` / `hanging` / `mathematical`；
- `baseline-shift`：长度、百分比（相对 `font-size`）、`baseline` / `sub` / `super`；
- 计算顺序：基线表 → `dominant-baseline` 偏移 → `baseline-shift`；
- 字体需提供 `ascent` / `descent` / `unitsPerEm`；Hershey 用固定比例（ascent 0.8、descent 0.2）。

**测试**：五种基线的 y 偏移；`sub` / `super`；`baseline-shift="10%"`；无字体度量时回退。

### 3.2 装饰线（M4-B2）

- `text-decoration` 支持 `none` / `underline` / `overline` / `line-through` 及组合；
- 颜色取当前 `fill`（渐变按字形起点取样，简化）；
- 厚度 `max(1, fontSize / 14)`；下划线在基线下方 `fontSize × 0.10`，上划线在 ascent 处，删除线在 `ascent × 0.55`；
- 装饰线随字形旋转（textPath / rotate），不跨越 `tspan` 断开；
- `text-decoration` 不可继承，但祖先设置时对后代文本生效（按 SVG 语义向下传播）。

**测试**：三种装饰线像素；组合；与 `fill` 颜色一致；textPath 上随切线旋转。

### 3.3 书写模式（M4-B3）

- 支持 `lr-tb` / `lr` / `tb` / `tb-rl`；
- 竖排：字形顺时针旋转 90°，沿 y 递增排版，列沿 x 递减（从右到左）；
- `x` / `y` 语义按 SVG：`x` 为列位置，`y` 为列内起点；
- `text-anchor` 在竖排下沿列方向生效；
- 与 `textPath` 同时出现时 `writing-mode` 忽略并 warning。

**测试**：`tb-rl` 两列顺序；字形旋转角；`text-anchor="middle"` 沿列居中；与 textPath 冲突 warning。

### 3.4 `textPath` 扩展（M4-B4）

- `side="left"`：字形整体沿路径法线左移 `fontSize × 0.5`；`right` 相反；`side` 不改变切线角；
- `method="align"`（默认）按逐字 advance 排布；`method="stretch"` 把字形拉伸到路径全长（按 `textLength` 规则缩放 advance）；
- `spacing="auto"` 使用字体 advance；`spacing="exact"` 使用 `dx` / `letter-spacing` 精确位置，缺省时等同 `auto`；
- 与 `writing-mode` 冲突时忽略 `writing-mode`。

**测试**：`side` 左右偏移像素；`stretch` 覆盖全长；`exact` 下 `dx` 生效。

### 3.5 TrueType 字体（M4-B5）

```cangjie
public class SvgTrueTypeFont <: SvgFont {
    public static func parse(bytes: Array<Byte>): SvgTrueTypeFont
    public static func load(path: Path): SvgTrueTypeFont
    public prop unitsPerEm: Int64
    public prop ascent: Float64
    public prop descent: Float64
    public func advance(codePoint: Int64, fontSize: Float64): Float64
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData
    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds
}
```

- 支持 TrueType 轮廓（`glyf` 简单 + 复合，复合递归深度 ≤ 8）；CFF/OTF 抛 `Unsupported`；
- `cmap` 支持 format 4 与 12；
- 坐标按 `unitsPerEm` 缩放到 `fontSize`，y 轴翻转（字体 y 向上 → SVG y 向下）；
- 二次贝塞尔转为 `Q` 命令；复合字形按 `ARG_1_AND_2_ARE_WORDS` / `ARGS_ARE_XY_VALUES` / `MORE_COMPONENTS` 组合；
- 安全：表数 ≤ 64、单表长度 ≤ 16 MiB、`glyf` 单字形点数 ≤ 10000、复合深度 ≤ 8、`loca` 单调；
- 不解析 hinting、`GSUB` / `GPOS` / `kern`（字距为 0，除 `hmtx` advance）。

**测试**：内置最小 TTF 字节 fixture（手工构造，覆盖简单字形 + 复合字形 + cmap4）；advance/路径/包围盒；截断表、超限字形、CFF 拒绝。

## 4. C 包：文档与 API

### 4.1 `view`（M4-C1）

```cangjie
public class SvgView <: SvgElement {
    public mut prop viewBox: ?SvgViewBox
    public mut prop preserveAspectRatio: SvgPreserveAspectRatio
    public mut prop viewTarget: ?String
}
```

- `SvgDocument.views(): ArrayList<SvgView>` 按文档顺序返回；
- `SvgDocument.view(id): ?SvgView` 按 id 查找；
- 提供 `SvgViewport.forView(view, viewportWidth, viewportHeight)` 计算视口变换；
- 不实现片段导航（`url(#view)` 的初始视图）；仅模型与换算 API。

**测试**：解析/往返；`views()` 顺序；`forView` 三档 `preserveAspectRatio`。

### 4.2 `switch` 条件（M4-C2）

- 按子元素顺序求值，选择第一个满足条件的元素；全部不满足时渲染空；
- `requiredFeatures`：逗号/空格分隔，支持 `http://www.w3.org/TR/SVG11/feature#Shape` 等已知特性字符串；未知特性视为不满足；
- `requiredExtensions`：非空即不满足（本模块无扩展）；
- `systemLanguage`：与 `SvgRenderOptions.languages` 做前缀匹配（`zh` 匹配 `zh-CN`），缺省为 `["en"]`；
- 无任何条件属性时视为满足；
- 选中元素的 `display="none"` 仍跳过并继续尝试下一个。

**测试**：语言匹配选择；未知扩展跳过；已知特性通过；全部不满足为空；`display` 交互。

### 4.3 `a` 链接模型（M4-C3）

- `a` 仍为 `SvgContainer`（不改既有类型）；
- 新增 `SvgDocument.anchors(): ArrayList<SvgAnchorInfo>`，含 `element` / `href` / `target`；
- 渲染行为不变；不联网、不触发导航、不执行事件；
- `href` 外部形式在解析期按既有安全策略处理（默认移除）。

**测试**：`anchors()` 返回嵌套顺序与 href/target；外部 href 默认不出现；`target` 缺省为空。

### 4.4 路径长度 API（M4-C4）

```cangjie
public func totalLength(tolerance!: Float64 = 0.25): Float64
public func pointAtLength(distance: Float64, tolerance!: Float64 = 0.25): SvgPoint
```

- 按扁平化容差把各段离散为折线并累加长度；
- `pointAtLength` 对负值钳制到起点、超长钳制到终点；
- 弧段用中心参数化后按容差细分；
- 结果与 `textPath` 使用同一套弧长逻辑，保证一致。

**测试**：直线/折线/圆/弧的长度；中点坐标；负值与超长；容差变小结果收敛。

### 4.5 变换 API（M4-C5）

```cangjie
public static func ctm(element: SvgElement): SvgMatrix
public static func screenCTM(element: SvgElement, viewport: SvgViewportTransform): SvgMatrix
```

- `ctm` 从根到元素累乘 `transform` 与嵌套 `svg` 的 `viewBox` 变换；
- `screenCTM` 再乘视口变换（`viewBox` + `preserveAspectRatio` + DPR），顺序为
  `scale(dpr) × viewport.matrix × ctm`，与渲染树一致；
- 不含 `use` 实例化产生的额外变换（文档中说明）。

**测试**：嵌套 `g` 的 CTM；嵌套 `svg` 的 viewBox；`screenCTM` 与渲染坐标一致。

## 5. 模块布局

新增源文件（均位于 `f_svg/src`，单包）：

| 文件 | 职责 |
|---|---|
| `SvgClipProperty.cj` | `clip` 属性解析与矩形裁剪 |
| `SvgOverflow.cj` | `overflow` 视口裁剪 |
| `SvgVectorEffect.cj` | `non-scaling-stroke` 宽度换算 |
| `SvgFilterPrimitives2.cj` | 新增 7 类原语实现 |
| `SvgFilterLighting.cj` | 光照模型与三种光源 |
| `SvgTrueTypeFont.cj` / `SvgTrueTypeTables.cj` | TTF 解析与字形轮廓 |
| `SvgTextBaseline.cj` | 基线表与 `baseline-shift` |
| `SvgTextDecoration.cj` | 装饰线几何 |
| `SvgTextWritingMode.cj` | 竖排布局 |
| `SvgView.cj` | `view` 元素与视口换算 |
| `SvgSwitch.cj` | 条件求值 |
| `SvgAnchor.cj` | `anchors()` 模型 |
| `SvgPathMeasure.cj` | 长度与取点 |

现有文件改动：`SvgTag.cj`（新标签）、`SvgBuilder.cj`（属性白名单）、`SvgStyleResolver.cj`（新属性）、`SvgRenderTree.cj`（clip/overflow/vector-effect/switch）、`SvgRenderer.cj`（描边与滤镜）、`SvgTextRenderer.cj`（基线/装饰/竖排/textPath 扩展）、`SvgDocument.cj`（views/anchors）、`SvgOptions.cj`（languages）、`SvgPathData.cj`（长度 API）、`SvgGeometry.cj`（CTM API）。

## 6. 安全与上限

| 项 | 默认上限 | 超限 |
|---|---|---|
| 卷积核 `order` | 9 × 9 | `Limit` |
| 湍流 `numOctaves` | 8 | `Limit` |
| 形态学像素半径 | 16 | `Limit` |
| 形态学采样量 | `区域像素 × (2rx+1)(2ry+1) ≤ 64 × 1024 × 1024` | `Limit` |
| TTF 表数 | 64 | `Limit` |
| TTF 单表长度 | 16 MiB | `Limit` |
| TTF 单字形点数 | 10000 | `Limit` |
| TTF 复合深度 | 8 | `Limit` |
| `feImage` 解码 | 与 `<image>` 共享预算 | `Limit` |
| `switch` 子元素数 | 不额外限制（受 `maxElements` 约束） | — |

## 7. 验收判据

- M1–M3 的 533 条用例零回归，M1/M2 六场景逐字节一致；
- 每个 Requirement 至少 1 个可执行 Scenario；
- `cjpm test` 全绿，`f_svg` 自身 0 warning；
- 滤镜新原语、TTF 字形、基线/装饰/竖排、clip/overflow/vector-effect 均有像素或几何断言；
- 所有上限有负向用例；
- `openspec validate --strict` 通过。

## 8. 实施顺序

1. A1–A3：`clip` / `overflow` / `vector-effect`（渲染树 + 光栅）；
2. A4–A10：七类滤镜原语与光照；
3. A11：`pattern` 的 `viewBox`；
4. B1–B2：基线与装饰线；
5. B3–B4：竖排与 `textPath` 扩展；
6. B5：TrueType 字体；
7. C1–C3：`view` / `switch` / `anchors`；
8. C4–C5：路径长度与 CTM API；
9. 文档、样本、基准、验收。

## 9. 已定契约

- 未设置新属性时输出与 M3 逐字节一致；
- `SvgRenderOptions` 只新增 `languages`（默认 `["en"]`）；
- TTF 只支持 TrueType 轮廓，CFF/OTF 抛 `Unsupported` 并由调用方回退；
- `feImage` 不联网、不读任意文件，只接受 `data:` 与 provider；
- `switch` 的条件求值在渲染期完成，不修改文档；
- `SvgPathData.totalLength` / `pointAtLength` 与 `textPath` 共用同一弧长实现。
