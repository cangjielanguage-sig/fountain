# f_svg

**SVG 1.1 文档与渲染**模块：值类型 + 类型化 DOM + 解析/生成 + 安全过滤 +
CSS 级联 + CPU 软件光栅 + 确定性 PNG + SMIL 动画。

M1 的静态文档能力保持不变；M2 增加「从文档到像素」与「从时间到文档」两条链路。
底层 XML 全部复用 [`f_xml`](../f_xml/README.md)，模块内没有第二套 XML 词法器。

> 设计、取舍与里程碑见 [`doc/f_svg模块设计.md`](doc/f_svg模块设计.md)。

## 依赖

```
f_svg
├── f_xml     XML 1.0 解析、DOM、命名空间、XmlWriter、实体安全上限
└── f_base    BaseException / StringGenerator
```

## 安装

模块随 fountain 仓库发布，版本与仓库一致（当前 `1.3.17`）。在应用 `cjpm.toml` 中按仓库惯用方式声明：

```toml
[dependencies]
  "fountain::f_svg" = { path = "../fountain/f_svg" }
```

或在已配置中心仓时使用 `"fountain::f_svg" = "1.3.17"`。同时需要在仓库根 `.modules` 中登记
`f_svg`（本仓库已登记）。

## 能力（M3）

| 能力 | 入口 |
|---|---|
| 解析 | `SvgParser.parse` 的文本 / 字节 / 流 / 路径 / `XmlDocument` 五个重载 |
| 模型 | `SvgDocument` / `SvgRoot` / `SvgElement` 及形状、文本、渐变、`use`、`image` 子类 |
| 类型化属性 | `SvgLength` / `SvgColor` / `SvgPaint` / `SvgTransform` / `SvgPathData` / `SvgViewBox` |
| 生成 | `SvgWriter` / `writeSvgString`，内部经 `XmlDocument` 交给 `f_xml::XmlWriter` |
| 安全 | 默认移除脚本、事件属性、外部引用；元素数与深度硬上限 |
| CSS | `CssStyleSheet` / `CssSelector` / `SvgStyleResolver` / `SvgComputedStyle` |
| 几何 | `SvgBounds` / `SvgGeometry` / `SvgViewport` |
| 渲染 | `SvgBitmap` / `SvgRasterizer` / `SvgRenderer` / `renderToPng` |
| PNG | `SvgPngEncoder` / `SvgBitmap.toPngBytes` / `writePng` / `savePng` |
| 动画 | `SvgTimeline` / `SvgInterpolator` / `SvgClock` / `SvgManualClock` |
| 字体 | `SvgFont` 接口 / `SvgFontRegistry` / 内置 `SvgHersheyFont` |
| 滤镜 | `SvgFilter` / `SvgFilterRenderer` / `SvgFilterBuffer`，八个 `fe*` 原语 |
| 图案 | `SvgPattern` / `SvgPatternSampler`，`href` 继承与 `patternTransform` |
| 位图 | `SvgPngDecoder` / `SvgImageResourceProvider` / `SvgRenderOptions.images` |
| SVGZ | `SvgParser.parseAuto` / `parseGzip` / `writeGzip` |
| 文本路径 | `SvgTextPathLayout` / `rotate` 列表 |
| marker | `SvgMarker` / `SvgMarkerExpander` |
| 解析 AA | `SvgAntiAliasMode.Analytic` / `SvgRenderOptions.antiAlias` |
| 无损保留 | 未知元素、未知属性、注释 / PI / CDATA、DOCTYPE |

## 快速开始（M1 文档能力）

### 1. 解析与遍历

```cangjie
import fountain::f_svg.*
import std.fs.Path

let document = SvgParser.parse(Path("logo.svg"))
let root = document.root
println(root.width?.toString() ?? "100%")

for (rect in document.elementsByTag("rect")) {
    println("${rect.id ?? "-"}: ${rect.attr("x") ?? "0"}")
}

for (warning in document.warnings) {
    println("warning: ${warning}")
}
```

解析文本时不会做字节嗅探：

```cangjie
let document = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>")
```

### 2. 构造文档

