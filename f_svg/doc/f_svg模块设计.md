# f_svg —— 仓颉 SVG 模块设计（基于 f_xml）

> 目标：在 `fountain::f_xml` 之上提供 **SVG 1.1** 的类型化模型、解析、生成与消费能力。  
> **M1** 只负责「把 SVG 文档讲清楚、改对、写回去」：值类型、模型、解析、生成、安全过滤，  
> 不做渲染、不做 CSS 级联、不做动画。  
> **M2** 的 CSS 级联、几何包围盒、CPU 光栅渲染、PNG 与 SMIL 动画见
> [`f_svg-M2设计.md`](f_svg-M2设计.md)。

---

## 0. 结论摘要

| 项目       | 结论                                                             |
| -------- | -------------------------------------------------------------- |
| 模块名 / 包名 | `f_svg` / `fountain::f_svg`                                    |
| 唯一硬依赖    | `fountain::f_xml`（DOM、命名空间、生成器、安全上限）                           |
| 定位       | SVG 1.1 文档的**值类型 + 类型化 DOM + 解析器 + 生成器**；不渲染                   |
| 解析入口     | `SvgParser.parse(input / bytes / text / path)`，内部走 `f_xml` DOM |
| 生成入口     | `SvgWriter`，内部构造 `XmlDocument` 交给 `f_xml::XmlWriter`           |
| 类型化程度    | 形状 / 文本 / 渐变 / 引用有独立类型；容器复用 `SvgElement`；未知内容无损保留              |
| 安全默认     | 默认移除 `<script>`、`on*` 事件属性、外部引用，并记录 warning                    |
| M1 范围    | 值类型、模型、解析、生成、安全过滤、往返一致性                                        |
| M2 范围    | CSS 解析与级联、几何包围盒与视口、CPU 软件光栅、描边 / 渐变 / 裁剪 / 蒙版、文本、PNG、SMIL 动画   |
| M3 范围    | 滤镜与 `fe*` 原语、图案、PNG 解码与 `<image>`、SVGZ、`textPath` / rotate、marker、解析覆盖率 AA |
| M4 范围    | `clip` / `overflow` / `vector-effect`、剩余滤镜原语与光照、`pattern` 视口、基线 / 装饰 / 竖排 / TTF、`view` / `switch` / 锚点、路径长度与 CTM API |
| M5 范围    | CSS 属性/伪类/兄弟选择器与 `@media` / `@font-face` / 变量 / `calc()`、`paint-order` / 混合模式 / `feDropShadow` / `transform-origin` / `context-*`、`kern` / `GPOS` / `GSUB` / bidi、元素级 `getBBox` / `getCTM` / 查询 API |
| M6 范围    | 静态交互（pointer-events/cursor/:hover/:focus）、嵌入（foreignObject 注入/外部文档/initialView）、渲染提示与颜色、字体细节与 GSUB 5/6、动画控制、DOM 查询与变更监听、SVG 2 收尾（vector-effect/linejoin/auto） |

---

## 1. 定位与边界

### 1.1 与 `f_xml` 的关系

`f_svg` 是 `f_xml` 的**上层语义模块**，不是它的替代：

```
业务代码
   │
   ▼
f_svg       类型化 SVG 模型 / 值解析 / 安全检查 / 序列化编排
   │
   ▼
f_xml       XML 1.0 词法 / 语法 / DOM / 命名空间 / 实体 / 生成器
   │
   ▼
f_base      StringGenerator、BaseException 等基础设施
```

职责切割：

| 能力                        | 归属      | 理由                                     |
| ------------------------- | ------- | -------------------------------------- |
| XML 解析、字符编码、实体展开、DTD 安全上限 | `f_xml` | 已成熟（376 条单测 + xmlconf 2038 断言），不再实现第二套 |
| 命名空间展开与 `xmlns` 输出        | `f_xml` | `QName` + `XmlWriter` 已覆盖              |
| SVG 标签语义、属性类型、路径语法、颜色语法   | `f_svg` | 属于 SVG 规范，不应污染通用 XML 模块                |
| 安全过滤（脚本 / 外链 / 事件属性）      | `f_svg` | 属于 SVG 语义层策略                           |

**明确不做的事**：不把 SVG 知识塞进 `f_xml`；不在 `f_svg` 里自己写 XML 词法器。

### 1.2 做什么 / 不做什么

**做**（M1）：

- SVG 1.1 文档的**无损往返**：解析 → 修改 → 序列化，结构等价；
- 常用属性的**类型化访问**：长度、颜色、画笔、变换、路径、`viewBox`；
- 形状 / 文本 / 渐变 / `use` / `image` 的**独立类型**；
- 未知元素、未知属性、外部命名空间的**原样保留**；
- 面向不可信输入的**安全过滤**与**规模上限**；
- 解析 / 生成过程中的**可定位错误**（行、列、元素路径）。

**不做**（M1 不做，M2 纳入）：

- 渲染、光栅化（M2 实现，M1 只保证模型与序列化正确）；
- CSS 级联（M1 把 `<style>` 与 `style=""` 原样保留，M2 实现选择器与优先级）；
- 几何布尔运算、路径填充规则计算（M2 随渲染一起做）。

**后续里程碑不做**（M3 及以后）：

- JPEG / WebP / GIF 解码、`feImage` 外部图像原语；
- TTF/OTF 字体解析与内置 CJK 字体；
- `foreignObject` 内部语义（保留原始子树，不解释 XHTML）；
- GPU / native 光栅后端。

> 判断标准：M1 只负责「把文档讲清楚」；任何需要**像素**的能力都放到 M2 的渲染层。

### 1.3 依赖与版本

`f_svg/cjpm.toml`：

```toml
[dependencies]
  "fountain::f_base" = {path = "../f_base"}
  "fountain::f_xml" = {path = "../f_xml"}

[package]
  cjc-version = "1.2.0"
  name = "f_svg"
  organization = "fountain"
  output-type = "dynamic"
  version = "1.3.17"          # 与仓库当前版本一致，随发布流程统一升版
  compile-option = "--dy-std -O2"
  override-compile-option = "--dy-std -O2"
```

- 不引入第三方依赖；颜色名表、路径语法全部自研。
- `f_xml` 已是 `.modules [include]` 成员，发布顺序上 `f_svg` 排在其后。
- 只依赖 `std.collection`、`std.math` 等标准库，不依赖 `stdx`。

### 1.4 发布登记

- 根 `.modules` 的 `[include]` 增加 `f_svg`；
- 根 `cjpm.toml` 的 `[dependencies]` 增加 `"fountain::f_svg" = {path = "./f_svg"}`；
- 根 `README.md` / `README_en.md` 的「各模块详细文档」增加 `f_svg` 条目；
- **不登记**聚合根 `src/f_svg` shim：聚合根 shim 已冻结，新模块不进入。

---

## 2. 总体架构

