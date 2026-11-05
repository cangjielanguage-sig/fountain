# f_svg

**SVG 1.1 静态文档**模块：值类型 + 类型化 DOM + 解析 + 生成 + 安全过滤。

只负责「把 SVG 文档讲清楚、改对、写回去」，**不渲染、不做 CSS 级联、不做动画**。
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

## 能力（M1）

| 能力 | 入口 |
|---|---|
| 解析 | `SvgParser.parse` 的文本 / 字节 / 流 / 路径 / `XmlDocument` 五个重载 |
| 模型 | `SvgDocument` / `SvgRoot` / `SvgElement` 及形状、文本、渐变、`use`、`image` 子类 |
| 类型化属性 | `SvgLength` / `SvgColor` / `SvgPaint` / `SvgTransform` / `SvgPathData` / `SvgViewBox` |
| 生成 | `SvgWriter` / `writeSvgString`，内部经 `XmlDocument` 交给 `f_xml::XmlWriter` |
| 安全 | 默认移除脚本、事件属性、外部引用；元素数与深度硬上限 |
| 无损保留 | 未知元素、未知属性、注释 / PI / CDATA、DOCTYPE |

## 快速开始

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
| `data:` 图片 | 保留 | `allowDataImages`（置 `false` 时移除） |
| `#id` 片段引用 | 保留 | 不可关闭 |
| 外部 DTD / 外部实体 | 永不加载 | 不可放开 |

规模上限（元素数 / 深度 / 实体）在严格与宽松模式下都**硬失败**，抛
`SvgException(kind: SvgErrorKind.Limit)`。

## 值类型

所有值类型对**规范形式可表示**的值满足 `parse(toString(x)) == x`；`parse` 失败抛 `SvgException`，
`SvgLength` / `SvgColor` / `SvgPathData` 另提供 `tryParse`（返回 `None`）。

已知不保真边界：绝对值 `< 1e-6` 的非零值归零、超过 6 位小数的值被舍入。
`SvgColor` 的 alpha 可由 `0..255` 字节精确表示时输出 `#rrggbbaa`（如 `#ff000080`），否则输出 `rgba()`。

```cangjie
SvgLength.parse("1.5em")          // value = 1.5, unit = Em
SvgColor.parse("hsl(120,100%,50%)") // #00ff00
SvgPaint.parse("url(#grad1) none")  // Reference(#grad1, fallback = None)
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

## 样本与测试

`testdata/` 提供六个小型样本：`basic-shapes.svg`、`text.svg`、`gradient.svg`、
`namespaces.svg`、`comments.svg`、`unsafe.svg`。

```bash
cd f_svg
cjpm test
```

大样本冒烟使用仓库内 `.assets/README/module-dependencies.svg`（存在时执行，不存在时跳过）。
性能参考值见 [`doc/perf-baseline.md`](doc/perf-baseline.md)。

## M1 不做什么

- 渲染 / 光栅化、路径包围盒、填充规则求值；
- CSS 解析与级联（`<style>` 与 `style=""` 原样保留）；
- SMIL 动画、滤镜、SVGZ、`foreignObject` 内部 XHTML 语义；
- 字体度量与文本换行。

## 已知 API 约定

- `SvgPaint` 的引用工厂方法名为 `referencing(id, fallback:)`（与字段 `reference` 区分）；
  `id` 可带或不带 `#`，统一存为 `#id`，空 id 抛 `InvalidValue`。
- `SvgAspectAlign` 的无对齐取值名为 `NoAlign`（序列化为 `none`）。