```cangjie
let svg = SvgRoot(
    width: SvgLength(200.0, unit: SvgLengthUnit.Px),
    height: SvgLength(100.0, unit: SvgLengthUnit.Px)
)
svg.viewBox = SvgViewBox(0.0, 0.0, 200.0, 100.0)

let rect = SvgRect(
    x: SvgLength(10.0), y: SvgLength(10.0),
    width: SvgLength(80.0), height: SvgLength(40.0)
)
rect.fill = SvgPaint.of(SvgColor.parse("#09f"))
rect.strokeWidth = SvgLength(2.0)
svg.appendElement(rect)

let document = SvgDocument(svg)
```

### 3. 生成

```cangjie
let compact = writeSvgString(document)
let pretty = writeSvgString(document, options: SvgWriteOptions(indent: Some("  ")))
```

写文件：

```cangjie
import std.fs.{File, OpenMode}

let file = File("out.svg", OpenMode.Write)
try {
    let writer = SvgWriter(file)
    writer.write(document)
    writer.flush()
} finally {
    file.close()
}
```

### 4. 安全选项

默认对不可信内容「移除 + 告警」，不会因一个 `<script>` 让整份文档失败：

```cangjie
let document = SvgParser.parse(userInput, options: SvgParseOptions(
    strict: false,
    security: SvgSecurityOptions(
        unsafePolicy: SvgUnsafePolicy.Remove,
        allowScript: false,
        allowEventAttributes: false,
        allowExternalReferences: false,
        allowDataImages: true,
        maxElements: 1_000_000,
        maxDepth: 512
    )
))
```

| 内容 | 默认 | 开关 |
|---|---|---|
| `<script>` | 移除 | `allowScript` / `unsafePolicy` |
| `on*` 事件属性 | 移除 | `allowEventAttributes` |
| `http:` / `https:` / `//` 引用 | 移除 | `allowExternalReferences` |
| `file:` / `javascript:` 引用 | 移除 | 仅 `unsafePolicy`（`allowExternalReferences` 不放行） |
> `allowExternalReferences` 仅作用于 `href`（`use` / `image` / `a` 等）；
> `fill` / `stroke` / `filter` / `clip-path` / `mask` / `marker-*` / `cursor` / `style` 中的
> `url(...)` 外部引用由 `unsafePolicy` 单独控制。

| `data:` 图片 | 保留 | `allowDataImages`（置 `false` 时移除） |
| `#id` 片段引用 | 保留 | 不可关闭 |
| 外部 DTD / 外部实体 | 永不加载 | 不可放开 |

规模上限（元素数 / 深度 / 实体）在严格与宽松模式下都**硬失败**，抛
`SvgException(kind: SvgErrorKind.Limit)`。

## M2：样式、渲染、PNG 与动画

```cangjie
import fountain::f_svg.*
import std.fs.Path

// 计算样式
let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: red }"))
let styles = resolver.compute(document.root)
let style = styles.get(rect)

// 渲染为位图 / PNG
let options = SvgRenderOptions(width: 128, height: 128, background: SvgColor.White)
let bitmap = SvgRenderer(options: options).render(document)
bitmap.savePng(Path("out.png"))

// 动画采样（不修改原文档）
let timeline = SvgTimeline(document)
let frame = timeline.sample(0.5)
let frameBitmap = SvgRenderer().render(frame)

// 字体注册：默认注册表内置 Hershey；也可注册外部 SvgFont
let fonts = SvgFontRegistry.defaultRegistry()
let textOptions = SvgRenderOptions(fonts: fonts)
```

渲染输出为 RGBA8、非预乘、行优先；同一文档 + 同一选项逐字节一致。
`SvgRenderOptions.samplesPerPixel` 只允许 1 / 2 / 4，`maxPixels` 默认 64M。

## M3：滤镜、图案、位图与 SVGZ

M3 只新增带默认值的选项，默认渲染输出与 M2 逐字节一致；唯一例外是合法
`data:image/png` 由占位变为真实绘制，以及显式开启 `antiAlias = Analytic` 时覆盖率来源改变。

### 滤镜