### 2.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│ 公共 API 层                                                   │
│   SvgParser  SvgWriter  SvgDocument  SvgElement 及子类        │
├──────────────────────────────────────────────────────────────┤
│ 值类型层                                                      │
│   SvgLength  SvgColor  SvgPaint  SvgTransform  SvgPathData    │
│   SvgViewBox  SvgPreserveAspectRatio  SvgPointList            │
├──────────────────────────────────────────────────────────────┤
│ 语义映射层                                                    │
│   SvgTag 表驱动映射 / 属性读写 / 安全检查 / 错误定位           │
├──────────────────────────────────────────────────────────────┤
│ f_xml                                                         │
│   XmlParser  XmlDocument  XmlElement  QName  XmlWriter        │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 三条数据流

**解析**：

```
InputStream / String / bytes / Path
  → f_xml::XmlParser.parse(...)            （BOM / 编码嗅探 / 实体展开交给 f_xml）
  → XmlDocument（通用 DOM）
  → SvgParser 遍历 XmlElement            （标签映射 + 属性类型化 + 安全过滤）
  → SvgDocument（类型化模型）
```

**构造**：

```
new SvgRoot(...) / new SvgRect(...) / SvgElement("g")
  → appendChild / setAttr / 类型化 setter
  → SvgDocument
```

**生成**：

```
SvgDocument
  → SvgWriter 按模型递归构造 XmlDocument / XmlElement
  → f_xml::XmlWriter.write(...)           （转义 / 命名空间 / 缩进 / 编码交给 f_xml）
  → OutputStream / String
```

### 2.3 为什么模型不直接包 `XmlElement`

两种方案：

| 方案                         | 优点              | 缺点                                             |
| -------------------------- | --------------- | ---------------------------------------------- |
| A. 薄包装 `XmlElement`        | 代码少、天然无损        | 类型化访问需反复解析属性；直接改 raw 会让缓存失真；公开 API 泄漏 f_xml 细节 |
| B. 独立模型 + `toXmlElement()` | 类型安全、可独立演进、语义清晰 | 需要写映射代码；未知内容要显式保留                              |

**选 B**。理由：

1. `f_svg` 的公开 API 不应要求调用方理解 `QName`、`XmlNode`；
2. 类型化属性需要缓存与校验，包装方案会出现「raw 改了、缓存没改」的隐式状态；
3. 映射代码是**一次性**成本，且能让 `f_svg` 独立于 `f_xml` 的 DOM 结构演进。

无损保留通过 `SvgRawElement`（未知元素）与 `SvgElement.extraAttributes`（未知属性）实现。

---

## 3. 值类型层

所有值类型都遵守两条约定：

1. **`parse` 抛 `SvgException`，`tryParse` 返回 `?T`**；
2. **`toString` 输出规范形式**，且对规范形式可表示的值满足 `parse(toString(x)) == x`（往返自洽）。
   已知不保真边界：`|v| < 1e-6` 归零、超过 6 位小数被舍入。

### 3.1 `SvgLength`

```cangjie
public enum SvgLengthUnit <: Equatable<SvgLengthUnit> & ToString {
    | Number | Percent | Em | Ex | Px | Pt | Pc | Cm | Mm | In
}

public struct SvgLength <: Equatable<SvgLength> & ToString {
    public let value: Float64
    public let unit: SvgLengthUnit
    public init(value: Float64, unit!: SvgLengthUnit = SvgLengthUnit.Number)
    public static func parse(text: String): SvgLength
    public static func tryParse(text: String): ?SvgLength
    public func isAbsolute(): Bool
    public func toString(): String
}

public enum SvgLengthAxis { | Horizontal | Vertical | Diagonal }

public struct SvgLengthContext {
    public let viewportWidth: Float64
    public let viewportHeight: Float64
    public let fontSize: Float64       // 默认 16
    public let dpi: Float64            // 默认 96
    public static func of(width: Float64, height: Float64): SvgLengthContext
}

public func toUserUnits(length: SvgLength, axis: SvgLengthAxis, context: SvgLengthContext): Float64
```

解析规则：

| 输入                                           | 结果                               |
| -------------------------------------------- | -------------------------------- |
| `10`                                         | `10 Number`                      |
| `10px` / `10PX`                              | `10 Px`（单位大小写不敏感）                |
| `50%`                                        | `50 Percent`                     |
| `1.5em` / `2ex`                              | `Em` / `Ex`                      |
| `12pt` / `1pc` / `2.54cm` / `25.4mm` / `1in` | 对应单位                             |
| 空串 / `10foo` / `NaN` / `Inf`                 | 抛 `SvgException`（`InvalidValue`） |

换算规则：

| 单位            | 换算                                |
| ------------- | --------------------------------- |
| px / Number   | 原值                                |
| in            | `96 * dpi / 96`（默认 dpi=96 ⇒ 96）   |
| cm            | `96 / 2.54`                       |
| mm            | `96 / 25.4`                       |
| pt            | `96 / 72`                         |
| pc            | `16`                              |
| em            | `fontSize`                        |
| ex            | `fontSize / 2`（无字体度量时的约定值，文档明确声明） |
| %（Horizontal） | `viewportWidth / 100`             |
| %（Vertical）   | `viewportHeight / 100`            |
| %（Diagonal）   | `sqrt(w² + h²) / sqrt(2) / 100`   |

> `%` 的基准取决于属性语义（`x`/`width` 用水平，`y`/`height` 用垂直，`r` 用对角线）。  
> 这是 SVG 1.1 的既有约定，API 用 `SvgLengthAxis` 显式表达，不做隐式猜测。

`toString` 规范：整数不带小数点（`10`），小数去掉末尾 `0`（`1.5`），  
百分比与单位原样拼接（`50%`、`1.5em`）。

### 3.2 `SvgColor`

```cangjie
public struct SvgColor <: Equatable<SvgColor> & ToString {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: Float64          // 0.0 ~ 1.0
    public static let Black: SvgColor
    public static let White: SvgColor
    public static let Transparent: SvgColor
    public static func parse(text: String): SvgColor
    public static func tryParse(text: String): ?SvgColor
    public static func fromRgb(r: UInt8, g: UInt8, b: UInt8, alpha!: Float64 = 1.0): SvgColor
    public static func fromHsl(h: Float64, s: Float64, l: Float64, alpha!: Float64 = 1.0): SvgColor
    public func toString(): String
}
```

支持语法（不区分大小写）：

| 形式                 | 示例                       | 备注                              |
| ------------------ | ------------------------ | ------------------------------- |
| `#rgb` / `#rrggbb` | `#f00`、`#FF0000`         | 也接受 `#rrggbbaa`（CSS Color 4 扩展） |
| `rgb(r,g,b)`       | `rgb(255, 0, 0)`         | 分量可为 `0~255` 或 `0%~100%`        |
| `rgba(r,g,b,a)`    | `rgba(255,0,0,0.5)`      | alpha 为 `0~1` 或 `0%~100%`       |
| `rgb(r g b / a)`   | `rgb(255 0 0 / 50%)`     | CSS Color 4 空格 / 斜杠语法           |
| `hsl(h,s%,l%)`     | `hsl(120, 100%, 50%)`    | 色相可带 `deg`                      |
| `hsla(h,s%,l%,a)`  | `hsla(0, 100%, 50%, .5)` |                                 |
| 命名色                | `rebeccapurple`、`salmon` | CSS3 147 色 + `transparent`      |

