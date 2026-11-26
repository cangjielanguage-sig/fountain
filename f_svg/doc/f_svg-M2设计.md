# f_svg M2 —— CSS / 几何 / 渲染 / 动画设计

> M1 已交付：值类型、类型化模型、基于 `f_xml` 的解析与生成、安全过滤、往返一致性。
> M2 在 M1 的模型之上补三件事：**CSS 级联与计算样式**、**渲染（CPU 软件光栅）**、
> **SMIL 动画**；渲染所需的**几何包围盒**与 **PNG 输出**一并落地。
> M2 仍不引入任何第三方依赖，全部基于 `f_xml`、`f_base` 与 `stdx.compress.zlib`。

---

## 0. M2 特性清单

| 编号 | 特性 | 交付物 | 依赖 |
|---|---|---|---|
| M2-1 | **CSS 解析** | `CssStyleSheet` / `CssRule` / `CssSelector`，支持元素、`.class`、`#id`、`*`、后代、子代、分组、`!important` | 无 |
| M2-2 | **级联与计算样式** | `SvgStyleResolver` / `SvgComputedStyle`：来源优先级、特异性、继承、`currentColor`、`inherit` / `initial` / `unset` | M2-1 |
| M2-3 | **几何包围盒** | `SvgBounds` / `SvgGeometry`：形状、路径（贝塞尔极值 + 弧）、描边、变换后包围盒 | M1 |
| M2-4 | **视口映射** | `SvgViewport`：`viewBox` + `preserveAspectRatio` → 用户坐标到设备坐标的矩阵 | M1/M2-3 |
| M2-5 | **光栅化核心** | `SvgBitmap` / `SvgRasterizer`：RGBA8、抗锯齿、填充规则（nonzero / evenodd）、扫描线 | M2-3/4 |
| M2-6 | **描边** | `SvgStrokeOutliner`：宽度、linecap、linejoin、miterlimit、dasharray / dashoffset | M2-3/5 |
| M2-7 | **渐变与图案** | 线性 / 径向渐变（stops、spreadMethod、gradientTransform、objectBoundingBox）；图案 M3 | M2-2/5 |
| M2-8 | **裁剪与蒙版** | `clipPath`、`mask`、组透明度、隔离组 | M2-5 |
| M2-9 | **文本渲染** | `SvgFont` 接口 + 内置 Hershey ASCII 单线字体 + 可插拔字体注册表；`text-anchor` / `dx` / `dy` / `letter-spacing` | M2-5 |
| M2-10 | **PNG 编码** | `SvgBitmap.writePng` / `toPngBytes`：zlib 包装 + Adler-32 + PNG chunk | `stdx.compress.zlib` |
| M2-11 | **SMIL 动画** | `SvgTimeline` / `SvgAnimation`：`animate` / `animateTransform` / `animateMotion` / `set`，线性/样条/离散插值 | M1/M2-2 |
| M2-12 | **渲染入口** | `SvgRenderer.render(document, options)` → `SvgBitmap`；`renderToPng` 便捷函数 | M2-5..11 |
| M2-13 | **测试与基准** | 几何数值用例、CSS 级联矩阵、光栅基元用例、动画采样、PNG 结构校验、性能基准 | 全部 |

**M2 明确不做**（M3 或永不）：

- 滤镜（`filter` / `feGaussianBlur` 等）、`foreignObject` 内部 XHTML 渲染；
- `<image>` 的 PNG/JPEG 解码（只保留属性，不绘制；M3 接图像编解码）；
- 完整 CSS3（伪类、媒体查询、`@font-face`、CSS 动画/过渡）；
- 双向文本、复杂字形整形、CJK 字体内置（通过 `SvgFont` 外部注入）；
- 流式序列化（需扩展 `f_xml::XmlWriter`，M3 单独评审）；
- 事件驱动的动画 `begin="click"`、脚本。

---

## 1. 定位与兼容性

### 1.1 与 M1 的关系

M2 是 M1 的**增量**：

- 公开 API 只增不改：M1 的 `SvgParser` / `SvgWriter` / 模型 / 值类型签名保持；
- 新增 `fountain::f_svg` 包内类型（不新建模块、不动聚合根 shim）；
- `SvgElement` 不新增公开可变字段；渲染所需的解析结果放在独立的 `SvgRenderTree` 中，
  避免把「渲染态」污染文档模型；