`<filter>` 与 `feGaussianBlur` / `feOffset` / `feFlood` / `feBlend` / `feComposite` /
`feMerge` / `feColorMatrix` / `feTile` 全部类型化；区域按 `filterUnits` 换算并裁剪到画布，
超过 `SvgRenderOptions.maxPixels` 时在分配缓冲前抛 `SvgException(kind: Limit)`。

```cangjie
let filter = SvgFilter()
filter.filterUnits = SvgCoordinateUnits.UserSpaceOnUse
filter.width = SvgLength(200.0)
let blur = SvgFeGaussianBlur()
blur.stdDeviation = SvgNumberList([2.0])
filter.appendElement(blur)
```

### 图案

`fill="url(#p)"` 与描边都支持 `<pattern>`：`patternUnits` / `patternContentUnits` 换算 tile，
`patternTransform` 在取样前作用于 tile，`href` 逐属性继承，循环引用只记 warning。

### 位图与资源边界

```cangjie
class MemoryImages <: SvgImageResourceProvider {
    public func resolve(href: String): ?Array<Byte> {
        if (href == "mem://logo") {
            return Some(pngBytes)
        }
        None
    }
}

let options = SvgRenderOptions(images: Some(MemoryImages()))
let bitmap = SvgRenderer(options: options).render(document)
```

注意：默认 `SvgParseOptions` 会移除 `mem://` 等外部引用；解析这类文档时需设置
`SvgParseOptions(security: SvgSecurityOptions(unsafePolicy: SvgUnsafePolicy.Keep))`，
否则 provider 不会被调用。`allowExternalReferences` 只放行 `http(s):` 与协议相对 URL，
不放行自定义协议。

`<image>` 只接受两种来源：`data:image/png;base64,` 内联字节，或调用方注入的
`SvgImageResourceProvider.resolve(href)`。库内不联网、不打开文件、不执行脚本；
`preserveAspectRatio` 与 `image-rendering` 分别控制映射与最近邻 / 双线性取样。
未注入 provider、返回 `None` 或解码失败时绘制占位并记 warning；占位默认透明，
设置 `SvgRenderOptions.background` 时按 M2 语义使用背景色填充。

### SVGZ

```cangjie
let document = SvgParser.parseAuto(bytes)   // 1F 8B 魔数命中时自动解压
let document2 = SvgParser.parseGzip(bytes)  // 强制 gzip
let compressed = writeGzip(document)        // mtime 固定 0，同文档同字节
```

解压输出超过 `SvgSecurityOptions.maxDecompressedBytes`（默认 64 MiB）抛 `Limit`。

### textPath、marker 与解析 AA

- `<textPath href="#path">` 按弧长排版，支持 `startOffset`（长度 / 百分比）、`text-anchor`、
  路径不足时截断 warning；`rotate` 单值 / 列表按字形消费，并与切线角叠加。
- `marker-start` / `marker-mid` / `marker-end` 支持 `markerUnits`、`orient`、`refX` / `refY`
  与 `viewBox`；每个元素最多 1024 个，超出 warning 截断。
- `SvgRenderOptions(antiAlias: SvgAntiAliasMode.Analytic)` 使用解析覆盖率；
  默认仍为 `Supersample`，`samplesPerPixel` 语义与 M2 完全一致。

### M3 安全上限

单张解码图像素 16 × 1024 × 1024、单次渲染累计解码 64 × 1024 × 1024、base64 文本 32 MiB、
gzip 解压输出 64 MiB、滤镜区域同 `maxPixels`、pattern tile 4 × 1024 × 1024、
pattern / marker 引用深度 64；所有检查都发生在分配大缓冲之前。

## M4：渲染保真、文本排版与查询 API

M4 只新增带默认值的行为与查询方法，`SvgRenderOptions` 仅追加 `languages`（默认 `["en"]`）。
未声明 M4 属性的文档，渲染输出与 M3 逐字节一致；条件性差异有两处：marker 内容越出
`markerWidth × markerHeight` 时按 SVG 1.1 裁剪，`switch` 由 M3 的遍历全部子元素改为
只选择第一个满足条件的子元素（M3 快照均不触发这两类差异，仍逐字节一致）。

### 能力

