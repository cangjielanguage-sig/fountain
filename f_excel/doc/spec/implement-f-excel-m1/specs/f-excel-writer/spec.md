# Spec Delta — f-excel-writer

## ADDED Requirements

### Requirement: 必需部件与内容类型

`write()` SHALL 产出以下部件，且 `[Content_Types].xml` SHALL 是 ZIP 的**第一个条目**：

```
1. [Content_Types].xml
2. _rels/.rels
3. xl/workbook.xml
4. xl/_rels/workbook.xml.rels
5. xl/worksheets/sheet1.xml … sheetN.xml
6. xl/styles.xml
```

`[Content_Types].xml` SHALL 为每个 worksheet 写一条
`<Override PartName="/xl/worksheets/sheetN.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`，
并为 `workbook.xml` 与 `styles.xml` 各写一条 Override，为 `rels` 写
`Default Extension="rels"` 与 `Default Extension="xml"`。

`_rels/.rels` SHALL 只有一条指向 `/xl/workbook.xml` 的
`Type="…/officeDocument"` 关系。`xl/_rels/workbook.xml.rels` SHALL 为每个 sheet 写一条
`Type="…/worksheet"` 关系，并为 `styles.xml` 写一条 `Type="…/styles"` 关系。
`r:id` 与部件路径的对应 SHALL 与 `workbook.xml` 的 `<sheet r:id>` 一致。

#### Scenario: 条目顺序

- **WHEN** 生成一个含 2 个 sheet 的文档
- **THEN** `[Content_Types].xml` 是第一个条目，且两个 worksheet 的 Override 都存在

#### Scenario: r:id 闭合

- **WHEN** 解析自己生成的包
- **THEN** 每个 `<sheet r:id>` 都能在 rels 里找到对应部件，无悬空引用

### Requirement: workbook.xml 的命名空间与前缀属性

`workbook.xml` 的根 SHALL 为
`<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`，
`<sheet>` 的 `r:id` SHALL 写成带前缀的属性（`prefix = "r"`、`uri` 为 r 命名空间），
SHALL NOT 写成字面名 `r:id` 的无前缀属性（`XmlElement.setAttr` 会犯这个错）。

`workbookPr` SHALL 在 `date1904 == true` 时写 `date1904="1"`，否则省略。
`<sheets>` 里的 `<sheet sheetId="i" name="…" r:id="rIdN"/>` SHALL 按 `ExcelDocument` 的 sheet 顺序输出。

#### Scenario: date1904 只在为真时写

- **WHEN** 默认（1900 基准）生成文档
- **THEN** `workbook.xml` 里没有 `date1904` 属性；解析回来 `date1904 == false`

#### Scenario: r:id 带前缀

- **WHEN** 检查生成的 `workbook.xml` 文本
- **THEN** 含 `r:id="rId1"` 且根元素声明了 `xmlns:r`

### Requirement: 文本写成 `inlineStr`

M1 的 `ExcelWriteOptions.stringMode` SHALL 只有 `InlineStr`（默认并唯一实现），
文本单元格 SHALL 写成 `<c r="A1" t="inlineStr"><is><t>…</t></is></c>`。
SHALL NOT 生成 `xl/sharedStrings.xml`。

`<t>` SHALL 在文本首尾有空白时带 `xml:space="preserve"`（否则 Excel 会吃掉空白）。

#### Scenario: 无共享字符串部件

- **WHEN** 生成任何 M1 文档
- **THEN** 包内没有 `xl/sharedStrings.xml`

#### Scenario: 首尾空白保留

- **WHEN** 单元格文本为 `"  a  "`
- **THEN** `<t xml:space="preserve">  a  </t>`，且解析回来仍是 `"  a  "`

### Requirement: 数字写成最短往返十进制

数值单元格 SHALL 写成「能唯一还原该 `Float64` 的最短十进制串」：

- 整数值 SHALL 写成不带小数点的形式（`1.0` → `"1"`，不是 `"1.0"`）；
- 非整数 SHALL 用最短往返表示（`0.1` → `"0.1"`，不是 `"0.10000000000000001"`）；
- `NaN` / `±Infinity` SHALL 抛 `ExcelException`（xlsx 无法表达，写进去 Excel 会报错）。

#### Scenario: 整数不带小数点

- **WHEN** 写入 `Number(1.0)`
- **THEN** 单元格 XML 为 `<v>1</v>`

#### Scenario: 小数往返

- **WHEN** 写入 `Number(0.1)`
- **THEN** `<v>0.1</v>`，解析回来与 `0.1` 逐位相等

