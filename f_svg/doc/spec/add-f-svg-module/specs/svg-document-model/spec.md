# svg-document-model

## ADDED Requirements

### Requirement: 结构元素到模型的映射

系统 SHALL 把 SVG 命名空间中的结构元素按固定表映射为具体模型类型：`svg` → `SvgRoot`；`g` / `defs` / `symbol` / `marker` / `pattern` / `clipPath` / `mask` / `switch` / `a` / `foreignObject` → `SvgContainer`。

`SvgContainer` SHALL 通过 `SvgContainerKind` 区分语义种类，不在数据结构上分裂。

#### Scenario: 容器共用类型

- **WHEN** 解析 `<defs>` 与 `<clipPath>`
- **THEN** 两者均为 `SvgContainer`，`kind` 分别为 `Defs` 与 `ClipPath`

### Requirement: 图形、文本与引用元素到模型的映射

系统 SHALL 按固定表映射图形、文本与引用元素：`rect` / `circle` / `ellipse` / `line` / `polyline` / `polygon` / `path` → 各自形状类；`text` / `tspan` / `textPath` → `SvgText` / `SvgTspan` / `SvgTextPath`；`linearGradient` / `radialGradient` / `stop` → `SvgLinearGradient` / `SvgRadialGradient` / `SvgStop`；`use` / `image` → `SvgUse` / `SvgImage`。

表中未列出的标签 SHALL 映射为 `SvgUnknownElement`。

#### Scenario: 表格全覆盖

- **WHEN** 解析包含上述全部标签的文档
- **THEN** 每个元素都得到对应类型而非 `SvgUnknownElement`

### Requirement: 元素基类的结构与属性顺序

`SvgElement` SHALL 暴露 `tag`、`namespace`、`attributes`、`children`、`parent`，并支持 `attr` / `setAttr` / `removeAttr`、`appendChild` / `appendElement` / `appendText`、`child` / `childrenOf`、`text()`、`elementPath()`、`toXmlElement()`、`toString()`。

属性 SHALL 保持插入顺序：解析时沿用源文档顺序，类型化 setter 命中同名属性时原位替换、未命中时追加，序列化按该顺序输出。

`elementPath()` SHALL 输出形如 `/svg[1]/g[2]/rect[1]` 的路径，序号为该标签在父节点同名子元素中的 1-based 位置。

`text()` SHALL 拼接所有后代文本与 CDATA，不含注释与 PI；解析阶段 SHALL 不做空白折叠。

#### Scenario: 属性原位替换

- **WHEN** 元素已有 `x="1" y="2"`，调用 `setAttr("x", "10")`
- **THEN** 属性顺序仍为 `x, y`，`x` 的值为 `10`

#### Scenario: 元素路径

- **WHEN** 对 `/svg/g[2]/rect`（第二个 `g` 下的第一个 `rect`）调用 `elementPath()`
- **THEN** 返回 `/svg[1]/g[2]/rect[1]`

### Requirement: 图形与绘制属性

七种形状 SHALL 继承 `SvgShape` 并提供几何属性的类型化读写：`SvgRect`（`x/y/width/height/rx/ry`）、`SvgCircle`（`cx/cy/r`）、`SvgEllipse`（`cx/cy/rx/ry`）、`SvgLine`（`x1/y1/x2/y2`）、`SvgPolyline`/`SvgPolygon`（`points`）、`SvgPath`（`d`）。

`SvgShape` SHALL 提供公共绘制属性：`fill`、`fillOpacity`、`stroke`、`strokeWidth`、`strokeOpacity`、`strokeLineCap`、`strokeLineJoin`、`strokeMiterLimit`、`strokeDashArray`、`strokeDashOffset`、`opacity`、`color`、`fillRule`。

几何属性 SHALL 允许缺省（`None`），解析阶段不补齐默认值。`strokeDashArray` SHALL 接受 `none`（得到 `None`）与长度列表。

#### Scenario: 几何属性读写

- **WHEN** 构造 `SvgRect` 并设置 `x = SvgLength(10)`、`width = SvgLength(80, unit: Px)`
- **THEN** 序列化结果包含 `x="10"` 与 `width="80px"`

#### Scenario: 缺省几何属性

- **WHEN** 解析 `<rect width="10" height="10"/>`（无 `x`/`y`）
- **THEN** `x` 与 `y` 为 `None`，不报错

#### Scenario: 虚线数组为 none

- **WHEN** 解析 `stroke-dasharray="none"`
- **THEN** `strokeDashArray` 为 `None`