| 组 | 能力 | 入口 |
|---|---|---|
| A | `clip` / `overflow` / `vector-effect` | `SvgClipProperty` / `SvgClipCoverage` / `SvgOverflow` / `SvgVectorEffect` |
| A | 7 类新滤镜原语 | `SvgFeComponentTransfer` / `SvgFeMorphology` / `SvgFeConvolveMatrix` / `SvgFeTurbulence` / `SvgFeDisplacementMap` / `SvgFeImage` |
| A | 光照 | `SvgFeDiffuseLighting` / `SvgFeSpecularLighting` / `SvgFeDistantLight` / `SvgFePointLight` / `SvgFeSpotLight` |
| A | pattern 视口 | `SvgPattern.viewBox` / `preserveAspectRatio` |
| B | 基线 / 装饰 / 竖排 | `SvgTextBaseline` / `SvgTextDecoration` / `SvgTextWritingMode` |
| B | textPath 扩展 | `SvgTextPath.side` / `method` / `spacing` |
| B | TrueType | `SvgTrueTypeFont.parse` / `load`，`cmap` 4/12、简单 + 复合字形 |
| C | 文档查询 | `SvgView` / `SvgDocument.views()` / `view(id)` / `switch` / `SvgDocument.anchors()` |
| C | 几何 API | `SvgPathData.totalLength` / `pointAtLength`、`SvgGeometry.ctm` / `screenCTM` |

### A：裁剪、溢出与非缩放描边

```cangjie
let document = SvgParser.parse(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
    "<g clip=\"rect(0, 20, 20, 0)\">" +
    "<rect width=\"40\" height=\"40\" fill=\"red\" vector-effect=\"non-scaling-stroke\"/>" +
    "</g></svg>"
)
let bitmap = SvgRenderer().render(document)
```

- `clip` 走覆盖率蒙版，可随元素 CTM 旋转；与 `clip-path` 同时存在时先 `clip` 后 `clip-path`。
- `overflow` 只对 marker / symbol / pattern / 嵌套 svg 生效；`scroll` / `auto` 归一为 `hidden`。
- `vector-effect="non-scaling-stroke"` 把描边宽度与虚线段长按 `1 / sqrt(|det(CTM)|)` 换算。
- 公开取值 `SvgVectorEffect.NoEffect` / `SvgVectorEffect.NonScalingStroke`（类 + 静态属性，避免与 `Option.None` 同名）。

### B：基线、装饰、竖排与 TrueType

```cangjie
let registry = SvgFontRegistry()
registry.register("MyFont", SvgTrueTypeFont.load(Path("my.ttf")))
let options = SvgRenderOptions(fonts: registry)
```

- `dominant-baseline` / `alignment-baseline` / `baseline-shift` 叠加顺序固定：基线表 → dominant → shift。
- `text-decoration` 不继承，但沿最近声明祖先向下传播；逐字形生成装饰线并随切线旋转。
- `writing-mode="tb-rl"` 沿 y 递增排布、列沿 x 递减，字形顺时针 90°；与 `textPath` 冲突时忽略并 warning。
- `textPath` 的 `side` / `method="stretch"` / `spacing="exact"` 均带 M3 兼容缺省。

### C：view、switch、anchors 与几何查询

```cangjie
let views = document.views()
let anchors = document.anchors()
let length = SvgPathData.parse("M0 0 L100 0").totalLength()
let point = SvgPathData.parse("M0 0 L100 0").pointAtLength(50)
let ctm = SvgGeometry.ctm(document.elementsByTag("rect")[0])
```

- `switch` 按子元素顺序求值，`systemLanguage` 与 `SvgRenderOptions.languages` 做 `-` 边界的前缀匹配。
- `view` 只提供模型与 `SvgViewport.forView` 换算，不参与默认渲染，也不实现 `url(#view)` 导航。
- `anchors()` 只返回解析后保留的链接；外部 `href` 仍按既有安全策略移除。

### M4 限制

- `pattern` 的 `overflow="visible"` 不向相邻 tile 扩展；tile 仍是采样周期。
- TTF 只支持 TrueType 轮廓：CFF / OTF 抛 `Unsupported`；不解析 hinting / `GSUB` / `GPOS` / `kern`，
  字距只来自 `hmtx`。库内不打开路径，`SvgTrueTypeFont.load(path)` 是唯一文件入口；
  `parse(bytes)` 与渲染过程都不访问文件系统，字体必须由调用方显式加载。
