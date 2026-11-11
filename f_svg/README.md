# f_svg

**SVG 1.1 核心 + 部分 SVG 2** 的纯仓颉实现，一条模块覆盖五件事：

| 链路 | 入口 | 结果 |
|---|---|---|
| 解析 | `SvgParser` | 类型化 DOM，未知元素与属性原样保留 |
| 样式 | `CssStyleSheet` / `SvgStyleResolver` | 计算样式树 |
| 渲染 | `SvgRenderer` | RGBA8 位图 / PNG |
| 动画 | `SvgTimeline` | 任意时刻的文档快照 |
| 生成 | `SvgBuilder` | 浏览器可直接播放的 SVG 文本/文件 |

不执行脚本、不接事件循环、不联网、不读字体/图片文件；渲染是**离线帧**，不是实时播放器。
XML 解析全部复用 [`f_xml`](../f_xml/README.md)。

> 设计、取舍与里程碑见 [`doc/f_svg模块设计.md`](doc/f_svg模块设计.md)。

## 依赖与安装

```
f_svg
├── f_xml     XML 1.0 解析、DOM、命名空间、XmlWriter、实体安全上限
└── f_base    BaseException / StringGenerator
```

模块随 fountain 仓库发布，版本与仓库一致（当前 `1.3.17`）：

```toml
[dependencies]
  "fountain::f_svg" = { path = "../fountain/f_svg" }
```

或在已配置中心仓时使用 `"fountain::f_svg" = "1.3.17"`，并在仓库根 `.modules` 登记 `f_svg`。

## 快速开始

### 1. 解析 → 渲染 PNG

```cangjie
import fountain::f_svg.*
import std.fs.Path

let document = SvgParser.parse(Path("input.svg"))
let bitmap = SvgRenderer(
    options: SvgRenderOptions(width: 800, height: 600, background: SvgColor.White)
).render(document)
bitmap.savePng(Path("output.png"))
```

### 2. 构造 → 保存 SVG

```cangjie
import fountain::f_svg.*
import std.fs.{File, Path}

let document = SvgParser.parse(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
    "<rect x=\"10\" y=\"10\" width=\"40\" height=\"40\" fill=\"#09f\"/></svg>"
)
let rect = document.elementsByTag("rect")[0]
rect.setAttr("fill", "#f60")

let text = writeSvgString(document, options: SvgWriteOptions(indent: Some("  ")))
File.writeTo(Path("edited.svg"), text.toArray())
```

### 3. 生成可播放动画

```cangjie
import fountain::f_svg.*

SvgBuilder(200.0, 100.0)
    .rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)
    .fill("#3366cc")
    .animate(
        attribute: "x",
        from: "10",
        to: "150",
        dur: "2s",
        begin: SvgBegin.offset(0.0),
        repeatCount: "indefinite"
    )
    .save("card.svg")
```

输出含 XML 声明与 `xmlns`，浏览器打开即渲染并播放；`save` 也可换成
`toSvgString()` / `write(output: OutputStream)` / `save(file: File)`。

## 已实现的 SVG 特性

状态说明：**支持** = 有实现与用例覆盖；**部分** = 有明确边界（见说明）；**不支持** = 见文末清单。

### 文档、解析与序列化

| 特性 | 状态 | 说明 |
|---|---|---|
| XML 1.0 / 命名空间 / DOCTYPE / 实体 | 支持 | 经 `f_xml`；外部 DTD 与外部实体永不加载 |
| SVG 根属性 | 支持 | `width` / `height` / `viewBox` / `preserveAspectRatio`；`version` / `baseProfile` / `zoomAndPan` 只存值 |
| 嵌套 `svg`、`g`、`defs`、`symbol`、`use`、`switch`、`a`、`view` | 支持 | `switch` 只选第一个满足条件的子元素 |
| 未知元素 / 未知属性 | 支持 | 保留前缀、URI、子树与原始属性，不丢弃 |
| 注释 / PI / CDATA | 支持 | 解析保留，序列化按结构写回 |
| 输入形式 | 支持 | 文本、字节、流、`Path`、`XmlDocument`；`parseAuto` 按 gzip 魔数识别 SVGZ |
| 生成 / 写回 | 支持 | `SvgWriter` / `writeSvgString`；未知内容与 `href` 读写形式可配置 |
| SVGZ | 支持 | `parseGzip` / `writeGzip`；解压上限默认 64 MiB |
| 安全过滤 | 支持 | 默认移除 `<script>`、`on*`、外部 `href`；元素数 1,000,000、深度 512 硬上限 |

### 图形与路径

| 特性 | 状态 | 说明 |
|---|---|---|
| `rect`（含 `rx` / `ry`） | 支持 | |
| `circle` / `ellipse` / `line` / `polyline` / `polygon` | 支持 | |
| `path` | 支持 | `M L H V C S Q T A Z` 绝对与相对写法 |
| `pathLength` | 支持 | 校准虚线、虚偏移与 `textPath` 绝对 `startOffset` |
| 填充规则 | 支持 | `fill-rule` / `clip-rule`：`nonzero` / `evenodd` |
| `use` / `symbol` | 支持 | 含 `x` / `y`、`href` 继承与实例化 |
| `switch` | 支持 | `systemLanguage` 与 `SvgRenderOptions.languages` 前缀匹配 |
| 嵌套视口 | 支持 | 嵌套 `svg` 的 `viewBox` / `preserveAspectRatio` |
| `transform` | 支持 | `translate` / `scale` / `rotate` / `skewX` / `skewY` / `matrix` 列表 |
| 根 `width` / `height: auto` | 支持 | 按内容包围盒与 `viewBox` 比例推导 |
| 几何查询 | 支持 | `getBBox` / `getCTM` / `getScreenCTM` / `absoluteBounds` |

### 样式与 CSS