#### Scenario: 非有限值拒绝

- **WHEN** 写入 `Number(Float64.NaN)`
- **THEN** 抛 `ExcelException`，消息含 `NaN`

### Requirement: 其余值类型

| 值 | 单元格 XML |
|---|---|
| `Empty`（显式设置） | `<c r="A1"/>` |
| `Boolean(true)` | `<c r="A1" t="b"><v>1</v></c>` |
| `Error("#DIV/0!")` | `<c r="A1" t="e"><v>#DIV/0!</v></c>` |
| `Text(s)` | `<c r="A1" t="inlineStr"><is><t>s</t></is></c>` |
| `Formula(src, cached)` | `<c r="A1"><f>src</f><v>cached</v></c>`；`cached = None` 时省略 `<v>` |
| `Date(dt)` | 数字（序列号）+ 日期样式，见下条 |

`Error` 的值 SHALL 限定在 `#NULL!` / `#DIV/0!` / `#VALUE!` / `#REF!` / `#NAME?` / `#NUM!` /
`#N/A` 之内；其它字符串 SHALL 抛 `ExcelException`。

#### Scenario: 公式原文不带等号

- **WHEN** 写入 `Formula("SUM(A1:A10)", Some(Number(55.0)))`
- **THEN** XML 为 `<f>SUM(A1:A10)</f><v>55</v>`，重新解析后原文仍为 `SUM(A1:A10)`

#### Scenario: 非法错误码

- **WHEN** 写入 `Error("#FOO!")`
- **THEN** 抛 `ExcelException`，消息含 `#FOO!`

### Requirement: 日期必须绑样式

写入 `Date(dt)` SHALL 把 `dt` 转成序列号（按 `date1904` 的两种基准），并自动绑定内置日期格式。
基准的取值：`ExcelWriteOptions.date1904 = Some(x)` 以其为准；`None` 时 `ExcelDocument.write`
跟随 `ExcelDocument.date1904`，`ExcelWriter` 取 `false`（1900 基准）。

| 情形 | `numFmtId` |
|---|---|
| 时间部分为 0（当天 00:00:00） | `14`（`mm-dd-yy`） |
| 有日期也有时间 | `22`（`m/d/yy h:mm`） |
| 只有时间（日期部分为基准日） | `20`（`h:mm`） |

`Cell.numberFormat` 为 `Some(Builtin(id))` 且 `id` 属于日期子集时 SHALL 以调用方为准；
若调用方给了**非日期**格式（如 `General`），SHALL 仍按日期换算序列号但记
`NumberFormatNotSupportedInM1`，且**不覆盖**调用方的选择。

#### Scenario: 日期不显示成 5 位数字

- **WHEN** 写入 `Date(2023-11-01 00:00:00)`
- **THEN** 单元格 `s` 指向 `numFmtId = 14`，`<v>` 为 `45231`

#### Scenario: 带时间的日期

- **WHEN** 写入 `Date(2023-11-01 12:00:00)`
- **THEN** `s` 指向 `numFmtId = 22`，`<v>` 为 `45231.5`

### Requirement: 最小 `styles.xml`

`styles.xml` SHALL 至少包含：

```xml
<styleSheet xmlns="…/spreadsheetml/2006/main">
  <fonts count="1"><font><sz val="11"/></font></fonts>
  <fills count="2">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="N">…</cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
```

- `fonts` SHALL 至少 1 条，最少写 `<sz val="11"/>`，SHALL NOT 写 `<name>`（用 Excel 自己的默认）；
- `fills[0]` SHALL 是 `none`、`fills[1]` SHALL 是 `gray125`（顺序反了 Excel 报"需要修复"）；
- `cellXfs[0]` SHALL 是 General（`numFmtId="0"`），日期格式依次追加，`cellXfs` 的索引即单元格的 `s`；
- `cellStyles` SHALL 至少一条 `builtinId="0"` 的 `Normal`。

#### Scenario: fills 前两项固定

- **WHEN** 解析自己生成的 `styles.xml`
- **THEN** `fills[0].patternType == none`、`fills[1].patternType == gray125`

#### Scenario: 空文档也写全

- **WHEN** 生成一个没有任何单元格的文档
- **THEN** `styles.xml` 仍包含 `fonts` / `fills` / `borders` / `cellStyleXfs` / `cellXfs` / `cellStyles`

### Requirement: 合并单元格写入

`Worksheet.merge("A1:C1")` 后生成的文件 SHALL 在 worksheet 里写