- 命名色表以内置 `static` 数组存放，线性扫描 + 大小写归一；不引入 `HashMap` 初始化开销。
- `parse("none")` **失败**：`none` 是画笔关键字，不是颜色（见 `SvgPaint`）。
- `toString`：`alpha == 1` 输出 `#rrggbb`；alpha 可由 `0..255` 字节精确表示时输出 `#rrggbbaa`；其余输出 `rgba(r,g,b,a)`，`a` 保留最短表示。

### 3.3 `SvgPaint`

```cangjie
public enum SvgPaintKind { | None | CurrentColor | Color | Reference }

public struct SvgPaint <: ToString {
    public let kind: SvgPaintKind
    public let color: ?SvgColor       // kind == Color
    public let reference: ?String     // kind == Reference，形如 "#grad1" 的 URL 去壳结果
    public let fallback: ?SvgPaint    // kind == Reference 的可选回退
    public static let None: SvgPaint
    public static let CurrentColor: SvgPaint
    public static func of(color: SvgColor): SvgPaint
    public static func referencing(id: String, fallback!: ?SvgPaint = None): SvgPaint
    public static func parse(text: String): SvgPaint
}
```

解析规则：

| 输入                          | 结果                                      |
| --------------------------- | --------------------------------------- |
| `none`                      | `None`                                  |
| `currentColor`              | `CurrentColor`                          |
| `red` / `#f00` / `rgb(...)` | `Color`                                 |
| `url(#grad1)`               | `Reference("#grad1", None)`             |
| `url(#grad1) none`          | `Reference("#grad1", Some(None))`       |
| `url(#grad1) red`           | `Reference("#grad1", Some(Color(red)))` |
| `url("http://...")`         | 抛安全异常（外部引用，见第 7 节）                      |

**契约**：`url()` 内只接受**同文档片段**（`#id`）。外部 URL 由解析选项决定拒绝或剥离；  
`SvgPaint.parse` 本身不发起任何 I/O。

工厂 `referencing(id, fallback:)` 接受带或不带 `#` 的 id，统一存为 `#id`；空 id 抛 `InvalidValue`。

### 3.4 `SvgMatrix` 与 `SvgTransform`

```cangjie
public struct SvgPoint <: Equatable<SvgPoint> & ToString {
    public let x: Float64
    public let y: Float64
}

public struct SvgMatrix <: Equatable<SvgMatrix> & ToString {
    public let a: Float64
    public let b: Float64
    public let c: Float64
    public let d: Float64
    public let e: Float64
    public let f: Float64
    public static let identity: SvgMatrix
    public func multiply(that: SvgMatrix): SvgMatrix
    public func apply(point: SvgPoint): SvgPoint
    public func determinant(): Float64
    public func invert(): ?SvgMatrix
    public static func translate(tx: Float64, ty: Float64): SvgMatrix
    public static func scale(sx: Float64, sy: Float64): SvgMatrix
    public static func rotate(degrees: Float64): SvgMatrix
    public static func rotateAround(degrees: Float64, cx: Float64, cy: Float64): SvgMatrix
    public static func skewX(degrees: Float64): SvgMatrix
    public static func skewY(degrees: Float64): SvgMatrix
}

public enum SvgTransformOp {
    | Matrix(SvgMatrix)
    | Translate(Float64, Float64)
    | Scale(Float64, Float64)
    | Rotate(Float64, Float64, Float64)   // angle, cx, cy
    | SkewX(Float64)
    | SkewY(Float64)
}

public struct SvgTransform <: ToString {
    public let operations: Array<SvgTransformOp>
    public static let identity: SvgTransform
    public static func parse(text: String): SvgTransform
    public func toMatrix(): SvgMatrix
    public func toString(): String
}
```


**合成顺序**：`transform="A B C"` 的矩阵是 `A × B × C`，点按列向量右乘——  
即**最后写的变换最先作用于坐标**。这是 SVG 1.1 的定义，文档与测试用例都必须钉死。

示例：`translate(10,20) scale(2)` 作用于 `(1,1)` ⇒ `(10 + 2, 20 + 2) = (12,22)`。

解析细节：

- 变换名与括号之间允许空白；参数用逗号或空白分隔；
- `translate` 缺省 `ty = 0`；`scale` 缺省 `sy = sx`；`rotate` 允许 `(angle)` 或 `(angle, cx, cy)`；
- 不支持 `matrix` 之外的未知函数名：抛 `SvgException`（`InvalidValue`）；
- 空串 / 全空白 ⇒ `identity`。

### 3.5 `SvgPathData`

```cangjie
public enum SvgPathCommandKind {
    | MoveTo | LineTo | HorizontalLineTo | VerticalLineTo
    | CurveTo | SmoothCurveTo | QuadraticBezierTo | SmoothQuadraticBezierTo
    | ArcTo | ClosePath
}

public struct SvgPathCommand {
    public let kind: SvgPathCommandKind
    public let relative: Bool
    public let values: Array<Float64>
}

public struct SvgArcParams {
    public let rx: Float64
    public let ry: Float64
    public let xAxisRotation: Float64
    public let largeArc: Bool
    public let sweep: Bool
    public let x: Float64
    public let y: Float64
}

public class SvgPathData <: ToString {
    public let commands: Array<SvgPathCommand>
    public init(commands: Array<SvgPathCommand>)
    public static func parse(text: String): SvgPathData
    public static func tryParse(text: String): ?SvgPathData
    public func toString(): String
    public func toAbsolute(): SvgPathData
}
```

命令与参数个数：

| 命令    | 参数 | 说明                                             |
| ----- | -- | ---------------------------------------------- |
| `M/m` | 2  | 后续隐式重复按 `L/l` 处理                               |
| `L/l` | 2  |                                                |
| `H/h` | 1  |                                                |
| `V/v` | 1  |                                                |
| `C/c` | 6  |                                                |
| `S/s` | 4  |                                                |
| `Q/q` | 4  |                                                |
| `T/t` | 2  |                                                |
| `A/a` | 7  | `rx ry rotation large-arc-flag sweep-flag x y` |
| `Z/z` | 0  | 无参数；后续不得跟数字                                    |

**词法难点**（必须逐条写用例）：

1. 数字之间可以只有符号分隔：`M1-2` ⇒ `1`、`-2`；
2. 小数可以连写：`0.5.5` ⇒ `0.5`、`.5`；
3. 指数形式：`1e3`、`1E-3`；
4. 弧标志位只能是 `0` 或 `1`，可与后续数字连写：`A5 5 0 0110 10`；
5. 逗号与空白可混用，但**不允许**出现两个逗号；
6. 命令字母大小写同时决定绝对 / 相对；
7. `Z` 后可以继续 `M`；`Z` 后直接数字是错误；
8. 空路径 / 只有空白 ⇒ 合法空路径。