| 特性 | 状态 | 说明 |
|---|---|---|
| 呈现属性 / `style` / `<style>` | 支持 | 按优先级与 `!important` 参与级联，支持继承 |
| 选择器 | 支持 | 类型、`*`、`#id`、`.class`、属性选择器、结构伪类、`:not`、四种组合器 |
| 结构伪类 | 支持 | `:root` / `:first-child` / `:last-child` / `:only-child` / `:nth-child(An+B)` / `:first-of-type` / `:last-of-type` / `:nth-of-type` / `:only-of-type` / `:empty` |
| `:hover` / `:focus` | 部分 | 只做静态求值：`SvgRenderOptions.hoveredIds` / `focusedIds`；不接事件循环 |
| `@media` | 部分 | `screen` / `all`、`and`、逗号列表、`min-width` / `max-width`；其余媒体特性忽略 |
| `@font-face` | 部分 | 只做 family 别名指向注册表；`src` 不加载文件 |
| `@color-profile` | 部分 | 解析名称与 `src`；不做 ICC 变换，按 sRGB 渲染 |
| CSS 变量 | 支持 | `--name` 继承、`var(--name, fallback)`，嵌套上限 8 层 |
| `calc()` | 部分 | `+ - * /`、括号、`px` / `%` / `em`；只用于若干长度属性 |
| `currentColor` | 支持 | |
| `context-fill` / `context-stroke` | 支持 | 只在 `use` 实例内有效 |
| `paint-order` | 支持 | `fill` / `stroke` / `markers` 任意无重复顺序 |
| `mix-blend-mode` | 支持 | `normal` / `multiply` / `screen` / `overlay` / `darken` / `lighten` / `color-dodge` / `color-burn` / `hard-light` / `soft-light` / `difference` / `exclusion` |
| `isolation` | 支持 | `auto` / `isolate` |
| `transform-origin` / `transform-box` | 部分 | `transform-box` 仅 `view-box` / `fill-box` |
| `display` / `visibility` / `opacity` | 支持 | 含组透明度与离屏合成 |
| `shape-rendering` / `text-rendering` / `color-rendering` / `color-interpolation` | 支持 | `auto` 保持既有输出；`linearRGB` 支持渐变在线性光下插值 |

### 填充、描边与标记

| 特性 | 状态 | 说明 |
|---|---|---|
| 颜色 | 支持 | 命名色、`#rgb` / `#rrggbb` / `#rrggbbaa`、`rgb()` / `rgba()` / `hsl()` / `hsla()` |
| 画笔回退 | 支持 | `fill="url(#g) red"` 形式的引用 + 回退 |
| 线性 / 径向渐变 | 支持 | `gradientUnits`、`gradientTransform`、`spreadMethod`、stop 透明度 |
| `pattern` | 支持 | `patternUnits` / `patternContentUnits` / `patternTransform` / `viewBox` / `href` 属性继承 |
| 描边属性 | 支持 | `stroke-width` / `linecap` / `linejoin` / `miterlimit` / `dasharray` / `dashoffset` |
| `stroke-linejoin` 扩展 | 支持 | `miter-clip` / `arcs` |
| `vector-effect` | 支持 | `none` / `non-scaling-stroke` / `non-scaling-size` / `non-rotation` / `fixed-position` |
| marker | 支持 | `marker-start` / `marker-mid` / `marker-end`、`markerUnits`、`orient`、`refX` / `refY`、`viewBox` |
| 上下文画笔 | 支持 | `context-fill` / `context-stroke` |

### 文本与字体

| 特性 | 状态 | 说明 |
|---|---|---|
| `text` / `tspan` / `textPath` | 支持 | `x` / `y` / `dx` / `dy` / `rotate` 列表、`text-anchor`、`textLength` / `lengthAdjust` |
| `textPath` | 支持 | `startOffset`、`side`、`method`、`spacing`；路径不足截断 warning |
| 基线 | 支持 | `dominant-baseline` / `alignment-baseline` / `baseline-shift` |
| 文本装饰 | 支持 | `underline` / `overline` / `line-through`、`double` / `dotted` / `dashed` / `wavy`、长属性与 `text-underline-position` |
| 竖排 | 部分 | `writing-mode: tb-rl`；无 `text-orientation` 与垂直度量 |
| 双向文本 | 部分 | UAX#9 子集（L/R/AL/EN/AN/WS/ON/B、数字、括号镜像）；无阿拉伯/印度系复杂整形 |
| 内置字体 | 部分 | Hershey 单线字体，覆盖 ASCII 大写、数字与标点；无小写与 CJK |
| TrueType | 部分 | `glyf` 简单/复合字形、`cmap` 4/12；不支持 CFF/OTF、WOFF、变量字体、hinting |
| 字距 | 支持 | `kern` format 0、`GPOS` Pair Adjustment format 1/2（仅 x advance） |
| 连字与上下文替换 | 部分 | GSUB Type 4（`liga` / `clig` / `hlig` / `dlig` / `calt` 开关）与 Type 5/6 format 3；其余 lookup 未实现 |
| `font-stretch` | 支持 | 9 关键字 + 百分比；无精确面时按 `请求值 / 选中面` 合成水平缩放 |
| `font-variant: small-caps` | 支持 | 大写字形缩放 0.8，advance 同步 |
| `font-size-adjust` | 支持 | 按 `OS/2.sxHeight / unitsPerEm` 修正 |
| `font-feature-settings` / `font-variant-ligatures` | 支持 | 4 字符 tag 开关，条目上限 64 |
| `font-kerning` | 支持 | `auto` / `normal` / `none` |
| 文本对齐 / 断行 | 部分 | 不做自动换行与两端对齐 |

### 图像、嵌入与外部资源

| 特性 | 状态 | 说明 |
|---|---|---|
| `image` + PNG | 支持 | `data:image/png` 或 `SvgImageResourceProvider`；单图 16 Mi 像素、单次渲染 64 Mi 像素 |
| `preserveAspectRatio` / `image-rendering` | 支持 | 最近邻 / 双线性 / 高质量取样 |
| SVGZ | 支持 | 见「文档」 |
| `foreignObject` | 部分 | 只提供 `SvgForeignObjectRenderer` 注入接口，库内不解析 XHTML |
| 外部文档 `use` | 部分 | `SvgExternalDocumentProvider`；外部文档不递归加载，单文档 16 MiB |
| `initialView` | 支持 | `#id` / `id`，覆盖初始视口 |
| JPEG / WebP / GIF / SVG-as-image | 不支持 | 只解码 PNG |
| 外部 `@import` / 外部图片 URL / 网络 | 不支持 | 安全边界内一律移除或跳过 |

### 滤镜