- 源码仍为单包 `fountain::f_svg`，新文件按前缀分组（`Css*` / `Geom*` / `Render*` / `Anim*`），
  不引入子包，保持与 `f_xml` 相同的布局约定。

### 1.2 依赖

```toml
[dependencies]
  "fountain::f_base" = {path = "../f_base"}
  "fountain::f_xml" = {path = "../f_xml"}
```

- `stdx.compress.zlib` 由仓颉 stdx 提供（与 `f_zip` 相同，不写进 `cjpm.toml`）；
- 不引入 FreeType、Skia、Cairo、PNG/JPEG 第三方库；
- 字体、图像解码都通过接口留出扩展点，核心库零 native 依赖。

### 1.3 对象生命周期

| 阶段 | 产物 | 是否可缓存 |
|---|---|---|
| 解析 | `SvgDocument`（M1） | 是 |
| 样式 | `SvgComputedStyle` 树 | 是；文档不可变时可复用 |
| 渲染树 | `SvgRenderTree`（内部） | 每次渲染构建；可按文档版本缓存 |
| 光栅 | `SvgBitmap` | 是；尺寸/时间/选项变化时失效 |
| 动画采样 | `SvgDocument` 快照 | 每个时间点独立 |

---

## 2. CSS 层（M2-1 / M2-2）

### 2.1 支持范围

**语法子集**：

- 规则集：`selectorList { declarations }`；
- 选择器：类型 `rect`、类 `.foo`、ID `#bar`、通配 `*`、复合 `rect.foo#bar`、
  后代 `g rect`、子代 `g > rect`、分组 `rect, circle`；
- 声明：`property: value;`，值原样保留为字符串，按 SVG 属性类型在计算阶段解析；
- 注释 `/* ... */`；
- `@media`、`@import`、伪类、属性选择器：**不支持**，遇到时整条规则跳过并记录 warning。

**样式来源与优先级**（从低到高）：

1. UA 默认值（`fill=black`、`stroke=none`、`opacity=1` 等）；
2. 呈现属性（`fill="red"`）；
3. `<style>` 中的规则（按特异性 + 源顺序）；
4. `style=""` 内联声明；
5. `!important` 声明（覆盖普通声明，仍按来源/特异性排序）。

**特异性**：`(id, class, type)` 三元组比较；`*` 不计；内联样式视为最高特异性
（在 `!important` 之外）；同特异性按源顺序后者胜。

**继承**：可继承属性（`fill`、`stroke`、`color`、`font-*`、`visibility`、`text-anchor` 等）
从父元素继承；不可继承属性取初始值。`inherit` / `initial` / `unset` 显式支持；
`currentColor` 在计算阶段替换为元素 `color` 的计算值。

### 2.2 API

```cangjie
public class CssStyleSheet <: ToString {
    public static func parse(text: String): CssStyleSheet
    public static func parse(text: String, warnings: ArrayList<String>): CssStyleSheet
    public let rules: Array<CssRule>
}

public class CssRule {
    public let selectors: Array<CssSelector>
    public let declarations: Array<CssDeclaration>
    public let order: Int64                 // 源顺序，用于同特异性排序
}

public class CssSelector {
    public let parts: Array<CssSelectorPart>
    public let specificity: CssSpecificity
    public func matches(element: SvgElement): Bool
}

public enum CssCombinator { | Descendant | Child }
public struct CssSpecificity { public let ids: Int64; classes: Int64; types: Int64 }

public struct CssDeclaration {
    public let property: String
    public let value: String
    public let important: Bool
}

/** 计算样式：只读快照，按属性名取值。 */
public class SvgComputedStyle {
    public func get(name: String): ?String
    public func fill(): SvgPaint
    public func stroke(): SvgPaint
    public func strokeWidth(): SvgLength
    public func opacity(): Float64
    public func color(): SvgColor
    public func fontFamily(): String
    public func fontSize(): SvgLength
    public func has(name: String): Bool
    public let source: CssStyleSource          // 用于调试
}

public enum CssStyleSource { | Default | Presentation | Sheet | Inline | Important }

public class SvgStyleResolver {
    public init(sheet!: CssStyleSheet = CssStyleSheet.empty())
    public func compute(root: SvgElement): SvgComputedStyleTree
    public func computeElement(element: SvgElement, parent: ?SvgComputedStyle): SvgComputedStyle
}
```