`toAbsolute()` 规则：

- 维护当前点 `(cx, cy)` 与子路径起点 `(sx, sy)`；
- `H/V` 转成 `L`；`S/T` 保持不变但坐标转绝对；
- `A` 的 `rx/ry/rotation/flags` 不变，只把终点转绝对；
- `Z` 后当前点回到子路径起点。

`toString` 规范：

- 每个命令一个字母 + 参数，参数间用空格分隔，命令之间用空格分隔；
- 相对命令保留小写；`toAbsolute` 后全部大写；
- 数字用 `SvgNumber.format`（见 §3.7）。

### 3.6 `SvgViewBox` 与 `SvgPreserveAspectRatio`

```cangjie
public struct SvgViewBox <: Equatable<SvgViewBox> & ToString {
    public let minX: Float64
    public let minY: Float64
    public let width: Float64
    public let height: Float64
    public static func parse(text: String): SvgViewBox
    public func toString(): String
}

public enum SvgAspectAlign {
    | NoAlign | XMinYMin | XMidYMin | XMaxYMin
    | XMinYMid | XMidYMid | XMaxYMid
    | XMinYMax | XMidYMax | XMaxYMax
}

public struct SvgPreserveAspectRatio <: ToString {
    public let align: SvgAspectAlign
    public let slice: Bool
    public static let Default: SvgPreserveAspectRatio   // xMidYMid meet
    public static func parse(text: String): SvgPreserveAspectRatio
    public func toMatrix(viewBox: SvgViewBox, width: Float64, height: Float64): SvgMatrix
    public func toString(): String
}
```

`toMatrix` 按 SVG 1.1 算法：

```
sx = width / viewBox.width
sy = height / viewBox.height
align == NoAlign → scale = (sx, sy)
否则           → scale = (min(sx,sy), min(sx,sy))   // meet
                 scale = (max(sx,sy), max(sx,sy))   // slice
tx / ty 按 XMin/XMid/XMax、YMin/YMid/YMax 计算剩余空间
结果 = translate(tx,ty) × scale(sx,sy) × translate(-minX,-minY)
```

- `width/height` 或 `viewBox` 宽高为 0 / 负数 ⇒ 抛 `SvgException`（`InvalidValue`）；
- `parse` 接受 `none`、`xMidYMid`、`xMinYMax slice` 等；未知值抛错；
- `none slice` 保留 `slice` 语义，`toString` 输出 `"none slice"`，保证往返。

### 3.7 数值与列表

```cangjie
public func formatSvgNumber(value: Float64): String

public struct SvgPointList <: ToString {
    public let points: Array<SvgPoint>
    public static func parse(text: String): SvgPointList
    public func toString(): String
}

public struct SvgNumberList <: ToString {
    public let values: Array<Float64>
    public static func parse(text: String, separator!: SvgListSeparator = SvgListSeparator.CommaOrSpace): SvgNumberList
    public func toString(): String
}
```

`formatSvgNumber` 契约：

- `NaN` / `±Inf` ⇒ 抛 `SvgException`（`InvalidValue`）；
- `-0.0` 输出 `0`；
- 整数输出不带 `.0`；
- 非整数最多保留 6 位小数，去掉末尾 `0`；
- 绝对值 `< 1e-6` 且非零 ⇒ 输出 `0`（避免 `1e-9` 噪声）；
- 不使用科学计数法（SVG 属性里虽允许，但规范形式更利于 diff）。

`SvgPointList` 用于 `polyline/polygon` 的 `points`，解析规则与路径数字一致，  
但只接受成对的 `x y`；奇数个数字 ⇒ `InvalidValue`。

---

## 4. 模型层

### 4.1 节点模型

```cangjie
public enum SvgNode {
    | ElementNode(SvgElement)
    | TextNode(String)
    | CDataNode(String)
    | CommentNode(String)
    | PiNode(String, String)
}
```

与 `f_xml::XmlNode` 同构，便于双向映射；不引入抽象节点基类，保持 `match` 穷尽性。

### 4.2 `SvgElement` 基类

```cangjie
public open class SvgElement <: ToString {
    public let tag: String                  // 本地名，如 "g" / "rect"
    public let namespace: String            // 默认 SVG 命名空间
    public let attributes: ArrayList<SvgAttribute>
    public let children: ArrayList<SvgNode>
    public var parent: ?SvgElement

    public init(tag: String, namespace!: String = SvgNamespaces.SVG)

    // 通用属性
    public prop id: ?String
    public prop className: ?String          // class
    public prop style: ?String             // 原样保留，不解释
    public prop transform: ?SvgTransform

    // 原始属性访问（未知属性也走这里）
    public func attr(name: String): ?String
    public func attr(namespace: String, local: String): ?String
    public func setAttr(name: String, value: String): SvgElement
    public func setAttr(namespace: String, local: String, value: String): SvgElement
    public func removeAttr(name: String): Bool

    // 子节点
    public func appendChild(node: SvgNode): SvgElement
    public func appendElement(element: SvgElement): SvgElement
    public func appendText(text: String): SvgElement
    public func child(tag: String): ?SvgElement
    public func childrenOf(tag: String): ArrayList<SvgElement>
    public func text(): String              // 拼接所有后代文本（含 CDATA）
    public func elementPath(): String       // 形如 /svg[1]/g[2]/rect[1]
    public func toXmlElement(): XmlElement  // 与 f_xml 互操作
    public func toString(): String          // 紧凑序列化
}
```

`SvgAttribute`：

```cangjie
public struct SvgAttribute {
    public let name: QName                 // 复用 f_xml::QName（公开依赖）
    public let value: String
}
```

> 公开 API 中出现 `QName` 是可接受的：`f_xml` 是 `f_svg` 的显式依赖，  
> 且命名空间属性无法用裸字符串无歧义表达。

**属性顺序**：`attributes` 保持插入顺序；解析时按源文档顺序；  
类型化 setter 命中同名属性时**原位替换**，否则追加。序列化按该顺序输出。  
这样「解析 → 序列化」的属性顺序稳定，便于 diff 与快照测试。

**命名空间前缀**：`setAttr(namespace:local:value:)` 对同一 URI 复用已分配前缀，新 URI 依次分配
`ns1`、`ns2`…，并跳过已占用的前缀；`xlink` 与 `xml` 使用固定前缀。

**可变列表的边界**：`attributes`、`children`、`warnings` 为便于只读遍历直接暴露为可变列表。
调用方写入属性或子节点时应使用 `setAttr` / `removeAttr` / `appendChild`，否则会绕过
`attributesVersion` 缓存失效与 `parent` 维护；`warnings` 按契约只增，不应清空。

### 4.3 容器与根

```cangjie
public class SvgRoot <: SvgElement {
    public init(width!: ?SvgLength = None, height!: ?SvgLength = None)
    public prop x: ?SvgLength
    public prop y: ?SvgLength
    public prop width: ?SvgLength
    public prop height: ?SvgLength
    public prop viewBox: ?SvgViewBox
    public prop preserveAspectRatio: ?SvgPreserveAspectRatio
}

public enum SvgContainerKind {
    | Group | Defs | Symbol | Marker | Pattern | ClipPath | Mask | Switch | Anchor | ForeignObject
}

public class SvgContainer <: SvgElement {
    public let kind: SvgContainerKind
    public init(kind: SvgContainerKind)
}
```