| 特性 | 状态 | 说明 |
|---|---|---|
| 滤镜框架 | 支持 | `filterUnits` / `primitiveUnits`、区域裁剪、`maxPixels` 预检查 |
| 颜色与合成 | 支持 | `feColorMatrix` / `feComponentTransfer` / `feBlend` / `feComposite` / `feMerge` / `feFlood` / `feDropShadow` |
| 模糊 / 形态 / 位移 | 支持 | `feGaussianBlur` / `feMorphology` / `feOffset` / `feDisplacementMap` |
| 纹理与卷积 | 支持 | `feTurbulence` / `feConvolveMatrix` / `feTile` |
| 光照 | 支持 | `feDiffuseLighting` / `feSpecularLighting` + 平行光 / 点光 / 聚光 |
| `feImage` | 部分 | 只接受 `data:image/png` 与 provider，与 `image` 共享解码预算 |

### 裁剪、蒙版与合成

| 特性 | 状态 | 说明 |
|---|---|---|
| `clip-path` | 支持 | `clipPath`、`clipPathUnits`、循环引用深度 64 |
| `clip` | 支持 | `rect()` 覆盖率蒙版，可与 `clip-path` 叠加 |
| `mask` | 支持 | `maskUnits` / `maskContentUnits`；亮度与 alpha 两种模式 |
| `mask-type` | 部分 | 只读元素属性，不参与 CSS 级联 |
| 组透明度 / 混合 / 隔离 | 支持 | `opacity`、`mix-blend-mode`、`isolation` |
| 处理顺序 | 支持 | 滤镜 → `clip` → `clip-path` → `mask` → 组透明度 → 混合 |

### 动画（SMIL）

| 特性 | 状态 | 说明 |
|---|---|---|
| 动画元素 | 支持 | `animate` / `animateTransform` / `animateMotion` / `set` / `discard` / `mpath` |
| 值来源 | 支持 | `from` / `to` / `by` / `values` |
| 插值 | 支持 | `calcMode`：`linear` / `discrete` / `spline` / `paced`；`keyTimes` / `keySplines` |
| 叠加 | 支持 | `additive` / `accumulate` |
| 时间 | 支持 | `dur` / `begin` / `end` / `repeatCount` / `repeatDur` / `min` / `max` / `fill` |
| `begin` 形式 | 部分 | 支持数值、`id.begin` / `id.end`、`indefinite`；多值、`id.end+1s`、`repeat(n)` 可生成并供浏览器播放，采样时 warning 后忽略 |
| 事件触发 | 部分 | `fireEvent(id, "click" / "mouseover" / ...)` 显式触发；无 UI 事件循环 |
| 时间源 | 支持 | `setCurrentTime` / `currentTime` / `pause` / `unpause` |
| 动画控制 | 支持 | `begin(id)` / `end(id)` / `discard`；`attributeType` CSS/XML |
| `restart` | 部分 | 可写回，采样不实现重启语义 |
| CSS 动画 / 过渡 / `@keyframes` | 不支持 | 只处理 SMIL |

### 交互与命中测试

| 特性 | 状态 | 说明 |
|---|---|---|
| `pointer-events` | 支持 | `auto` / `none` / `visiblePainted` / `visibleFill` / `visibleStroke` / `visible` / `painted` / `fill` / `stroke` / `all` / `bounding-box` |
| `cursor` | 部分 | 只校验关键字白名单并入样式；`url()` 不加载资源 |
| 命中测试 | 支持 | `SvgHitTest.hitTest(document/root, point)`，按填充轮廓 / 描边 / 文本字形判定 |
| 命中查询 | 支持 | `getIntersectionList` / `getEnclosureList` / `checkIntersection` / `checkEnclosure` |
| `elementsAt` / `elementAt` | 支持 | `public static` 入口；返回顶层在前的命中链 |
| 链接 / 导航 / 事件派发 | 不支持 | 安全边界 |

### DOM、查询与脚本接口

| 特性 | 状态 | 说明 |
|---|---|---|
| 文档查询 | 支持 | `elementById` / `elementsByTag` / `getElementsByClassName` / `querySelectorAll` / `views` / `anchors` |
| 节点编辑 | 支持 | `appendChild` / `insertBefore` / `removeChild`、`setAttr` / `removeAttr` |
| 变更监听 | 支持 | `addMutationListener` / `removeMutationListener`，同步回调，上限 32 |
| 视图状态 | 支持 | `SvgViewState(currentScale, currentTranslate)` 经渲染选项传入 |
| 工厂方法 | 支持 | `SvgPoint.create` / `SvgMatrix.create` / `SvgTransform.create` |
| 路径测量 | 支持 | `getTotalLength` / `getPointAtLength`（`SvgPath` 与 `SvgPathData`） |
| `getElementById` / `matches` / `closest` | 不支持 | 使用上表的文档查询方法 |

### SVG 2 收尾与生成 API

| 特性 | 状态 | 说明 |
|---|---|---|
| `vector-effect` 多值 | 支持 | 固定顺序 `non-scaling-size → non-rotation → fixed-position` |
| `stroke-linejoin: miter-clip / arcs` | 支持 | |
| 根 `width` / `height: auto` | 支持 | |
| `mesh` / `hatch` 渐变 | 不支持 | |
| `SvgBuilder` 链式构建 | 支持 | `rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path` / `text` / `use` / `image`，含样式、分组、动画、输出与 `save` |
| 类型化动画 | 支持 | `SvgAnimate` / `SvgAnimateTransform` / `SvgAnimateMotion` / `SvgSet` / `SvgMpath` |
| 时间表达式 | 支持 | `SvgBegin.offset` / `clock` / `at` / `after` / `repeatOf` / `event` / `indefinite` / `literal` / `join` |
| 生成枚举 | 支持 | `SvgRestart` / `SvgAnimationFill` / `SvgAnimationTransformType` / `SvgMotionRotate` |
| 渐变 / `defs` 构建 | 不支持 | 用 DOM API 或先写 `defs` 再交给 `SvgBuilder` 输出 |

## 使用指南

### 解析

```cangjie
let fromText = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
let fromBytes = SvgParser.parse(bytes)
let fromPath = SvgParser.parse(Path("logo.svg"))
let fromAuto = SvgParser.parseAuto(bytes)       // 自动识别 SVGZ
let fromXml = SvgParser.parse(xmlDocument)      // 复用已解析 XML DOM
```

严格模式：

```cangjie
let document = SvgParser.parse(text, options: SvgParseOptions(strict: true))
```