### 2.3 解析与计算流程

```
<style> 文本 / .css 文件
  → CssLexer（跳过注释、识别字符串与 url()）
  → CssParser（规则集 / 声明块 / !important）
  → CssStyleSheet（规则按源顺序）
  → SvgStyleResolver：
       对每个元素：
         1. 收集匹配规则 + 呈现属性 + 内联声明
         2. 按 (important, 来源, 特异性, 源顺序) 排序
         3. 逐属性取胜出值
         4. 继承可继承属性
         5. 解析为类型化值（颜色、长度、画笔、字体）
         6. 解析 currentColor
  → SvgComputedStyleTree
```

**安全**：`style` / `<style>` 中的 `url(...)` 与 `@import` 在 M1 已由构建器过滤；
M2 的 CSS 解析器**不再引入外部资源**，只处理已过滤后的文本。若调用方直接解析
`CssStyleSheet`，其中 `url()` 只作为字符串保留，渲染阶段只接受 `#id` 片段。

### 2.4 测试矩阵

- 词法：注释、字符串、`url()`、转义、非法字符恢复；
- 选择器：五类基本选择器、复合、后代、子代、分组、特异性排序；
- 级联：UA < 呈现 < 样式表 < 内联 < `!important` 的六组交叉；
- 继承：可继承 / 不可继承 / `inherit` / `initial` / `unset`；
- `currentColor` 两级继承；
- 非法声明：未知属性忽略、非法值降级并 warning；
- 性能：1000 条规则 × 1000 元素的匹配（目标 < 20 ms）。

---

## 3. 几何层（M2-3 / M2-4）

### 3.1 包围盒

```cangjie
public struct SvgBounds <: Equatable<SvgBounds> & ToString {
    public let x: Float64
    public let y: Float64
    public let width: Float64
    public let height: Float64
    public static func empty(): SvgBounds
    public func isEmpty(): Bool
    public func union(that: SvgBounds): SvgBounds
    public func intersect(that: SvgBounds): SvgBounds
    public func transform(matrix: SvgMatrix): SvgBounds       // 变换后轴对齐包围盒
    public func inflate(amount: Float64): SvgBounds
}

public class SvgGeometry {
    /** 元素自身坐标系中的几何包围盒（不含描边）。 */
    public static func bounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds
    /** 含描边的包围盒。 */
    public static func strokeBounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds
    /** 应用元素及其祖先 transform 后的包围盒。 */
    public static func absoluteBounds(element: SvgElement, style!: SvgComputedStyle): ?SvgBounds
}
```

实现要点：

- `rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon`：直接几何；
- `path`：
  - 三次 / 二次贝塞尔：求导数零点，取端点与极值点；
  - 弧：端点参数 → 中心参数，按角度范围取四个轴向极值；
  - 直线 / `H/V` / `Z`：端点；
  - 退化（零长、负半径、NaN）：忽略该段；
- 文本：由字体 provider 的 `glyphBounds` 累加；无 provider 时返回 `None`；
- 描边：路径 bbox 外扩 `strokeWidth / 2`，斜接 join 用 `miterlimit` 修正；
- 变换：对 bbox 四角变换后取轴对齐包围盒（保守但正确）。

### 3.2 视口

```cangjie
public struct SvgViewport {
    public let width: Float64
    public let height: Float64
    public static func from(root: SvgRoot, fallbackWidth: Float64, fallbackHeight: Float64): SvgViewport
    public func transform(root: SvgRoot): SvgMatrix    // viewBox + preserveAspectRatio
}
```

- `viewBox` 缺省：用户单位 = 设备单位；
- `preserveAspectRatio` 使用 M1 的 `toMatrix`；
- 嵌套 `<svg>` 的视口变换按祖先矩阵累乘。

### 3.3 测试