- `feImage` 只接受 `data:image/png` 与 provider，并与 `<image>` 共享单次渲染解码预算。
- `ctm` 不计入 `use` 实例化产生的额外变换。

## 值类型

所有值类型对**规范形式可表示**的值满足 `parse(toString(x)) == x`；`parse` 失败抛 `SvgException`，
`SvgLength` / `SvgColor` / `SvgPathData` 另提供 `tryParse`（返回 `None`）。

已知不保真边界：绝对值 `< 1e-6` 的非零值归零、超过 6 位小数的值被舍入。
`SvgColor` 的 alpha 可由 `0..255` 字节精确表示时输出 `#rrggbbaa`（如 `#ff000080`），否则输出 `rgba()`。

```cangjie
SvgLength.parse("1.5em")          // value = 1.5, unit = Em
SvgColor.parse("hsl(120,100%,50%)") // #00ff00
SvgPaint.parse("url(#grad1) none")  // Reference(#grad1, fallback = Some(SvgPaint.None))
SvgTransform.parse("translate(10,20) scale(2)").toMatrix()
SvgPathData.parse("M0 0 A5 5 0 0110 10")
SvgViewBox.parse("0 0 200 100")
SvgPreserveAspectRatio.parse("xMinYMax slice")
```

长度换算需要显式指定百分比基准轴：

```cangjie
let context = SvgLengthContext.of(200.0, 100.0)
toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context) // 100
```

## 模型与序列化契约

- **属性顺序稳定**：解析按源顺序，构造按赋值顺序，序列化同序。
- **未知 ≠ 丢弃**：非 SVG 命名空间元素保留为 `SvgUnknownElement`（前缀 / URI / 子树完整）；
  未知属性原样留在 `attributes`。
- **结构等价往返**：`parse → write → parse` 的标签、URI、属性展开名与值、文本、子节点顺序、
  注释 / PI / CDATA 一致；空元素写法、引号、缩进与 XML 声明不要求字节一致。
- **紧凑字节稳定**：连续两次紧凑写入结果相同。
- `href` 读取同时接受 `href` 与 `xlink:href`；写入形式由 `SvgWriteOptions.xlink` 决定
  （默认 `true` 写 `xlink:href`）。同一元素同时带两种写法时只保留第一个，避免重复属性。
- `writeSvgString` 只接受 UTF-8；其他 `charset` 请直接用 `SvgWriter` 写字节流，
  字符串便捷函数会抛 `SvgException(kind: InvalidValue)`。

## 错误定位

`f_xml::XmlException` 在解析边界包装为 `SvgException(kind: SvgErrorKind.Syntax)`，
保留 1-based 行列。构建期的值错误与安全错误额外携带 `elementPath()`：
```
/svg[1]/g[2]/rect[1]
```

构建期（值 / 安全 / 结构）错误的 `line` 与 `column` 为 `0`，定位以 `elementPath` 为准；
只有 XML 词法/语法错误保留行列。

## 样本与测试

`testdata/` 提供 M1 小型样本（`basic-shapes.svg`、`text.svg`、`gradient.svg`、
`namespaces.svg`、`comments.svg`、`unsafe.svg`）与 M2 渲染场景
（`testdata/render/*.svg` + `*.rgba` 期望图）。场景快照按 64×64 逐像素比较，容差 ≤ 1。

```bash
cd f_svg
cjpm test
```

大样本冒烟使用仓库内 `.assets/README/module-dependencies.svg`（存在时执行，不存在时跳过）。
性能参考值见 [`doc/perf-baseline.md`](doc/perf-baseline.md)。

## M5 选择器能力

`CssSelector.parse(text)` 支持以下子集，并与 `SvgStyleResolver` 的级联、`querySelectorAll` 共用同一实现：