- `g` / `defs` / `symbol` / `marker` / `pattern` / `clipPath` / `mask` / `switch` / `a`  
  统一用 `SvgContainer` 表达：它们的差异在**语义**（由消费者解释），不在数据结构。
- `foreignObject` 使用 `SvgContainer`，其子节点按原样保留（不解释 XHTML）。
- `SvgRoot` 是 `svg` 元素；`width/height` 缺省时按 `100%` 处理（渲染器语义，模型只保留 `None`）。

### 4.4 形状

```cangjie
public abstract class SvgShape <: SvgElement {
    // 公共绘制属性
    public prop fill: ?SvgPaint
    public prop fillOpacity: ?Float64
    public prop stroke: ?SvgPaint
    public prop strokeWidth: ?SvgLength
    public prop strokeOpacity: ?Float64
    public prop strokeLineCap: ?SvgLineCap
    public prop strokeLineJoin: ?SvgLineJoin
    public prop strokeMiterLimit: ?Float64
    public prop strokeDashArray: ?Array<SvgLength>
    public prop strokeDashOffset: ?SvgLength
    public prop opacity: ?Float64
    public prop color: ?SvgColor             // currentColor 的解析基准
    public prop fillRule: ?SvgFillRule
}

public class SvgRect <: SvgShape {
    public init(x!: ?SvgLength = None, y!: ?SvgLength = None,
        width!: ?SvgLength = None, height!: ?SvgLength = None,
        rx!: ?SvgLength = None, ry!: ?SvgLength = None)
    public prop x / y / width / height / rx / ry: ?SvgLength
}
public class SvgCircle <: SvgShape { public prop cx / cy / r: ?SvgLength }
public class SvgEllipse <: SvgShape { public prop cx / cy / rx / ry: ?SvgLength }
public class SvgLine <: SvgShape { public prop x1 / y1 / x2 / y2: ?SvgLength }
public class SvgPolyline <: SvgShape { public prop points: ?SvgPointList }
public class SvgPolygon <: SvgShape { public prop points: ?SvgPointList }
public class SvgPath <: SvgShape { public prop d: ?SvgPathData }
```

枚举：

```cangjie
public enum SvgLineCap { | Butt | Round | Square }
public enum SvgLineJoin { | Miter | Round | Bevel }
public enum SvgFillRule { | Nonzero | Evenodd }
```

- 几何属性允许缺省（`None`）：解析阶段不强制补齐，渲染器按 SVG 默认值处理；
- 类型化属性读取时若原始值非法：**严格模式抛错，宽松模式返回 `None` 并记 warning**；
- `strokeDashArray` 接受 `none`（返回 `None`）与逗号 / 空白分隔的长度列表。

### 4.5 文本

```cangjie
public open class SvgTextElement <: SvgElement {
    public prop x: ?Array<SvgLength>
    public prop y: ?Array<SvgLength>
    public prop dx: ?Array<SvgLength>
    public prop dy: ?Array<SvgLength>
    public prop rotate: ?Array<Float64>
    public prop textLength: ?SvgLength
    public prop lengthAdjust: ?SvgLengthAdjust
    public prop textAnchor: ?SvgTextAnchor
    public prop fontFamily: ?String
    public prop fontSize: ?SvgLength
    public prop fontWeight: ?String
    public prop fontStyle: ?String
    public prop letterSpacing: ?SvgLength
    public prop wordSpacing: ?SvgLength
}

public class SvgText <: SvgTextElement
public class SvgTspan <: SvgTextElement
public class SvgTextPath <: SvgTextElement {
    public prop href: ?String
    public prop startOffset: ?SvgLength
}

public enum SvgTextAnchor { | Start | Middle | End }
public enum SvgLengthAdjust { | Spacing | SpacingAndGlyphs }
```

- `x/y/dx/dy` 是**列表**（SVG 允许逐字定位）；单值也存成单元素数组；
- `text()` 返回拼接文本；不做空白折叠（`xml:space` 属 M2）；
- 不做字体度量与换行。

### 4.6 渐变、引用与图片

```cangjie
public abstract class SvgGradient <: SvgElement {
    public prop gradientUnits: ?SvgCoordinateUnits
    public prop gradientTransform: ?SvgTransform
    public prop spreadMethod: ?SvgSpreadMethod
    public prop href: ?String                 // 继承模板
}

public class SvgLinearGradient <: SvgGradient {
    public prop x1 / y1 / x2 / y2: ?SvgLength
}
public class SvgRadialGradient <: SvgGradient {
    public prop cx / cy / r / fx / fy: ?SvgLength
}

public class SvgStop <: SvgElement {
    public prop offset: ?Float64              // 0..1，百分比已归一
    public prop stopColor: ?SvgColor
    public prop stopOpacity: ?Float64
}

public enum SvgCoordinateUnits { | UserSpaceOnUse | ObjectBoundingBox }
public enum SvgSpreadMethod { | Pad | Reflect | Repeat }

public class SvgUse <: SvgElement {
    public prop href: ?String
    public prop x / y / width / height: ?SvgLength
}

public class SvgImage <: SvgElement {
    public prop href: ?String
    public prop x / y / width / height: ?SvgLength
    public prop preserveAspectRatio: ?SvgPreserveAspectRatio
}
```


- `href` 读取时同时接受 `href` 与 `xlink:href`，写入时按 `SvgWriteOptions.xlink` 决定；
  两种写法同时存在时只保留第一个，避免重复展开名；
- `offset` 支持 `0.5` / `50%`，统一归一为 `0..1`，越界钳制并记 warning；
- `SvgStop` 的 `stop-color` 可读 `currentColor` 之外的 `SvgColor`；`currentColor` 保留为 `None` + 原始字符串。

### 4.7 未知元素与无损保留

```cangjie
public class SvgUnknownElement <: SvgElement {
    public let rawName: QName
}
```

保留规则：

| 情况                                    | 处理                                       |
| ------------------------------------- | ---------------------------------------- |
| 非 SVG 命名空间的元素（如 `sodipodi:namedview`） | `SvgUnknownElement`，保留前缀 / URI / 属性 / 子树 |
| SVG 命名空间中的未知标签（如 M3 才支持的 `animate`）   | `SvgUnknownElement`（宽松）或抛错（严格）           |
| 未知属性（含 `data-*`、编辑器私有属性）              | 原样保留在 `attributes`                       |
| 注释 / PI / CDATA                       | 保留为对应 `SvgNode`                          |
| `<!DOCTYPE>`                          | 保留在 `SvgDocument.doctype`                |

**这是本模块的核心契约**：不认识 ≠ 丢弃。只有安全策略明确要移除的内容（脚本、事件属性、外部引用）才会被删除。

### 4.8 `SvgDocument`