- 每个形状的 bbox 精确值；
- 贝塞尔极值（控制点同侧 / 异侧 / 退化）；
- 弧的四种轴向极值、整圆、半圆、大弧 / 小弧 / 翻转标志；
- 变换后 bbox（旋转 45°、非等比缩放）；
- 描边 bbox（miter / round / bevel）；
- 空元素 / 零尺寸 / 非法值。

---

## 4. 渲染层（M2-5 ~ M2-10 / M2-12）

### 4.1 入口与选项

```cangjie
public struct SvgRenderOptions {
    public let width: Int64                    // 输出像素宽，默认取 root.width
    public let height: Int64
    public let background: ?SvgColor           // 默认透明
    public let samplesPerPixel: Int64          // 1 / 2 / 4，默认 4（SSAA）
    public let maxPixels: Int64                // 默认 64M，超限抛 Limit
    public let fonts: ?SvgFontRegistry
    public let devicePixelRatio: Float64       // 默认 1.0
}

public class SvgBitmap <: ToString {
    public let width: Int64
    public let height: Int64
    public let pixels: Array<Byte>             // RGBA8，row-major，非预乘
    public func pixel(x: Int64, y: Int64): SvgColor
    public func writePng(output: OutputStream): Unit
    public func toPngBytes(): Array<Byte>
    public func savePng(path: Path): Unit
}

public class SvgRenderer {
    public init(options!: SvgRenderOptions = SvgRenderOptions())
    public func render(document: SvgDocument): SvgBitmap
    public func render(element: SvgElement, width!: Int64, height!: Int64): SvgBitmap
}

public func renderToPng(document: SvgDocument, options!: SvgRenderOptions = SvgRenderOptions()): Array<Byte>
```

### 4.2 渲染管线

```
SvgDocument
  → SvgStyleResolver.compute        （计算样式）
  → SvgRenderTreeBuilder            （解析 use/image/clipPath/mask/渐变，展开 display:none）
  → SvgDisplayList                  （扁平绘制指令：FillPath / StrokePath / Image / Text）
  → SvgRasterizer                   （逐指令光栅，SSAA 子采样）
  → SvgBitmap                       （RGBA8）
  → SvgPngEncoder                   （可选）
```

**隔离组**：`opacity < 1`、`mask`、`clipPath`、`filter`（M3）需要离屏缓冲；
`opacity` 用预乘 alpha 的 `over` 合成，避免色边。

**变换**：每个绘制指令携带 `SvgMatrix`（用户坐标 → 设备坐标），
光栅器把路径控制点变换后直接扫描，不做位图变换。

**裁剪**：`clipPath` 生成覆盖率蒙版（8-bit），与绘制覆盖率相乘；
`clip-rule` 支持 nonzero / evenodd。

**蒙版**：`mask` 生成 alpha/luminance 蒙版；`maskUnits` / `maskContentUnits` 支持
`userSpaceOnUse` / `objectBoundingBox`。

### 4.3 光栅化算法

**填充**：

- 扫描线 + 边表（active edge table），按 y 方向 1 行、x 方向 `samplesPerPixel` 子采样；
- 非零环绕：累计有向交点；奇偶：交点配对；
- 每个像素的覆盖率 = 子采样命中数 / `samplesPerPixel²`；
- 水平/垂直线段、退化边做保护；
- 目标：1 个 512×512 的 100 段路径 < 8 ms。

**抗锯齿**：默认 4×4 超采样；`samplesPerPixel = 1` 时关闭（用于基准/像素精确用例）。
后续可替换为解析覆盖率（M3），接口不变。

**颜色与混合**：

- 内部统一 `SvgRgba`（Float64 r/g/b/a，0..1）；
- 源覆盖 `a = color.a * coverage * opacity`；
- 目标使用「over」：`out = src + dst * (1 - src.a)`，非预乘输出前转换；
- `background` 先填满画布。

**渐变**：

- 线性：`t = dot(p - p0, p1 - p0) / |p1 - p0|²`，按 `spreadMethod` 映射；
- 径向：焦点 `fx/fy`，按 `t = (|p - f| / r)` 的圆锥/椭圆近似；`FR` 与 `fr` 暂不支持；
- stops：按 offset 排序，线性插值 RGBA（sRGB 空间，不做 gamma 校正）；
- `gradientTransform` 在采样前应用逆矩阵；
- `objectBoundingBox`：把 bbox 归一化到 `0..1`。