宽松模式把可恢复问题写入 `document.warnings`，不抛异常；语法错误仍抛
`SvgException(kind: Syntax)` 并带 1-based 行列。

### 遍历、查询与编辑

```cangjie
let root = document.root
let rect = document.elementById("hero").getOrThrow()
for (shape in document.elementsByTag("rect")) {
    println("${shape.id ?? "-"}: ${shape.attr("x") ?? "0"}")
}

let hits = root.querySelectorAll("g > rect:not(.skip) + circle")
let box = rect.getBBox(options: SvgBBoxOptions(stroke: true))
let ctm = rect.getCTM()
```

编辑后直接写回：

```cangjie
rect.setAttr("fill", "#f60")
rect.setAttr("stroke-width", "2")
let svg = writeSvgString(document)
```

序列化契约：属性顺序稳定、未知内容保留、`parse → write → parse` 结构等价；
同一文档连续两次紧凑写入字节一致。

### 样式

```cangjie
let sheet = CssStyleSheet.parse(
    "rect { fill: red } .badge { stroke: navy; stroke-width: 2 }"
)
let resolver = SvgStyleResolver(sheet: sheet)
let styles = resolver.compute(document.root)
let style = styles.get(rect)
```

`@media` 的宽度取 `SvgRenderOptions.width`，独立求值时可传 `mediaWidth:`。
CSS 变量、`calc()`、`@font-face` 别名与 `:hover` / `:focus` 静态状态均在上表范围内。

### 渲染

```cangjie
let options = SvgRenderOptions(
    width: 800,
    height: 600,
    background: SvgColor.White,
    samplesPerPixel: 4,
    devicePixelRatio: 1.0,
    antiAlias: SvgAntiAliasMode.Supersample
)
let bitmap = SvgRenderer(options: options).render(document)
bitmap.savePng(Path("out.png"))
```

- 输出 RGBA8、非预乘、行优先；同一文档 + 同一选项逐字节一致。
- `samplesPerPixel` 只允许 1 / 2 / 4；`maxPixels` 默认 64 Mi 像素。
- `antiAlias: Analytic` 使用解析覆盖率，输出与超采样不同。
- 常用选项：`fonts`、`images`、`languages`、`hoveredIds` / `focusedIds`、
  `initialView`、`foreignObjectRenderer`、`externalDocuments`、`viewState`。

### 动画采样

```cangjie
let timeline = SvgTimeline(document)
timeline.setCurrentTime(1.5)
let frame = timeline.sampleCurrent()             // 克隆原文档并应用 1.5s 状态

let bitmap = SvgRenderer(
    options: SvgRenderOptions(width: 800, height: 600)
).render(frame)
```

`sample(time)` 不修改原文档；同一时间点重复采样结果一致。需要交互触发时：

```cangjie
timeline.begin("fade-in")
timeline.fireEvent("pulse", "click")
timeline.end("pulse")
```

### 生成

```cangjie
let builder = SvgBuilder(200.0, 100.0, viewBox: SvgViewBox(0.0, 0.0, 200.0, 100.0))
builder
    .group(id: "card")
    .rect(x: 10.0, y: 10.0, width: 180.0, height: 80.0, rx: 12.0, ry: 12.0)
    .fill("#0d47a1")
    .end()
    .circle(cx: 100.0, cy: 50.0, r: 24.0)
    .fill("#ffb300")
    .animateTransform(
        attribute: "transform",
        transformType: SvgAnimationTransformType.Rotate,
        from: "0 100 50",
        to: "360 100 50",
        dur: "3s",
        begin: SvgBegin.offset(0.0),
        repeatCount: "indefinite"
    )
    .save("badge.svg")
```

`SvgBuilder` 的游标语义：`group()` 进入子组，`end()` 退回父级；形状、样式与动画都作用于
当前游标。输出方式：

```cangjie
let text = builder.toSvgString()                 // 紧凑字符串
builder.write(outputStream)                     // 只写并 flush，不关闭流
builder.save(Path("badge.svg"))                 // 文件系统失败抛 InvalidValue
// builder.save(file)                            // 写入已打开文件，只 flush，不关闭
```

扩展 `begin` 与类型化元素的写法：

```cangjie
builder.rect(x: 0.0, y: 0.0, width: 20.0, height: 20.0)
    .animate(
        attribute: "opacity",
        values: ["0", "1", "0"],
        dur: "2s",
        begin: SvgBegin.after("intro", 0.5),
        repeatCount: "2"
    )

builder.circle(cx: 40.0, cy: 40.0, r: 10.0)
    .animateMotion(mpath: "#orbit", dur: "4s", repeatCount: "indefinite")
```

### 安全选项

```cangjie
let options = SvgParseOptions(
    strict: false,
    security: SvgSecurityOptions(
        unsafePolicy: SvgUnsafePolicy.Remove,
        allowScript: false,
        allowEventAttributes: false,
        allowExternalReferences: false,
        allowDataImages: true,
        maxElements: 1_000_000,
        maxDepth: 512,
        maxDecompressedBytes: 64 * 1024 * 1024
    )
)
```

| 内容 | 默认 | 开关 |
|---|---|---|
| `<script>` | 移除 | `allowScript` / `unsafePolicy` |
| `on*` 事件属性 | 移除 | `allowEventAttributes` |
| `http:` / `https:` / `//` 引用 | 移除 | `allowExternalReferences` |
| `file:` / `javascript:` 引用 | 移除 | 仅 `unsafePolicy`，`allowExternalReferences` 不放行 |
| `data:` 图片 | 保留 | `allowDataImages` |
| `#id` 片段 | 保留 | 不可关闭 |
| 外部 DTD / 外部实体 | 永不加载 | 不可放开 |

`allowExternalReferences` 只作用于 `href`；样式里的 `url(...)` 由 `unsafePolicy` 控制。
规模上限在严格与宽松模式下都会硬失败，抛 `SvgException(kind: Limit)`。

### 错误与告警

```cangjie
try {
    let document = SvgParser.parse(untrusted)
} catch (error: SvgException) {
    println("${error.kind}: ${error.message} @ ${error.elementPath()}")
}
```

- 解析/构建错误：`SvgException`，`kind` 为 `Syntax` / `InvalidValue` / `Unsupported` / `Security` / `Limit`。
- 可恢复问题：写入 `document.warnings`，按契约只增不清空。
- 元素定位：`elementPath()` 形如 `/svg[1]/g[2]/rect[1]`；XML 语法错误保留行列。