```cangjie
public class SvgDocument <: ToString {
    public var root: SvgRoot
    public var declaration: ?XmlDeclaration
    public var doctype: ?DocTypeInfo
    public let prolog: ArrayList<SvgNode>
    public let epilog: ArrayList<SvgNode>
    public let warnings: ArrayList<String>

    public init(root: SvgRoot)
    public func elementById(id: String): ?SvgElement
    public func elementsByTag(tag: String): ArrayList<SvgElement>
    public func toXmlDocument(): XmlDocument
    public func toString(): String
}
```

- `declaration` / `doctype` 复用 `f_xml` 类型，保证 DOCTYPE 与 XML 声明可无损往返；
- `warnings` 记录宽松模式下的降级（非法属性值、被移除的不安全内容等）；
- `elementById` 深度优先，返回第一个匹配（不要求 id 唯一，但按规范应唯一）；
- `elementsByTag` 只返回后代元素，不含根元素自身。

---

## 5. 解析层

### 5.1 入口

```cangjie
public struct SvgParseOptions {
    public let strict: Bool                    // 默认 false
    public let security: SvgSecurityOptions
    public let xml: XmlParserOptions           // 透传给 f_xml
    public init(strict!: Bool = false,
        security!: SvgSecurityOptions = SvgSecurityOptions(),
        xml!: XmlParserOptions = XmlParserOptions())
}

public struct SvgSecurityOptions {
    public let unsafePolicy: SvgUnsafePolicy   // 默认 Remove
    public let allowScript: Bool               // 默认 false
    public let allowEventAttributes: Bool      // 默认 false
    public let allowExternalReferences: Bool   // 默认 false
    public let allowDataImages: Bool           // 默认 true
    public let maxElements: Int64              // 默认 1_000_000
    public let maxDepth: Int64                 // 默认 512
}

public enum SvgUnsafePolicy { | Reject | Remove | Keep }

public class SvgParser {
    public static func parse(input: InputStream, options!: SvgParseOptions = SvgParseOptions()): SvgDocument
    public static func parse(bytes: Array<Byte>, options!: SvgParseOptions = SvgParseOptions()): SvgDocument
    public static func parse(text: String, options!: SvgParseOptions = SvgParseOptions()): SvgDocument
    public static func parse(path: Path, options!: SvgParseOptions = SvgParseOptions()): SvgDocument
    public static func parse(document: XmlDocument, options!: SvgParseOptions = SvgParseOptions()): SvgDocument
}
```

- `parse(text)` 跳过字节嗅探（与 `f_xml` 对齐）；
- `parse(document)` 供调用方复用已解析的 XML；
- 所有重载最终走同一个 `SvgBuilder`。

### 5.2 标签映射

| SVG 标签                                                                                                  | 模型类型                                   |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `svg`                                                                                                   | `SvgRoot`                              |
| `g` / `defs` / `symbol` / `marker` / `pattern` / `clipPath` / `mask` / `switch` / `a` / `foreignObject` | `SvgContainer`                         |
| `rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path`                                | 对应形状类                                  |
| `text` / `tspan` / `textPath`                                                                           | `SvgText` / `SvgTspan` / `SvgTextPath` |
| `linearGradient` / `radialGradient` / `stop`                                                            | 对应渐变类 / `SvgStop`                      |
| `use` / `image`                                                                                         | `SvgUse` / `SvgImage`                  |
| `style` / `title` / `desc` / `metadata`                                                                 | 通用 `SvgElement`（保留内容，不解释、不告警）           |
| 其他                                                                                                      | `SvgUnknownElement`                    |

### 5.3 命名空间

- SVG 命名空间常量：`http://www.w3.org/2000/svg`；
- XLink 命名空间：`http://www.w3.org/1999/xlink`；
- 根元素必须在 SVG 命名空间**或**无命名空间（手写 SVG 常见）；
- 元素按 `QName.uri` 判定归属，**不靠前缀**（前缀任意）；
- 无命名空间的子元素继承 SVG 命名空间（宽容规则）；
- 属性命名空间：`xlink:href` 按 URI 识别；`xmlns` 声明由 `f_xml` 处理，不进模型属性表。

### 5.4 严格 / 宽松模式

| 场景                          | 严格模式             | 宽松模式（默认）                      |
| --------------------------- | ---------------- | ----------------------------- |
| SVG 命名空间未知标签                | 抛 `Unsupported`  | `SvgUnknownElement` + warning |
| 属性值非法（如颜色写错）                | 抛 `InvalidValue` | 保留原值，类型化读取返回 `None` + warning |
| 缺必需属性（如 `<rect>` 无 `width`） | 抛 `InvalidValue` | 允许，模型字段为 `None`               |
| `href` 指向外部                 | 抛 `Security`     | 按策略移除 / 保留 + warning          |
| 元素数 / 深度超限                  | 抛 `Limit`        | 同左（安全限制不降级）                   |

> 安全上限在两种模式下都**硬失败**；不存在「宽松就放行」的开关。

属性值与必需属性校验只作用于 **SVG 命名空间的已知元素**；外部命名空间的元素与属性原样保留，
不参与 SVG 语义校验（严格模式也不会因此报错）。

### 5.5 错误与定位

```cangjie
public enum SvgErrorKind {
    | Syntax | InvalidValue | Unsupported | Security | Limit
}

public class SvgException <: BaseException {
    public let kind: SvgErrorKind
    public let line: Int64
    public let column: Int64
    public let elementPath: ?String
    public init(message: String, kind!: SvgErrorKind = SvgErrorKind.InvalidValue)
    public init(message: String, line: Int64, column: Int64,
        kind!: SvgErrorKind = SvgErrorKind.InvalidValue,
        elementPath!: ?String = None)
}
```

- 行 / 列来自 `f_xml` 的 `XmlException`（1-based）；
- `f_xml` 抛出的 `XmlException` 在 `SvgParser` 边界统一包装为 `SvgException(kind: Syntax)`，  
  保留原始消息与位置；
- 构建期的语义 / 安全错误只保证 `elementPath`，`line` / `column` 为 `0`（位置未知）；
- `elementPath` 形如 `/svg[1]/g[2]/rect[1]`，由构建器维护，便于定位。

### 5.6 解析流程

```
1. f_xml 解析 → XmlDocument
2. 校验根元素（svg，且命名空间合法）→ 否则 Syntax
3. DFS 构建模型：
   a. 元素数 / 深度计数（超限 → Limit）
   b. 标签映射
   c. 属性分组：已知 → 类型化字段；未知 → attributes
   d. 安全过滤（脚本 / 事件属性 / 外部引用）
   e. 命名空间规范化
   f. 子节点递归
4. 收集 warnings
```

**构建时校验一次，类型化值惰性解析**：构建阶段对已知属性做一次合法性校验；类型化值不在此时
预置，而是在首次读取时解析并按 `attributesVersion` 缓存。未被访问的属性不付出类型化解析成本。