### Requirement: 文本元素

系统 SHALL 提供 `SvgTextElement` 基类与 `SvgText`、`SvgTspan`、`SvgTextPath` 三个子类。

文本元素 SHALL 支持 `x/y/dx/dy`（长度列表）、`rotate`（数字列表）、`textLength`、`lengthAdjust`、`textAnchor`、`fontFamily`、`fontSize`、`fontWeight`、`fontStyle`、`letterSpacing`、`wordSpacing`；单值输入 SHALL 存为单元素列表。

`SvgTextPath` SHALL 额外支持 `href` 与 `startOffset`。

#### Scenario: 多值定位

- **WHEN** 解析 `<text x="10 20 30">abc</text>`
- **THEN** `x` 为三个长度的数组，`text()` 返回 `abc`

#### Scenario: 单值仍为列表

- **WHEN** 解析 `<text x="10">a</text>`
- **THEN** `x` 长度为 1

### Requirement: 渐变、引用与图片

系统 SHALL 提供 `SvgGradient`、`SvgLinearGradient`、`SvgRadialGradient`、`SvgStop`、`SvgUse`、`SvgImage`。

渐变 SHALL 支持 `gradientUnits`、`gradientTransform`、`spreadMethod`、`href`；线性渐变支持 `x1/y1/x2/y2`，径向渐变支持 `cx/cy/r/fx/fy`。

`SvgStop` SHALL 把 `offset` 归一为 `0..1`（支持小数与百分比），越界 SHALL 钳制并记 warning；`stop-color` 可解析为 `SvgColor`，`currentColor` SHALL 保留原始字符串并使类型化字段为 `None`。

`href` 读取 SHALL 同时接受 `href` 与 `xlink:href`；写入形式 SHALL 由 `SvgWriteOptions.xlink` 决定（默认 `true` 写 `xlink:href`）。

#### Scenario: offset 归一化

- **WHEN** 解析 `offset="50%"`、`offset="1.5"`、`offset="-0.2"`
- **THEN** 依次得到 `0.5`、`1.0`（并记 warning）、`0.0`（并记 warning）

#### Scenario: href 双写法读取

- **WHEN** 分别解析 `href="#a"` 与 `xlink:href="#a"`
- **THEN** `href` 均为 `#a`

### Requirement: 未知内容无损保留

系统 SHALL 不丢弃任何无法识别的内容：

- 非 SVG 命名空间的元素 → `SvgUnknownElement`，保留 `QName`（前缀/URI）、属性与子树；
- SVG 命名空间中的未知标签 → 宽松模式 `SvgUnknownElement` + warning，严格模式抛 `Unsupported`；
- `style` / `title` / `desc` / `metadata` → 已知但无语义的标签，映射为通用 `SvgElement`，保留内容且不告警；
- 未知属性（含 `data-*` 与编辑器私有属性）→ 原样保留在 `attributes`；
- 注释、PI、CDATA → 保留为对应 `SvgNode`；
- `<!DOCTYPE>` → 保留在 `SvgDocument.doctype`。

#### Scenario: 私有命名空间

- **WHEN** 解析含 `sodipodi:namedview` 的文档
- **THEN** 该元素为 `SvgUnknownElement`，前缀、URI、属性与子节点完整保留

#### Scenario: 未知属性

- **WHEN** 解析 `<rect data-x="1" inkscape:label="a"/>`
- **THEN** 两个属性都出现在 `attributes` 中且值不变

#### Scenario: 无语义已知标签

- **WHEN** 严格模式解析含 `<style>`、`<title>`、`<desc>`、`<metadata>` 的文档
- **THEN** 均成功构建为通用 `SvgElement`，不抛 `Unsupported`，也不产生未知标签 warning

### Requirement: 文档对象

系统 SHALL 提供 `SvgDocument`，包含 `root`（`SvgRoot`）、`declaration`、`doctype`、`prolog`、`epilog`、`warnings`，并提供 `elementById`、`elementsByTag`、`toXmlDocument()`、`toString()`。

`declaration` 与 `doctype` SHALL 复用 `f_xml::XmlDeclaration` 与 `f_xml::DocTypeInfo`，保证可无损往返。

`elementById` SHALL 深度优先返回第一个匹配元素；`elementsByTag` SHALL 返回全部后代中 local name 匹配的元素（不区分命名空间）。

#### Scenario: 按 id 查找

- **WHEN** 文档中有两个同 id 元素
- **THEN** `elementById` 返回文档序中第一个

#### Scenario: 按标签查找