- 类型选择器、`*`、`#id`、`.class`；
- 属性选择器 `[attr]`、`[attr=v]`、`[attr~=v]`、`[attr|=v]`、`[attr^=v]`、`[attr$=v]`、`[attr*=v]`，值可用裸标识符、单引号或双引号，右方括号前可加 `i` 做 ASCII 大小写不敏感比较；
- 结构伪类 `:root`、`:first-child`、`:last-child`、`:only-child`、`:nth-child(An+B)`、`:first-of-type`、`:last-of-type`、`:nth-of-type(An+B)`、`:only-of-type`、`:empty`；`An+B` 接受 `odd` / `even` / 整数 / `n` / `-n+2`；
- 否定伪类 `:not(<简单选择器>)`，参数只能是单个简单选择器，嵌套与复合参数会被拒绝；
- 组合器：后代（空白）、子代 `>`、相邻兄弟 `+`、一般兄弟 `~`。

```cangjie
let selector = CssSelector.parse("g > rect:not(.skip)[data-role^=badge] + circle")
if (selector.matches(element)) {
    // ...
}
```

单条选择器最多 256 个简单选择器；超出时整条规则跳过并写 warning。

### @media 与 @font-face

- `@media <query-list> { rules }` 支持 `screen` / `all`、`and`、逗号「或」列表与
  `(min-width: Npx)` / `(max-width: Npx)`；宽度取渲染逻辑视口宽度（`SvgRenderOptions.width`
  优先，其次根元素宽度，再其次 300）；独立调用 `SvgStyleResolver.compute` 时可用
  `mediaWidth:` 指定。`print` 等其他媒体类型不匹配，不产生 warning；无法解析的查询跳过并记 warning。
- `@font-face` 只读取 `font-family`（必需）与可选的 `font-weight` / `font-style`，把该
  family 作为别名指向字体注册表中的同名 family；同名未注册时指向注册表的首个 family。
  `src` 不加载任何文件，只记一条 warning。别名只在本次渲染内生效，不写入调用方注册表。

### CSS 变量与 calc()

- `--name: value` 按元素继承，名称保留原始大小写；`var(--name, fallback)` 在归一化前展开，
  嵌套上限 8 层，循环引用与缺失且无 fallback 都使该声明无效并记 warning；fallback 内可再写 `var()`。
- `calc()` 支持 `+` / `-` / `*` / `/`、括号与 `px` / `%` / `em`，括号上限 16 层；
  `*` / `/` 至少一侧必须是数字，百分比与绝对长度不得混用。`calc()` 只用于
  `stroke-width`、`letter-spacing`、`word-spacing`、`font-size`、`stroke-dashoffset`，
  用在颜色或画笔上按非法值处理。
- 计算样式的初始值：`paint-order` 为 `fill stroke markers`（继承）、`mix-blend-mode` 为
  `normal`、`isolation` 为 `auto`、`transform-origin` 为 `0 0`、`transform-box` 为
  `view-box`、`direction` 为 `ltr`（继承）、`unicode-bidi` 为 `normal`、
  `font-kerning` 为 `auto`（继承）；非法值回退初始值并记 warning。

### 绘制顺序 paint-order

`paint-order` 是 `fill` / `stroke` / `markers` 的无重复有序子集，缺省
`fill stroke markers`。渲染树按该顺序发出命令；未列出的层按默认相对顺序追加到末尾，
marker 的派生位置、数量与朝向不变。

```xml
<svg xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="10" width="40" height="40"
        fill="orange" stroke="navy" stroke-width="6"
        style="paint-order: stroke fill"/>
</svg>
```

上例先画描边再画填充，重叠处显示填充。未声明 `paint-order` 的文档输出与 M4 逐字节一致；
非法值（未知关键字）回退默认顺序并记 warning。

### 混合模式与隔离

`mix-blend-mode` 支持 `normal` / `multiply` / `screen` / `overlay` / `darken` / `lighten` /
`color-dodge` / `color-burn` / `hard-light` / `soft-light` / `difference` / `exclusion`。
非 `normal` 的元素会先渲染到离屏层，再与父层在预乘 RGBA 域按 CSS 公式合成一次；
滤镜、`clip`、`clip-path`、`mask` 与组透明度的处理顺序与 M4 相同。

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
  <rect width="40" height="40" fill="#c86432"/>
  <rect width="40" height="40" fill="#808080" style="mix-blend-mode: multiply"/>