> 设计取舍：类型化字段与原始属性**同时存在**。`setAttr("x", "10")` 后  
> 类型化 `x` 字段需要同步更新——实现上用 setter 写原始属性，读取时按需解析并缓存，  
> 缓存随 `attributes` 的版本号失效。这是 §2.3 选 B 方案后必须显式处理的点。

---

## 6. 生成层

### 6.1 入口

```cangjie
public struct SvgWriteOptions {
    public let indent: ?String                 // None = 紧凑
    public let xmlDeclaration: Bool            // 默认 true
    public let charset: Charset                // 默认 UTF-8
    public let cdata: CdataMode                // 默认 Auto
    public let xlink: Bool                     // 默认 true：引用写 xlink:href
    public let trailingNewline: Bool           // 默认 false
}

public class SvgWriter {
    public init(output: OutputStream, options!: SvgWriteOptions = SvgWriteOptions())
    public func write(document: SvgDocument): Unit
    public func write(element: SvgElement): Unit
    public func flush(): Unit
    public func close(): Unit
}
```

便捷函数：

```cangjie
public func writeSvgString(document: SvgDocument, options!: SvgWriteOptions = SvgWriteOptions()): String
```

`writeSvgString` 只支持 UTF-8；非 UTF-8 `charset` 抛 `InvalidValue`，需要其他编码时直接用
`SvgWriter` 写 `OutputStream`。写出声明的 `encoding` 总是跟随 `SvgWriteOptions.charset`，
保留源声明的 `version` / `standalone`。

### 6.2 序列化流程

```
SvgDocument
  → 构造 XmlDocument：
      declaration（可选）
      doctype（可选）
      prolog（注释 / PI）
      root → XmlElement（递归：tag → QName(uri=SVG)，属性 → XmlAttribute，子节点 → XmlNode）
      epilog
  → f_xml::XmlWriter.write(doc)
```

- **命名空间**：根元素的 `QName.uri` 设为 SVG 命名空间，`f_xml::XmlWriter` 自动输出 `xmlns`；  
  `xlink:href` 的 `QName` 带 XLink URI，自动输出 `xmlns:xlink`；
- **转义**：完全交给 `f_xml::XmlWriter`（属性值、文本、CDATA 三套规则）；
- **缩进**：交给 `f_xml`；缩进会插入空白文本节点，往返后多出空白（README 已声明）；
- **编码**：`charset` 透传；非 UTF 编码的不可映射字符按 `f_xml` 的 `onInvalidChar` 策略处理。

### 6.3 往返一致性

**结构等价**定义：

- 标签名、命名空间 URI、属性名（展开名）与值、文本内容、子节点顺序一致；
- 属性顺序一致（模型保持插入顺序）；
- 注释 / PI / CDATA 保留；
- 不要求字节一致（空元素写法、引号、缩进、XML 声明可不同）。

**测试判据**：`parse(write(parse(x)))` 与 `parse(x)` 的模型快照相等。  
另设「紧凑模式字节稳定」用例：`write(parse(write(parse(x)))) == write(parse(x))`。

---

## 7. 安全边界

| 威胁                                             | 默认策略                              | 可配置                       |
| ---------------------------------------------- | --------------------------------- | ------------------------- |
| `script` 元素（按 local name，任意命名空间）              | `Remove`：移除并记 warning             | `Keep` / `Reject`         |
| `on*` 事件属性（`onload`、`onclick`…）                | `Remove`                          | `Keep` / `Reject`         |
| `javascript:` / `file:` 引用                     | 视为不安全引用，`Remove`                   | 仅 `unsafePolicy`           |
| 外部引用（`http:` / `https:` / 协议相对 `//`）           | `Remove`                          | `allowExternalReferences` |
| `<image href="data:...">`                      | 允许（不发起 I/O）                       | `allowDataImages`         |
| 外部 DTD / 外部实体                                  | `f_xml` 永不加载，引用即报错                | 不可放开                      |
| 实体膨胀                                           | `f_xml` 三层上限（64 KB / 8 MB / 2 GB） | 透传 `EntityLimits`         |
| 元素数 / 深度                                       | 1,000,000 / 512                   | `SvgSecurityOptions`      |
| 属性值长度                                          | 1 MiB（`f_xml`）                    | 透传                        |
| `<foreignObject>`                              | 原样保留，不解释                          | —                         |

**原则**：

1. 解析器**从不发起网络请求**、从不打开外部文件；
2. 默认对不可信输入做「移除 + 告警」，而不是「拒绝整个文档」——SVG 常用于展示用户上传内容，  
   因一个 `<script>` 就整份失败会让调用方被迫关闭安全过滤；
3. 需要严格拒绝时用 `unsafePolicy = Reject`；
4. 所有移除都写入 `SvgDocument.warnings`，调用方可审计。

---

## 8. 性能与内存

- 解析复用 `f_xml` 的零拷贝字符层与事件批处理；`f_svg` 只做一次 DFS 与属性解析；
- 类型化属性**惰性解析 + 版本缓存**：未访问的属性不解析；
- 序列化构造 `XmlDocument` 会短暂出现「模型 + XML 树」双份内存；  
  M1 接受该成本（SVG 文档通常 < 5 MB）；大文档流式输出列为 M2（需 `f_xml::XmlWriter` 增加  
  `comment` / `cdata` 增量方法，属于跨模块 API 变更，须单独评审）；
- 目标（合成 1 MB SVG，`-O2`）：
  - 解析 + 构建模型 ≤ 25 ms；
  - 模型 → 字符串 ≤ 20 ms；
  - 峰值内存 ≤ 8 × 输入大小。

> 性能目标只作回归参考，不作为 M1 验收硬门禁；硬门禁是正确性与往返一致性。

---

## 9. 测试策略

### 9.1 分层

| 层   | 内容                                                                                    | 形式        |
| --- | ------------------------------------------------------------------------------------- | --------- |
| 值类型 | `SvgLength` / `SvgColor` / `SvgPaint` / `SvgTransform` / `SvgPathData` / `SvgViewBox` | 表驱动单元测试   |
| 模型  | 构造、属性读写、父子关系、`elementPath`                                                            | 单元测试      |
| 解析  | 标签映射、命名空间、严格 / 宽松、错误定位                                                                | 单元测试 + 样本 |
| 生成  | 转义、命名空间、缩进、编码、往返                                                                      | 单元测试      |
| 安全  | 脚本 / 事件 / 外链 / 上限                                                                     | 单元测试      |
| 端到端 | 真实 SVG 文件往返                                                                           | 文件样本测试    |

### 9.2 值类型用例矩阵（必须覆盖）

**`SvgLength`**：整数 / 小数 / 负数 / 百分比 / 全部单位 / 大小写 / 空串 / 非法单位 /  
`NaN` / `Inf` / 前后空白 / 超长数字。

**`SvgColor`**：`#rgb` / `#rrggbb` / `#rrggbbaa` / 大小写 / 短横线命名色 /  
`rgb` 逗号与空格语法 / 百分比分量 / 越界钳制 / `rgba` alpha 百分比 /  
`hsl` 六个色相区 / `hsla` / `transparent` / `none` 失败 / 未知色名失败 / 空串失败。