## 值类型

所有值类型对规范形式可表示的值满足 `parse(toString(x)) == x`；`parse` 失败抛 `SvgException`，
`SvgLength` / `SvgColor` / `SvgPathData` 另提供 `tryParse`。

```cangjie
SvgLength.parse("1.5em")
SvgColor.parse("hsl(120,100%,50%)")            // #00ff00
SvgPaint.parse("url(#grad1) none")             // 引用 + 回退
SvgTransform.parse("translate(10,20) scale(2)").toMatrix()
SvgPathData.parse("M0 0 A5 5 0 0110 10")
SvgViewBox.parse("0 0 200 100")
SvgPreserveAspectRatio.parse("xMinYMax slice")
```

已知边界：绝对值 `< 1e-6` 的非零值归零，超过 6 位小数舍入。
百分比长度换算需显式指定基准轴：

```cangjie
let context = SvgLengthContext.of(200.0, 100.0)
toUserUnits(SvgLength(50.0, unit: SvgLengthUnit.Percent), SvgLengthAxis.Horizontal, context)
```

## 模型与序列化契约

- **属性顺序稳定**：解析按源顺序，构造按赋值顺序，序列化同序。
- **未知不丢弃**：非 SVG 命名空间元素保留为 `SvgUnknownElement`；未知属性原样保留。
- **结构等价往返**：`parse → write → parse` 的标签、URI、属性、文本、子节点顺序、
  注释 / PI / CDATA 一致；空元素写法、引号、缩进与 XML 声明不要求字节一致。
- **紧凑字节稳定**：连续两次紧凑写入结果相同。
- `href` 读取接受 `href` 与 `xlink:href`；写入形式由 `SvgWriteOptions.xlink` 决定。
- `writeSvgString` 只接受 UTF-8；其他字符集请直接用 `SvgWriter` 写字节流。

## 不支持与安全边界

| 类别 | 不实现 |
|---|---|
| 脚本与交互 | `<script>`、`on*` 事件、事件循环、链接激活/导航、光标资源加载 |
| 资源 | 网络与文件读取、外部 CSS `@import`、外部图片 URL、外部 DTD/实体 |
| 图像 | JPEG / WebP / GIF、SVG-as-image、`image-orientation`、ICC 色彩管理 |
| SVG 2 图形 | `mesh` / `hatch` 渐变、`mask-type` 进 CSS、`transform-box` 的 `content-box` / `border-box` |
| 字体 | CFF/OTF、WOFF/WOFF2、变量字体、hinting、`vmtx`/`vhea`、`text-orientation`、`font-variation-settings`、`font-optical-sizing` |
| 文本 | 复杂脚本整形（阿拉伯连写、印度系重排）、完整 UAX#9、自动换行/两端对齐、`text-emphasis`、`text-decoration-skip-ink` |
| OpenType | GPOS mark-to-base / mark-to-mark / cursive / 上下文定位；GSUB 单替换、多替换、交替替换、链式 format 1/2 |
| CSS | 动画 / 过渡 / `@keyframes` / `@property`、`@supports` / `@layer` / `@container`、伪元素、`:has()`、`:nth-child(of S)`、`@media` 的 `resolution` / `orientation` / `prefers-*` |
| 动画 | `restart` 采样语义、真实 syncbase / wallclock / accessKey 时钟、`animateColor`（已废弃） |
| 渲染 | 实时播放器、GPU/native 后端、浏览器逐像素一致 |

未注册字体或缺字时，文本包围盒返回 `None`，渲染绘制占位字形并 warning。

## 测试与样本

`testdata/` 提供基础样本（`basic-shapes.svg`、`text.svg`、`gradient.svg`、`namespaces.svg`、
`comments.svg`、`unsafe.svg`）、渲染场景（`testdata/render/*.svg` + `*.rgba`）与故事动图
（`testdata/story/*.svg`）。场景快照按 64×64 逐像素比较，容差 ≤ 1。

```bash
cd f_svg
cjpm test
cjpm build
```

当前 1230 条用例全绿，`f_svg` 构建 0 warning。性能参考见
[`doc/perf-baseline.md`](doc/perf-baseline.md)。

## 已知 API 约定

- `SvgPaint` 的引用工厂方法为 `referencing(id, fallback:)`；`id` 可带或不带 `#`。
- `SvgAspectAlign` 的无对齐取值名为 `NoAlign`（序列化为 `none`）。
- `SvgVectorEffect.NoEffect` 用静态属性而非 `None`，避免与 `Option.None` 冲突。
- 作者侧 `SvgBuilder` 实现在 `SvgAuthoringBuilder.cj`，与解析期内部 `SvgBuilder.cj` 不冲突。
- `SvgHitTest.elementsAt` / `elementAt` 为 `public static`（仓颉不允许同名静态/实例方法混载）。
- `attributes` / `children` / `warnings` 直接暴露为列表；写入请用 `setAttr` / `removeAttr` /
  `appendChild`，直接改列表会绕过缓存失效与 `parent` 维护。

## 更多文档