- **WHEN** 文档中 `use` 与 `x:use` 各一个
- **THEN** `elementsByTag("use")` 返回两个

### Requirement: 解析入口与选项

系统 SHALL 提供 `SvgParser.parse` 的五个重载：`InputStream`、`Array<Byte>`、`String`、`Path`、`XmlDocument`，全部走同一构建器。

`SvgParseOptions` SHALL 包含 `strict`（默认 `false`）、`security`（`SvgSecurityOptions`）与 `xml`（`XmlParserOptions`，原样透传）。

`parse(text)` SHALL 跳过字节嗅探，直接交给 `f_xml` 的文本入口。

#### Scenario: 五种入口等价

- **WHEN** 同一份 SVG 分别通过文本、字节、流、文件路径与预解析 `XmlDocument` 进入
- **THEN** 五个 `SvgDocument` 的结构快照相等

#### Scenario: XML 选项透传

- **WHEN** `SvgParseOptions(xml: XmlParserOptions(trimWhitespaceOnly: true))`
- **THEN** `f_xml` 按该选项丢弃纯空白文本节点

### Requirement: 严格与宽松模式

系统 SHALL 按模式区分处理：SVG 命名空间未知标签、非法属性值、缺失必需属性在严格模式抛错、宽松模式降级并记 warning；外部引用在严格模式抛 `Security`，宽松模式按策略移除或保留。

元素数与深度上限 SHALL 在两种模式下都硬失败。

#### Scenario: 非法颜色值

- **WHEN** 解析 `fill="notacolor"`，宽松模式
- **THEN** 文档构建成功，`fill` 类型化读取为 `None`，`warnings` 含该属性

#### Scenario: 严格模式同输入

- **WHEN** 同一输入使用 `strict: true`
- **THEN** 抛 `SvgException(kind: InvalidValue)`

### Requirement: 命名空间处理

系统 SHALL 按命名空间 URI 判定元素归属，不依赖前缀。

无命名空间的子元素 SHALL 继承父元素的 SVG 命名空间；根元素 SHALL 位于 SVG 命名空间或无命名空间，否则抛 `Syntax`。

`xlink:href` SHALL 按 XLink URI 识别；`xmlns` 声明 SHALL 由 `f_xml` 处理，不进入模型属性表。

#### Scenario: 任意前缀

- **WHEN** 文档以 `xmlns:s="http://www.w3.org/2000/svg"` 并写 `<s:rect/>`
- **THEN** 仍映射为 `SvgRect`

#### Scenario: 根命名空间非法

- **WHEN** 根元素位于 `http://example.com/ns`
- **THEN** 抛 `SvgException(kind: Syntax)`

### Requirement: 生成与选项

系统 SHALL 提供 `SvgWriter(output, options)` 与 `writeSvgString(document, options)`。

`SvgWriteOptions` SHALL 包含 `indent`（`None` 为紧凑）、`xmlDeclaration`（默认 `true`）、`charset`（默认 UTF-8）、`cdata`（默认 `Auto`）、`xlink`（默认 `true`）、`trailingNewline`（默认 `false`）。

序列化 SHALL 由 `SvgWriter` 构造 `XmlDocument` 后交给 `f_xml::XmlWriter`，转义、命名空间声明、缩进与编码全部由 `f_xml` 负责。

#### Scenario: 自动命名空间声明

- **WHEN** 写入含 SVG 与 `xlink:href` 的文档
- **THEN** 输出根元素带 `xmlns="http://www.w3.org/2000/svg"` 且带 `xmlns:xlink` 声明

#### Scenario: 紧凑模式

- **WHEN** `indent: None`
- **THEN** 输出不含缩进产生的空白文本节点

### Requirement: 往返一致性

系统 SHALL 保证结构等价往返：`parse(write(parse(x)))` 与 `parse(x)` 的模型快照相等。

结构等价 SHALL 定义为：标签名、命名空间 URI、属性展开名与值、文本内容、子节点顺序、注释/PI/CDATA、属性顺序一致；不要求空元素写法、引号、缩进与 XML 声明字节一致。

系统 SHALL 同时满足「紧凑模式字节稳定」：`write(parse(write(parse(x)))) == write(parse(x))`。

#### Scenario: 样本往返

- **WHEN** 对六个 `testdata` 样本执行 `parse → write → parse`
- **THEN** 前后模型结构等价

#### Scenario: 二次写入稳定

- **WHEN** 对样本连续执行两次紧凑写入
- **THEN** 两次输出字节相同