**`SvgPaint`**：`none` / `currentColor` / 颜色 / `url(#id)` / 带 fallback / 外部 URL 拒绝 /  
引号形式 `url("#id")`。

**`SvgTransform`**：单变换 / 多变换顺序 / 缺省参数 / 角度负数 / `matrix` 六参数 /  
未知函数 / 空串 / 非法数字 / 组合后的点变换。

**`SvgPathData`**：十条命令的绝对与相对形式 / 隐式重复 / `M` 后隐式 `L` / 符号分隔 /  
小数连写 / 指数 / 弧标志连写 / 逗号错误 / `Z` 后数字错误 / 空路径 /  
`toAbsolute` 的当前点与子路径起点 / 序列化往返。

**`SvgViewBox` / `SvgPreserveAspectRatio`**：四参数 / 逗号与空格 / 负数宽高失败 /  
九种对齐 / `meet` 与 `slice` / 非等比视口 / 退化视口。

### 9.3 真实样本

- `f_svg/testdata/` 存放小型样本（每个 < 5 KB）：
  - `basic-shapes.svg`：七种形状 + 分组 + 变换；
  - `text.svg`：文本 / tspan / 多 x 列表；
  - `gradient.svg`：线性 / 径向 / 继承；
  - `namespaces.svg`：默认命名空间 + `xlink` + 编辑器私有命名空间；
  - `comments.svg`：注释 / PI / CDATA / DOCTYPE；
  - `unsafe.svg`：脚本 / 事件 / 外链（用于安全用例）。
- 仓库内 `.assets/README/module-dependencies.svg`（约 246 KB）作为**可选**大样本：  
  文件存在时跑往返与性能冒烟，不存在时跳过（但打印「已跳过」）。
- 不把大文件提交进 `f_svg/testdata/`，避免仓库膨胀。

### 9.4 安全用例

| 用例                                         | 默认结果                     |
| ------------------------------------------ | ------------------------ |
| `<script>alert(1)</script>`                | 元素被移除，warning 含 `script` |
| `<rect onload="x()">`                      | `onload` 被移除             |
| `<image href="https://x/y.png">`           | `href` 被移除               |
| `<use href="//evil/x.svg#a">`              | `href` 被移除               |
| `<use href="#ok">`                         | 保留                       |
| `<image href="data:image/png;base64,...">` | 保留                       |
| 100 万 + 1 个元素                              | 抛 `Limit`                |
| 深度 513                                     | 抛 `Limit`                |
| `unsafePolicy = Reject` + 脚本               | 抛 `Security`             |

### 9.5 验收判据（M1）

1. 所有值类型的用例矩阵通过；
2. 六个样本 `parse → write → parse` 结构等价；
3. 安全用例全部符合表格；
4. 大样本（存在时）往返成功且耗时在 §8 目标内；
5. `cjpm test` 全绿，`cjpm build` 无新增 warning；
6. README（中英）与本设计文档的公开 API 一致。


## 11. API 速览

```cangjie
import fountain::f_svg.*

// 解析
let doc = SvgParser.parse(File("logo.svg", OpenMode.Read))
let root = doc.root
let width = root.width?.toString() ?? "100%"

// 遍历
for (rect in doc.elementsByTag("rect")) {
    println("${rect.id ?? "-"}: ${rect.attr("x") ?? "0"}")
}

// 构造
let svg = SvgRoot(width: SvgLength(200.0, unit: SvgLengthUnit.Px),
                  height: SvgLength(100.0, unit: SvgLengthUnit.Px))
svg.viewBox = SvgViewBox(0.0, 0.0, 200.0, 100.0)
svg.appendElement(SvgRect(x: SvgLength(10.0), y: SvgLength(10.0),
    width: SvgLength(80.0), height: SvgLength(40.0)))
    .fill = SvgPaint.of(SvgColor.parse("#09f"))

// 生成
let text = writeSvgString(SvgDocument(svg), options: SvgWriteOptions(indent: Some("  ")))
```

---

## 12. 已定契约与遗留问题

### 12.1 已定（不再讨论）

1. **不渲染**：本模块只产出模型与 XML，不产出像素。
2. **不重复实现 XML**：解析 / 生成 / 命名空间 / 实体全部走 `f_xml`。
3. **未知内容保留**：不认识 ≠ 丢弃；安全策略明确要求移除的除外。
4. **属性顺序稳定**：解析保持源顺序，构造保持定义顺序，序列化按该顺序输出。
5. **默认宽松 + 安全移除**：非法值不炸整份文档，危险内容移除并告警。
6. **安全上限硬失败**：元素数 / 深度 / 实体上限不可通过宽松模式绕过。
7. **值类型往返自洽**：对规范形式可表示的值，`parse(toString(x)) == x`。
8. **变换合成顺序**：`A B C` = `A × B × C`，后写的先作用于坐标。
9. **不发布 `src/` shim**：新模块不进入已冻结的聚合根。
10. **模块版本跟随仓库**：当前 `1.3.17`，随统一发布流程升版。

### 12.2 仍需确认（M2 前）

| 问题               | 备选                                         | 建议                                      |
| ---------------- | ------------------------------------------ | --------------------------------------- |
| CSS 解析范围         | 完整 CSS3 vs 仅 SVG 呈现属性                      | 先做「`<style>` + `class` 选择器 + 呈现属性优先级」子集 |
| 路径包围盒            | 解析近似 vs 精确（含弧）                             | M2 做精确弧端点求解，提供 `tolerance`              |
| 流式输出             | 扩展 `f_xml::XmlWriter` vs `f_svg` 自建 writer | 优先扩展 `f_xml`（需评审公开 API）                 |
| `xml:space` 空白折叠 | M2 vs M3                                   | M2，与文本布局一起                              |
| SVGZ             | 依赖 gzip 实现 vs 不支持                          | 若仓库后续有 gzip 能力再接，M1 明确不支持               |

---

## 附录 A：与 `f_xml` 的 API 映射

| `f_svg` 概念                                                  | `f_xml` 对应                           |
| ----------------------------------------------------------- | ------------------------------------ |
| `SvgNode`                                                   | `XmlNode`                            |
| `SvgAttribute.name`                                         | `XmlAttribute.name`（`QName`）         |
| `SvgElement.tag` / `namespace`                              | `XmlElement.name.local` / `name.uri` |
| `SvgElement.attributes` / `children`                        | `XmlElement.attributes` / `children` |
| `SvgDocument.declaration` / `doctype` / `prolog` / `epilog` | 同名                                   |
| 解析                                                          | `XmlParser.parse(...)`               |
| 生成                                                          | `XmlWriter.write(XmlDocument)`       |
| 错误位置                                                        | `XmlException.line/column`           |

## 附录 B：SVG 命名空间常量

```cangjie
public class SvgNamespaces {
    public static let SVG: String = "http://www.w3.org/2000/svg"
    public static let XLINK: String = "http://www.w3.org/1999/xlink"
    public static let XML: String = "http://www.w3.org/XML/1998/namespace"
}
```