**描边**：

- `SvgStrokeOutliner` 把中心线转成闭合轮廓：
  - 每段生成左右偏移线；
  - join：miter（超过 `miterlimit` 退化为 bevel）、round（圆弧离散）、bevel；
  - cap：butt / round / square；
  - dash：按 `dasharray` 切分中心线，每段独立加 cap；
- 轮廓按填充规则 nonzero 光栅化；
- 圆形 / 椭圆 / 矩形走解析轮廓，不依赖通用 outliner。

**文本**：

```cangjie
public interface SvgFont {
    func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData
    func advance(codePoint: Int64, fontSize: Float64): Float64
    func ascent(fontSize: Float64): Float64
    func descent(fontSize: Float64): Float64
    func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds
}

public class SvgFontRegistry {
    public func register(family: String, font: SvgFont): Unit
    public func resolve(family: String, weight: String, style: String): ?SvgFont
    public static func defaultRegistry(): SvgFontRegistry   // 内置 Hershey ASCII
}
```

- 内置 `HersheyFont`：ASCII 32–126，单线笔画，`glyphPath` 返回折线；
- 文本布局：按字符 advance 累加，支持 `x/y` 列表（逐字定位）、`dx/dy`、`letter-spacing`、
  `word-spacing`、`text-anchor`（start/middle/end）、`textLength` + `lengthAdjust`；
- 字形以 `SvgPathData` 交给光栅器，**与形状共用同一套填充/描边**；
- CJK / 复杂脚本：外部注册 `SvgFont`；未命中时绘制占位方框并记 warning；
- 不做 bidi、连字、字形替换。

**`use` / 符号**：解析 `href="#id"`，克隆目标子树并叠加 `x/y` 位移；
`symbol` 的 `viewBox` 按嵌套视口处理；循环引用检测（最大深度 64）。

**`<image>`**：M2 不解码；保留占位矩形（透明或 `background`），记 warning。
M3 接 PNG/JPEG 解码后替换。

### 4.4 PNG 编码

```cangjie
public class SvgPngEncoder {
    public static func encode(bitmap: SvgBitmap): Array<Byte>
    public static func write(bitmap: SvgBitmap, output: OutputStream): Unit
}
```

- PNG 签名 + `IHDR`（8-bit RGBA，color type 6）+ `IDAT` + `IEND`；
- 每行 filter 0（None）；IDAT 使用 `stdx.compress.zlib.CompressOutputStream` 的
  `WrapType.DeflateFormat`，再手工加 zlib 头（`0x78 0x9C`）与 Adler-32；
- CRC-32 复用 `f_util.crc32`？`f_svg` 不依赖 `f_util`；在 `f_svg` 内部实现 20 行 CRC-32 表，
  避免为一个函数新增模块依赖（与 `f_xml` 的 Escaper 同理）；
- 输出确定性：同一 `SvgBitmap` 两次编码字节一致。

### 4.5 渲染测试

**基元级**（像素精确，`samplesPerPixel = 1`）：

- 矩形覆盖：半开半闭、边界像素；
- 三角形 / 凹多边形：nonzero vs evenodd；
- 圆 / 椭圆：四象限对称；
- 描边：butt/round/square、miter 截断、dash 相位；
- 渐变：端点、spread、stops 边界；
- 裁剪：矩形 / 圆形 clipPath；
- 透明度：两层 50% 叠加的期望值（容差 1/255）。

**场景级**：

- `testdata/render/*.svg` + 对应 `*.rgba` 期望图（64×64，约 16 KB/张），
  逐像素比较，容差 ≤ 1；
- 覆盖：形状、渐变、描边、clipPath、mask、文本、use、嵌套 svg；
- 动画：同一文档在 0 / 0.5 / 1 秒的采样快照 + 像素快照。

**性能基准**（参考、非门禁）：

- 512×512 基础场景（50 个形状）≤ 50 ms；
- 1024×1024 渐变 + 裁剪 ≤ 200 ms；
- PNG 编码 1024×1024 ≤ 100 ms；
- 内存 ≤ 输出像素 × 12 字节。

---

## 5. 动画层（M2-11）