- 模块设计：[`doc/f_svg模块设计.md`](doc/f_svg模块设计.md)
- 各里程碑规格与验证报告：`doc/spec/`
- OpenSpec 主规格：`openspec/specs/svg-*`
- 生成 API 设计与示例：[`doc/f_svg-M7设计.md`](doc/f_svg-M7设计.md)

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`CssAttributeOperator`（enum）、`CssAttributeSelector`（struct）、`CssColorProfileRule`（class）、`CssCombinator`（enum）、`CssDeclaration`（struct）、`CssFontFaceRule`（class）、`CssLexer`（class）、`CssMediaFeature`（struct）、`CssMediaQuery`（class）、`CssMediaQueryItem`（class）、`CssPseudoClass`（enum）、`CssRule`（class）、`CssSelector`（class）、`CssSelectorPart`（struct）、`CssSimpleSelector`（struct）、`CssSimpleSelectorKind`（enum）、`CssSpecificity`（struct）、`CssStyleSource`（enum）、`CssToken`（struct）、`CssTokenKind`（enum）、`SvgAlignmentBaseline`（enum）、`SvgAnchorInfo`（class）、`SvgAnimationInfo`（class）、`SvgAnimationKind`（enum）、`SvgAntiAliasMode`（enum）、`SvgArcParams`（struct）、`SvgAttribute`（struct）、`SvgAutoSize`（class）、`SvgAutoSizeSize`（struct）、`SvgBaselineShift`（enum）、`SvgBidiClass`（enum）、`SvgBitmap`（class）、`SvgBlendMode`（enum）、`SvgBounds`（struct）、`SvgCalcMode`（enum）、`SvgChannelSelector`（enum）、`SvgCircle`（class）、`SvgClipCoverage`（class）、`SvgClipPathMasker`（class）、`SvgClipProperty`（class）、`SvgClipRect`（struct）、`SvgClock`（interface）、`SvgColorInterpolation`（enum）、`SvgColorMatrixType`（enum）、`SvgColorRendering`（enum）、`SvgCompositeOperator`（enum）、`SvgComputedStyle`（class）、`SvgComputedStyleTree`（class）、`SvgContainer`（class）、`SvgContainerKind`（enum）、`SvgCoordinateUnits`（enum）、`SvgCoverageMask`（class）、`SvgCrc32`（class）、`SvgCursor`（struct）、`SvgDirection`（enum）、`SvgDisplayCommand`（class）、`SvgDisplayCommandKind`（enum）、`SvgDisplayList`（class）、`SvgDocument`（class）、`SvgDominantBaseline`（enum）、`SvgEdgeMode`（class）、`SvgElement`（class）、`SvgEllipse`（class）、`SvgErrorKind`（enum）、`SvgFeBlend`（class）、`SvgFeColorMatrix`（class）、`SvgFeComponentTransfer`（class）、`SvgFeComposite`（class）、`SvgFeConvolveMatrix`（class）、`SvgFeDiffuseLighting`（class）、`SvgFeDisplacementMap`（class）、`SvgFeDistantLight`（class）、`SvgFeDropShadow`（class）、`SvgFeFlood`（class）、`SvgFeFunc`（class）、`SvgFeFuncA`（class）、`SvgFeFuncB`（class）、`SvgFeFuncG`（class）、`SvgFeFuncR`（class）、`SvgFeGaussianBlur`（class）、`SvgFeImage`（class）、`SvgFeMerge`（class）、`SvgFeMergeNode`（class）、`SvgFeMorphology`（class）、`SvgFeOffset`（class）、`SvgFePointLight`（class）、`SvgFeSpecularLighting`（class）、`SvgFeSpotLight`（class）、`SvgFeTile`（class）、`SvgFeTurbulence`（class）、`SvgFillRule`（enum）、`SvgFilter`（class）、`SvgFilterBuffer`（class）、`SvgFilterPrimitive`（class）、`SvgFilterRenderer`（class）、`SvgFont`（interface）、`SvgFontFeatures`（class）、`SvgFontKerning`（enum）、`SvgFontRegistry`（class）、`SvgFontStretch`（enum）、`SvgGeometry`（class）、`SvgGradient`（class）、`SvgGradientSampler`（class）、`SvgGroupCompositor`（class）、`SvgGzip`（class）、`SvgHersheyFont`（class）、`SvgImage`（class）、`SvgImageRendering`（enum）、`SvgInteractionState`（class）、`SvgInterpolator`（class）、`SvgLengthAdjust`（enum）、`SvgLengthAxis`（enum）、`SvgLengthContext`（struct）、`SvgLengthUnit`（enum）、`SvgLightingPrimitive`（class）、`SvgLine`（class）、`SvgLineCap`（enum）、`SvgLineJoin`（enum）、`SvgLinearGradient`（class）、`SvgListSeparator`（enum）、`SvgManualClock`（class）、`SvgMarker`（class）、`SvgMarkerExpander`（class）、`SvgMarkerInstance`（class）、`SvgMarkerOrient`（enum）、`SvgMarkerUnits`（enum）、`SvgMasker`（class）、`SvgMixBlendMode`（enum）、`SvgMorphologyOperator`（enum）、`SvgMutationEvent`（class）、`SvgMutationKind`（enum）、`SvgMutationListener`（class）、`SvgNamespaces`（class）、`SvgNode`（enum）、`SvgNumberList`（struct）、`SvgOverflow`（enum）、`SvgPaintKind`（enum）、`SvgPaintLayer`（enum）、`SvgPaintOrder`（class）、`SvgPathCommand`（struct）、`SvgPathCommandKind`（enum）、`SvgPathLength`（class）、`SvgPattern`（class）、`SvgPatternSampler`（class）、`SvgPngDecoder`（class）、`SvgPngEncoder`（class）、`SvgPointList`（struct）、`SvgPointerEvents`（enum）、`SvgPolygon`（class）、`SvgPolyline`（class）、`SvgPreserveAspectRatio`（struct）、`SvgRadialGradient`（class）、`SvgRasterizer`（class）、`SvgRect`（class）、`SvgRenderTreeBuilder`（class）、`SvgRgba`（struct）、`SvgRoot`（class）、`SvgShape`（class）、`SvgShapeRendering`（enum）、`SvgSpreadMethod`（enum）、`SvgStop`（class）、`SvgStrokeOutliner`（class）、`SvgStrokeStyle`（struct）、`SvgSwitch`（class）、`SvgTag`（class）、`SvgText`（class）、`SvgTextAnchor`（enum）、`SvgTextBaseline`（class）、`SvgTextDecoration`（struct）、`SvgTextDecorationGeometry`（class）、`SvgTextDecorationSpec`（class）、`SvgTextDecorationStyle`（enum）、`SvgTextElement`（class）、`SvgTextGlyph`（class）、`SvgTextLayout`（class）、`SvgTextPath`（class）、`SvgTextPathLayout`（class）、`SvgTextPathMethod`（enum）、`SvgTextPathSide`（enum）、`SvgTextPathSpacing`（enum）、`SvgTextPlacement`（class）、`SvgTextRenderer`（class）、`SvgTextRendering`（enum）、`SvgTextUnderlinePosition`（enum）、`SvgTransferFunctionType`（enum）、`SvgTransformBox`（enum）、`SvgTransformOp`（enum）、`SvgTrueTypeFont`（class）、`SvgTspan`（class）、`SvgTurbulenceType`（enum）、`SvgUnicodeBidi`（enum）、`SvgUnsafePolicy`（enum）、`SvgUse`（class）、`SvgVectorEffect2`（class）、`SvgView`（class）、`SvgViewport`（struct）、`SvgViewportTransform`（struct）、`SvgWritingMode`（enum）、`SvgZoomAndPan`（enum）、`public static func count(): Int64`、`formatSvgNumber`（func）、`renderToPng`（func）、`public static func reset(): Unit`、`svgBidiClass`（func）、`svgMirrorBidiCodePoint`（func）、`svgSetInlineStyleProperty`（func）、`table`（func）
- `CssAttributeSelector`：`let caseInsensitive: Bool`、`let op: CssAttributeOperator`、`let value: ?String`
- `CssDeclaration`：`let value: String`
- `CssFontFaceRule`：`let family: String`、`let srcPresent: Bool`、`let weight: ?String`
- `CssLexer`：`tokenize`（func）
- `CssMediaFeature`：`let isMinWidth: Bool`
- `CssMediaQuery`：`let items: Array<CssMediaQueryItem>`
- `CssMediaQueryItem`：`let features: Array<CssMediaFeature>`、`mediaType`（let）
- `CssRule`：`let declarations: Array<CssDeclaration>`、`let selectors: Array<CssSelector>`、`specificity`（func）
- `CssSelector`：`let combinators: Array<CssCombinator>`、`let parts: Array<CssSelectorPart>`、`let specificity: CssSpecificity`
- `CssSelectorPart`：`let classes: Array<String>`、`let combinator: ?CssCombinator`、`simples`（let）、`let typeName: ?String`
- `CssSpecificity`：`let classes: Int64`、`compareTo`（func）、`let ids: Int64`、`plus`（func）、`let types: Int64`、`zero`（let）
- `CssStyleSheet`：`colorProfiles`（let）、`fontFaces`（let）、`let rules: Array<CssRule>`
- `SvgAnchorInfo`：`let element: SvgElement`、`let target: String`
- `SvgAnimationInfo`：`let attributeName: String`、`let targetId: ?String`
- `SvgArcParams`：`let largeArc: Bool`、`let sweep: Bool`、`let xAxisRotation: Float64`
- `SvgAttribute`：`let value: String`
- `SvgAutoSize`：`static func rootSize(`
- `SvgBBoxOptions`：`clipped`（let）
- `SvgBitmap`：`pixel`（func）、`let pixels: Array<Byte>`、`setPixel`（func）、`writePng`（func）
- `SvgBounds`：`inflate`（func）、`intersect`（func）、`isEmpty`（func）、`union`（func）
- `SvgBuilder`：`className`（func）、`fillOpacity`（func）、`strokeOpacity`（func）、`strokeWidth`（func）
- `SvgClipRect`：`let bottom: ?Float64`、`let left: ?Float64`、`let right: ?Float64`、`let top: ?Float64`
- `SvgColor`：`Black`（let）、`static let Transparent = SvgColor(0, 0, 0, alpha: 0.0)`、`let alpha: Float64`、`let blue: UInt8`、`let green: UInt8`
- `SvgComputedStyle`：`alignmentBaseline`（func）、`baselineShift`（func）、`clipRect`（func）、`clipRule`（func）、`colorInterpolation`（func）、`colorProfile`（func）、`colorRendering`（func）、`direction`（func）、`dominantBaseline`（func）、`fillOpacity`（func）、`fillRule`（func）、`fontFamily`（func）、`fontFeatures`（func）、`fontKerning`（func）、`fontSize`（func）、`fontSizeAdjust`（func）、`fontStretch`（func）、`fontStyle`（func）、`fontVariantCaps`（func）、`fontVariantLigatures`（func）、`fontWeight`（func）、`imageRendering`（func）、`isolationIsolate`（func）、`letterSpacing`（func）、`mixBlendMode`（func）、`overflowMode`（func）、`paintOrder`（func）、`pathLengthValue`（func）、`pointerEvents`（func）、`shapeRendering`（func）、`let source: CssStyleSource`、`sourceOf`（func）、`stopColor`（func）、`stopOpacity`（func）、`strokeDashArray`（func）、`strokeDashOffset`（func）、`strokeLineCap`（func）、`strokeLineJoin`（func）、`strokeMiterLimit`（func）、`strokeOpacity`（func）、`strokeWidth`（func）、`textAnchor`（func）、`textDecoration`（func）、`textDecorationColor`（func）、`textDecorationSpec`（func）、`textDecorationStyle`（func）、`textDecorationThickness`（func）、`textRendering`（func）、`textUnderlinePosition`（func）、`transformBox`（func）、`unicodeBidi`（func）、`vectorEffect`（func）、`vectorEffects`（func）、`wordSpacing`（func）、`writingMode`（func）
- `SvgCoverageMask`：`applyTo`（func）、`let coverage: Array<Byte>`、`coverageAt`（func）
- `SvgCrc32`：`static func checksum(bytes: Array<Byte>): Int64`、`update`（func）
- `SvgDisplayCommand`：`aspect`（let）、`blendMode`（let）、`bounds`（let）、`clipBounds`（let）、`clipQuads`（let）、`let clipRect: ?SvgBounds`、`filter`（let）、`isolated`（let）、`nonScalingStroke`（let）、`paintOverride`（let）、`let tag: String`、`let textElement: ?SvgTextElement`
- `SvgDisplayList`：`let commands: Array<SvgDisplayCommand>`、`let logicalHeight: Float64`、`let logicalWidth: Float64`
- `SvgDocument`：`var declaration: ?XmlDeclaration = None`、`var doctype: ?DocTypeInfo = None`、`let epilog = ArrayList<SvgNode>()`、`parseOptions`（var）、`let prolog = ArrayList<SvgNode>()`
- `SvgEdgeMode`：`Duplicate`（let）、`static let NoEdge = SvgEdgeMode(2)`、`static let Wrap = SvgEdgeMode(1)`
- `SvgElement`：`appendElement`（func）、`appendText`（func）、`childrenOf`（func）、`let namespace: String`、`let tag: String`
- `SvgException`：`let column: Int64`
- `SvgFeComponentTransfer`：`functionFor`（func）
- `SvgFeMerge`：`inputs`（prop）
- `SvgFilter`：`primitives`（prop）
- `SvgFilterBuffer`：`let pixels: Array<Byte>`
- `SvgFilterRenderer`：`apply`（func）、`region`（func）
- `SvgFontFeatures`：`static let MAX_ENTRIES: Int64 = 64`、`enabled`（func）
- `SvgFontRegistry`：`defaultRegistry`（func）、`derived`（func）、`register`（func）、`resolve`（func）
- `SvgFontStretch`：`percentage`（func）
- `SvgGeometry`：`bounds`（func）、`screenCTM`（func）、`strokeBounds`（func）
- `SvgGroupCompositor`：`composite`（func）、`createLayer`（func）
- `SvgGzip`：`compress`（func）、`decompress`（func）
- `SvgHersheyFont`：`advance`（func）、`ascent`（func）、`descent`（func）、`glyphBounds`（func）、`glyphPath`（func）
- `SvgInterpolator`：`static func numeric(from: Float64, to: Float64, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): Float64`、`numericList`（func）、`splineValue`（func）、`stringValue`（func）
- `SvgLength`：`isAbsolute`（func）、`let value: Float64`
- `SvgLengthContext`：`let dpi: Float64`、`let fontSize: Float64`、`let viewportHeight: Float64`、`let viewportWidth: Float64`
- `SvgLightingPrimitive`：`lightSource`（func）、`lightSources`（func）
- `SvgLineJoin`：`attrName`（func）
- `SvgManualClock`：`now`（func）、`stop`（func）
- `SvgMarkerExpander`：`expand`（func）
- `SvgMarkerInstance`：`let viewportHeight: Float64`、`viewportMatrix`（let）、`let viewportWidth: Float64`
- `SvgMatrix`：`apply`（func）、`let b: Float64`、`let c: Float64`、`let d: Float64`、`determinant`（func）、`let e: Float64`、`let f: Float64`、`identity`（let）、`invert`（func）、`rotateAround`（func）
- `SvgMutationEvent`：`let attributeName: ?String`、`let element: SvgElement`、`let newValue: ?String`、`let oldValue: ?String`
- `SvgMutationListener`：`func onMutation(event: SvgMutationEvent): Unit`
- `SvgNamespaces`：`static let SVG: String =`、`static let XLINK: String =`、`static let XML: String =`
- `SvgOverflow`：`clips`（func）
- `SvgPaint`：`static let CurrentColor = make(SvgPaintKind.CurrentColor)`、`let reference: ?String`
- `SvgPaintOrder`：`defaultOrder`（func）、`let layers: Array<SvgPaintLayer>`
- `SvgParseOptions`：`xml`（let）
- `SvgPathCommand`：`let relative: Bool`
- `SvgPathData`：`let commands: Array<SvgPathCommand>`、`pointAtLength`（func）、`totalLength`（func）
- `SvgPathLength`：`static func ratio(element: SvgElement, actualLength: Float64): Float64`
- `SvgPngDecoder`：`static func decode(bytes: Array<Byte>): SvgBitmap`
- `SvgPngEncoder`：`static func encode(bitmap: SvgBitmap): Array<Byte>`
- `SvgPointList`：`let points: Array<SvgPoint>`
- `SvgPreserveAspectRatio`：`Default`（let）、`let align: SvgAspectAlign`、`let slice: Bool`
- `SvgRasterizer`：`fillGradient`（func）、`strokeGradient`（func）
- `SvgRenderOptions`：`validatePixels`（func）
- `SvgRenderTreeBuilder`：`build`（func）、`buildElement`（func）
- `SvgRenderer`：`renderToPng`（func）
- `SvgRgba`：`let alpha: Float64`、`let blue: Float64`、`let green: Float64`、`over`（func）、`transparent`（let）
- `SvgStrokeOutliner`：`outlineContours`（func）、`outlineElement`（func）、`outlinePolyline`（func）
- `SvgStrokeStyle`：`let dashArray: Array<Float64>`、`let dashOffset: Float64`、`let lineCap: SvgLineCap`、`let lineJoin: SvgLineJoin`、`let miterLimit: Float64`
- `SvgStyleResolver`：`computeElement`（func）、`fontFaces`（let）
- `SvgSwitch`：`select`（func）
- `SvgTag`：`isKnown`（func）
- `SvgTextDecoration`：`isNone`（func）、`let lineThrough: Bool`
- `SvgTextDecorationGeometry`：`lineThroughOffset`（func）、`overlineOffset`（func）、`thickness`（func）、`underlineOffset`（func）
- `SvgTextDecorationSpec`：`let lines: SvgTextDecoration`、`let thickness: ?SvgLength`、`let underlinePosition: SvgTextUnderlinePosition`
- `SvgTextGlyph`：`let advance: Float64`、`angle`（let）、`ascent`（let）、`let codePoint: Int64`、`descent`（let）、`let fontSize: Float64`
- `SvgTextLayout`：`let advance: Float64`、`let bounds: ?SvgBounds`、`let glyphs: Array<SvgTextGlyph>`
- `SvgTextPathLayout`：`place`（func）
- `SvgTextPlacement`：`angle`（let）、`originX`（let）、`let originY: Float64`
- `SvgTextRenderer`：`decorationOutline`（func）、`layout`（func）、`outline`（func）
- `SvgTimeline`：`animations`（func）、`duration`（func）
- `SvgTransform`：`identity`（let）、`let operations: Array<SvgTransformOp>`
- `SvgTrueTypeFont`：`advance`（func）、`ascent`（func）、`descent`（func）、`glyphBounds`（func）、`glyphPath`（func）、`load`（func）
- `SvgUnknownElement`：`let rawName: QName`
- `SvgVectorEffect`：`static prop FixedPosition: SvgVectorEffect`、`static prop NonRotation: SvgVectorEffect`、`static prop NonScalingSize: SvgVectorEffect`、`static prop NonScalingStroke: SvgVectorEffect`、`strokeScale`（func）
- `SvgVectorEffect2`：`apply`（func）
- `SvgViewBox`：`let minX: Float64`、`let minY: Float64`
- `SvgViewport`：`forView`（func）、`nestedTransform`（func）、`nestedViewport`（func）
- `SvgWriteOptions`：`let cdata: CdataMode`、`let charset: Charset`、`let trailingNewline: Bool`、`let xmlDeclaration: Bool`
- `SvgWriter`：`close`（func）、`flush`（func）
- `SvgWritingMode`：`isVertical`（func）