</svg>
```

上例中 `#808080` 与 `#c86432` 的 multiply 结果为约 `#643219`（`(100,50,25)`）。

`isolation: isolate` 建立隔离组：组内子元素只与组内已合成像素混合，不会读取组外内容；
`auto` 不额外隔离。缺少父图层时以透明背景作为混合背景。`feBlend` 使用的
`SvgBlendMode` 仍保持 5 个取值，不受影响。

### 投影 feDropShadow

`<feDropShadow>` 等价于「取输入 alpha → 高斯模糊 → 按 `dx` / `dy` 偏移 → 用
`flood-color` / `flood-opacity` 着色 → 与原图 source-over 合并」，复用既有模糊与合成实现。
缺省 `dx=2`、`dy=2`、`stdDeviation=2`、`flood-color=black`、`flood-opacity=1`；
负 `stdDeviation` 与非法颜色回退缺省值并记 warning。滤镜区域会在 `filterUnits` 结果上
按 `|dx| + 3σ`、`|dy| + 3σ` 外扩，再裁剪到画布。

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="60" height="60">
  <defs><filter id="shadow"><feDropShadow dx="2" dy="2" stdDeviation="2"/></filter></defs>
  <rect x="10" y="10" width="20" height="20" fill="red" filter="url(#shadow)"/>
</svg>
```

### 变换原点

`transform-origin` 接受 1–2 个值（长度、百分比、`left` / `center` / `right` / `top` /
`bottom`），单值补 `center`；`transform-box` 为 `view-box`（缺省，以最近视口为参考盒）或
`fill-box`（以元素包围盒为参考）。变换矩阵为 `T(origin) × M × T(-origin)`。

缺省 `0 0` + `view-box` 时直接使用原矩阵，输出与 M1–M4 逐字节一致；
`SvgGeometry.ctm` / `absoluteBounds` 新增 `styles:` 参数以在查询时解析原点。

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <rect x="30" y="30" width="20" height="20" fill="orange"
        transform="rotate(90)" transform-origin="40 40"/>
</svg>
```

### 上下文画笔 context-fill / context-stroke

`fill` / `stroke` 可取 `context-fill` / `context-stroke`，只在 `use` 展开的实例内有效：
解析为 `use.href` 目标元素的计算 `fill` / `stroke`，嵌套 `use` 取最近一层的帧。
无 `use` 上下文、或在普通元素上直接使用时回退 `none` 并记 warning；被引用元素自身为
`context-*` 时同样回退 `none`，不递归解析。解析顺序为先 `context-*`、再 `currentColor`，
两者不会同时生效。

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">
  <defs><g id="paint" fill="red"><rect width="20" height="20" fill="context-fill"/></g></defs>
  <use href="#paint"/>
</svg>
```

## M3 不做什么

- JPEG / WebP / GIF 解码、`feImage` 外部图像原语；
- `foreignObject` 内部 XHTML 语义；
- CSS 动画/过渡、伪元素（`::before` / `::after`）、`@supports` / `@layer` / `@container`；
- 双向文本、连字、字形替换、内置 CJK 字体、TTF/OTF 解析（M5 起支持基础连字与字距，见对应章节）；
- SMIL 扩展（`animateColor`、事件驱动动画、脚本）与文本 `textPath` 的 `side` 属性；
- GPU / native 光栅后端。

未注册字体或字体缺字时，文本包围盒返回 `None`；渲染仍绘制占位字形并写 warning。

## 已知 API 约定

- `SvgPaint` 的引用工厂方法名为 `referencing(id, fallback:)`（与字段 `reference` 区分）；
  `id` 可带或不带 `#`，统一存为 `#id`，空 id 抛 `InvalidValue`。
- `SvgAspectAlign` 的无对齐取值名为 `NoAlign`（序列化为 `none`）。
- `attributes` / `children` / `warnings` 为只读遍历方便直接暴露为可变列表；写入请使用
  `setAttr` / `removeAttr` / `appendChild`，直接改列表会绕过缓存失效与 `parent` 维护。
  `warnings` 按契约只增，不应清空。