### 5.1 支持的 SMIL 子集

| 元素 | 作用 | 支持属性 |
|---|---|---|
| `animate` | 任意可动画属性 | `attributeName`、`from` / `to` / `by` / `values`、`dur`、`begin`、`end`、`repeatCount`、`repeatDur`、`fill`、`calcMode`、`keyTimes`、`keySplines`、`additive`、`accumulate` |
| `animateTransform` | `transform` | 同上 + `type`（translate/scale/rotate/skewX/skewY） |
| `animateMotion` | 沿路径移动 | `path` / `mpath`、`rotate`（auto/auto-reverse/角度）、`keyPoints` |
| `set` | 定时设值 | `attributeName`、`to`、`begin`、`dur`、`fill` |

**时间语义**：

- `begin` / `end`：支持 `0s`、`1.5s`、`500ms`、`indefinite`、`id.begin`、`id.end`；
  事件型（`click`）不支持，解析时忽略并 warning；
- `dur`：秒 / 毫秒；`indefinite` 表示永不结束；
- `repeatCount`：数值 / `indefinite`；`repeatDur` 截断总时长；
- `fill`：`remove` / `freeze`；
- 简单时间轴：同一元素多个动画按 begin 排序，后者覆盖前者（`additive="sum"` 时叠加）。

### 5.2 API

```cangjie
public interface SvgClock {
    func now(): Float64                 // 秒
}

public class SvgManualClock <: SvgClock {
    public var time: Float64
    public init(time!: Float64 = 0.0)
}

public class SvgTimeline {
    public init(document: SvgDocument, clock!: SvgClock = SvgManualClock())
    public func duration(): Float64                  // 无动画时 0
    public func animations(): Array<SvgAnimationInfo>
    /** 返回应用动画后的文档快照；不修改原文档。 */
    public func sample(time: Float64): SvgDocument
    public func sampleCurrent(): SvgDocument
}

public class SvgAnimationInfo {
    public let targetId: ?String
    public let attributeName: String
    public let begin: Float64
    public let end: Float64
    public let kind: SvgAnimationKind
}
```

### 5.3 插值

| 类型 | 规则 |
|---|---|
| 数值 | 线性；`calcMode=discrete` 取前一个关键帧；`spline` 用 `keySplines` 三次贝塞尔 |
| 数值列表 | 逐项插值，长度不等时按较短者并对多余项取末值 |
| 颜色 | RGBA 各通道线性插值（sRGB） |
| 变换 | 分解为 translate/scale/rotate/skew 后逐项插值；无法分解时离散 |
| 路径 | 命令结构一致时逐坐标插值；否则离散 |
| 字符串 / 枚举 | 离散 |

- `by` 动画：`to = from + by`（数值）；
- `additive="sum"`：叠加到基础值；`accumulate="sum"`：每轮重复累加；
- `fill="freeze"`：结束后保持末值；`remove`：恢复基础值；
- 动画只作用于**渲染用快照**，不写回 `SvgDocument`。

### 5.4 测试

- 时间解析：`0s` / `1.5s` / `500ms` / `indefinite` / `id.begin`；
- 关键帧：`values` + `keyTimes` 的线性 / 离散 / 样条；
- 重复：`repeatCount=2.5`、`repeatDur` 截断、`fill=freeze`；
- 变换：`animateTransform` 的六种 type、`additive=sum`；
- 路径运动：直线 / 曲线 / `rotate=auto`；
- 采样快照不修改原文档；
- 与渲染联调：0 / 0.5 / 1 秒的像素快照。

---

## 6. 模块布局

保持单包 `fountain::f_svg`，新增文件：

```
f_svg/src/
  CssLexer.cj  CssParser.cj  CssSelector.cj  CssStyleSheet.cj
  SvgComputedStyle.cj  SvgStyleResolver.cj
  SvgBounds.cj  SvgGeometry.cj  SvgViewport.cj
  SvgStrokeOutliner.cj
  SvgBitmap.cj  SvgRasterizer.cj  SvgRenderTree.cj  SvgRenderer.cj
  SvgFont.cj  SvgHersheyFont.cj  SvgTextRenderer.cj
  SvgPngEncoder.cj  SvgCrc32.cj
  SvgAnimation.cj  SvgTimeline.cj  SvgInterpolator.cj  SvgClock.cj
  *_test.cj
f_svg/testdata/render/
  basic.svg  gradient.svg  stroke.svg  clip.svg  text.svg  animation.svg
  *.rgba（期望图）
```