```xml
<mergeCells count="1"><mergeCell ref="A1:C1"/></mergeCells>
```

且位于 `<sheetData>` **之后**（schema 顺序）。合并区域内只有左上角有值，
其余格 SHALL NOT 重复写值。

#### Scenario: 顺序正确

- **WHEN** 生成含合并区域的 sheet XML
- **THEN** `<mergeCells>` 出现在 `</sheetData>` 之后

#### Scenario: 只写左上角

- **WHEN** `merge("A1:C1")` 且 `A1` 有值
- **THEN** `B1` / `C1` 不出现在 XML 里

### Requirement: XML 转义与非法字符

`WorksheetXmlWriter` SHALL 与 `f_xml.Escaper` 用**同一张表**（`Escaper.cj:27-62`），
否则两套实现会漂移：

| 字符 | 文本 | 属性 |
|---|---|---|
| `&` | `&amp;` | `&amp;` |
| `<` | `&lt;` | `&lt;` |
| `>` | `&gt;` | `&gt;` |
| `"` | 不转 | `&quot;` |
| `'` | 不转 | 不转 |
| `\r` | `&#13;` | `&#13;` |
| `\n` / `\t` | 原样 | 原样 |

`\r` 必须转义：否则写出再读回会被行尾归一成 `\n`，往返不一致。

XML 1.0 非法控制字符（`0x00`–`0x08`、`0x0B`、`0x0C`、`0x0E`–`0x1F`）与 `0x7F`、`U+FFFE`、
`U+FFFF` SHALL **剔除**并记 `ControlCharStripped`（**不抛异常**，与设计 §10「写入文本含控制字符
→ 剔除并记 warning」一致）。剔除后其余内容 SHALL 逐字节保留。

对**合法字符**，输出 SHALL 与 `f_xml.XmlWriter` 对同一文本的转义逐字节一致
（两套实现不得漂移）。

#### Scenario: 中文与 emoji 原样

- **WHEN** 写入 `Text("中文😀")`
- **THEN** XML 里是原样的 UTF-8 字节，解析回来内容一致

#### Scenario: 控制字符被剔除

- **WHEN** 写入 `Text("a\u{0001}b")`
- **THEN** 得到 `"ab"`，且有一条 `ControlCharStripped`

#### Scenario: 与 f_xml 转义一致

- **WHEN** 同一段含 `& < > " '` 的文本分别经 `WorksheetXmlWriter` 与 `f_xml.XmlWriter` 输出
- **THEN** 文本节点部分的字节完全一致

### Requirement: 写入上限校验

写入 SHALL 在越界时抛 `ExcelException`（**不静默截断**）：

| 项 | 上限 |
|---|---|
| 单元格文本 | 32767 字符 |
| 公式长度 | 8192 字符 |
| 行号 | 1048576 |
| 列号 | 16384 |
| sheet 名 | 31 字符，且不含 `[]:*?/\` |

#### Scenario: 超长文本

- **WHEN** 写入 32768 个字符的文本
- **THEN** 抛 `ExcelException`，消息含实际长度与上限

### Requirement: 输出目标

`write(output: OutputStream)` SHALL 只写 `output`，SHALL NOT 关闭它；
`write(path: Path)` SHALL 创建/截断该文件、写完关闭，**失败时**留下的是残缺文件
（ZIP 顺序写无法回滚），由调用方决定是否删除。

#### Scenario: 不关调用方的流

- **WHEN** 传入一个内存 `OutputStream` 后调用 `write`
- **THEN** 返回后该流仍可继续写

#### Scenario: 写文件

- **WHEN** `write(Path("/tmp/a.xlsx"))` 后重新 `ExcelDocument(Path("/tmp/a.xlsx"))`
- **THEN** sheet 名与单元格值一致

### Requirement: 生成物能被 Excel 打开

M1 的出口 SHALL 包含一组**人工验收**（自动化只能覆盖结构）：用真实 Excel / WPS / LibreOffice
打开生成物，不得出现"需要修复"提示；要求中英文、数字精度、日期显示、合并单元格四项正确。
自动化侧用 openpyxl 回读做结构比对。

#### Scenario: 无修复提示

- **WHEN** 用 Excel 打开 `write()` 生成的文件
- **THEN** 不弹"发现不可读取的内容/需要修复"

#### Scenario: 日期显示为日期

- **WHEN** 用 Excel 打开含 `Date` 单元格的文件
- **THEN** 显示为日期而不是 5 位整数