- 新文件按主题前缀分组，不建子包；
- 公开类型全部在 `f_svg.cj` 的包声明下自动可见，无需再导出；
- 测试与实现同名，保持 M1 约定。

---

## 7. 性能与内存

| 场景 | 目标（参考） |
|---|---|
| 512×512、50 个形状、4×4 SSAA | ≤ 50 ms |
| 1024×1024、渐变 + 裁剪 | ≤ 200 ms |
| 1024×1024 PNG 编码 | ≤ 100 ms |
| 几何 bbox（1000 段路径） | ≤ 2 ms |
| CSS 匹配（1000 规则 × 1000 元素） | ≤ 20 ms |
| 峰值内存 | ≤ 输出像素 × 12 字节 + 文档模型 |

- 光栅器按行处理，不分配整幅浮点缓冲；离屏层只在需要时创建；
- 路径在光栅前预变换并扁平化（贝塞尔按设备像素误差 0.25 细分为折线）；
- 文字按 glyph 缓存路径（字体 + 字号 + 字符 → `SvgPathData`）。

---

## 8. 安全

- 渲染器**不发起网络请求、不打开外部文件**；
- CSS `url()` 只接受 `#id`；外部 URL 在解析阶段已由 M1 过滤；
- `<image>` 不解码，避免图像解码器攻击面；
- 输出尺寸受 `maxPixels` 限制，防止内存炸弹；
- 递归深度（`use` / 嵌套 svg / 动画）上限 64；
- 动画 `values` 数量上限 10000，防止时间轴爆炸。

---

## 9. 验收判据（M2）

1. CSS：选择器 / 级联 / 继承矩阵全绿；1000×1000 匹配 ≤ 20 ms；
2. 几何：所有形状、贝塞尔、弧、描边的 bbox 用例通过；
3. 渲染：基元像素用例 + 六个场景快照通过（容差 ≤ 1）；
4. 动画：时间解析、插值、重复、freeze 用例通过；采样不修改原文档；
5. PNG：结构校验（签名 / IHDR / IDAT / IEND / CRC / Adler-32）+ 解码回读一致；
6. `cjpm test` 全绿，`f_svg` 自身 0 warning；
7. M1 的 216 条用例不回归；
8. README（中英）与设计文档同步公开 API。

---

## 10. 实施顺序

| 阶段 | 内容 | 依赖 |
|---|---|---|
| M2.1 | CSS 词法 / 解析 / 选择器 / 级联 / 计算样式 | M1 |
| M2.2 | 包围盒 / 视口变换 | M1 |
| M2.3 | 位图 / 光栅器基元（填充、SSAA、混合） | M2.2 |
| M2.4 | 描边轮廓 | M2.3 |
| M2.5 | 渐变 / 裁剪 / 蒙版 / 组透明度 | M2.3 |
| M2.6 | 文本（Hershey + 布局） | M2.3 |
| M2.7 | 渲染树 / `SvgRenderer` / `use` / 嵌套 svg | M2.3–M2.6 |
| M2.8 | PNG 编码 | M2.3 |
| M2.9 | SMIL 动画 / 采样 | M2.1 |
| M2.10 | 场景快照 / 性能基准 / README / 文档 | 全部 |

每个阶段按 Red-Green-Refactor 推进；渲染基元先写像素级断言，再写实现。

---

## 11. 已定契约

1. 公开 API 只增不改，M1 签名保持；
2. 渲染输出 RGBA8 非预乘，行优先，`pixels.size == width * height * 4`；
3. 同一输入 + 同一选项 → 字节级一致的 PNG；
4. 渲染器不联网、不解码外部图像、不执行脚本；
5. 动画采样返回新文档，不修改原文档；
6. 文本必须经 `SvgFont`，核心不内置 CJK 字体；
7. 所有安全上限硬失败（`SvgException(kind: Limit)`）；
8. 单包布局，不新增模块、不动聚合根 shim。
