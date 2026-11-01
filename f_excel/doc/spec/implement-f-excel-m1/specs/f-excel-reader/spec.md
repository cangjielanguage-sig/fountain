# Spec Delta — f-excel-reader

## ADDED Requirements

### Requirement: 三个构造入口

`ExcelDocument` SHALL 提供：

- `init()`：纯内存新建，不发任何 I/O；含 1 个名为 `Sheet1` 的 sheet、最小样式表、
  空字符串表。SHALL NOT 创建或打开任何 `File`。
- `init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())`
- `init(path: Path, options!: ExcelReadOptions = ExcelReadOptions())`

`init(path)` SHALL 走 `f_zip` 的路径模式（`File.seek` 窗口读，不把整包读进内存）；
`init(input)` SHALL 走 `f_zip` 的全量缓冲模式。

#### Scenario: 空文档不碰文件系统

- **WHEN** `ExcelDocument()`
- **THEN** 得到 1 个 sheet（名字 `Sheet1`）、`sheetCount() == 1`，且没有创建任何文件

#### Scenario: 空输入是失败路径

- **WHEN** 用零字节的 `InputStream` 构造
- **THEN** 抛 `ExcelException`，消息为「不是有效的 xlsx 文件」，`caused` 为 `ZipException`

### Requirement: 包结构与 sheet 清单

读取 SHALL 依次处理：`xl/workbook.xml`（DOM）取 `<sheets><sheet name r:id>` 与
`<workbookPr date1904>`；`xl/_rels/workbook.xml.rels`（DOM）把 `r:id` 映射为部件路径
（如 `worksheets/sheet1.xml`，相对 `xl/`）。匹配一律按 `QName.local`，
**不拼前缀**（`<x:sheet>` 与 `<sheet>` 等价）。

`workbook.xml` 缺失 SHALL 抛 `ExcelException("缺少 workbook.xml，可能不是 xlsx 文件")`。
rels 缺失或某 `r:id` 无对应项 SHALL **跳过该 sheet** 并记 `SheetSkipped`，
**不整体失败**。rels 指向的部件不存在 SHALL 记 `SheetEntryMissing` 并跳过。

#### Scenario: 前缀差异不影响解析

- **WHEN** `workbook.xml` 用 `<x:workbook xmlns:x="..."><x:sheets><x:sheet .../>`
- **THEN** sheet 清单与无前缀时完全一致

#### Scenario: 缺 rels 只丢 sheet

- **WHEN** `xl/_rels/workbook.xml.rels` 不存在，`workbook.xml` 声明了 2 个 sheet
- **THEN** 构造成功，`sheetCount() == 0`，`warnings()` 含 2 条 `SheetSkipped`

### Requirement: sheet 访问与管理

`ExcelDocument` SHALL 提供：

```cangjie
public func sheets(): ArrayList<Worksheet>
public func sheet(name: String): ?Worksheet          // 大小写敏感，找不到返回 None
public func sheetAt(index: Int64): ?Worksheet        // 0 起，越界返回 None
public func sheetCount(): Int64
public func addSheet(name: String): Worksheet        // 同名抛 ExcelException
public func removeSheet(name: String): Bool
public func renameSheet(oldName: String, newName: String): Bool
public prop date1904: Bool                           // 由 workbookPr 决定，可改
public func warnings(): ArrayList<ExcelWarning>
```

`addSheet` SHALL 拒绝空名、超过 31 字符、含 `[]:*?/\` 中任一字符、与已有 sheet 重名，
四种情况都抛 `ExcelException` 且消息指出是哪一条。

#### Scenario: sheetAt 从 0 起

- **WHEN** 文档有 2 个 sheet
- **THEN** `sheetAt(0)` 与 `sheetAt(1)` 均有值，`sheetAt(2)` 为 `None`

#### Scenario: 非法 sheet 名

- **WHEN** `addSheet("a/b")`
- **THEN** 抛 `ExcelException`，消息含 `a/b` 与非法字符原因

### Requirement: `Worksheet` 的双套单元格 API

```cangjie
public func cell(row: Int64, col: Int64): ?CellValue
public func cell(ref: String): ?CellValue            // 非法 ref 返回 None
public func cell(ref: CellRef): ?CellValue
public func setCell(row: Int64, col: Int64, value: CellValue): Unit
public func setCell(ref: String, value: CellValue): Unit
public func setCell(ref: CellRef, value: CellValue): Unit
public func clearCell(row: Int64, col: Int64): Unit
public func clearCell(ref: String): Unit
```

三组重载 SHALL 语义一致（同一坐标返回同一值）。越界坐标的 `setCell` SHALL 抛
`ExcelException`；越界的 `cell` SHALL 返回 `None`。

#### Scenario: 两套 API 结果一致

- **WHEN** `setCell("B3", Text("x"))` 后分别用 `cell(3, 2)`、`cell("B3")`、
  `cell(CellRef.parse("B3")!)` 取
- **THEN** 三次都返回 `Some(Text("x"))`

#### Scenario: 写越界拒绝

- **WHEN** `setCell(1048577, 1, Text("x"))`
- **THEN** 抛 `ExcelException`，消息含行上限

### Requirement: 范围统计

`rowCount()` / `colCount()` SHALL 返回**已用范围**的最大行号 / 列号（0 表示空）；
`dimension(): ?String` SHALL 优先采用文件里的 `<dimension ref="A1:C100">`，
缺失时按实际已用范围拼 `A1:C100`，完全没有数据时返回 `None`。

`rowValues(row: Int64): Array<(Int64, CellValue)>` SHALL 返回该行的稀疏 `(col, value)` 列表，
按 `col` 升序，不含空单元格。`range(from: String, to: String): Array<Array<CellValue>>` SHALL
按 `to` 的列数对齐，空位填 `CellValue.Empty`；`from`/`to` 非法 SHALL 抛 `ExcelException`。

#### Scenario: 空 sheet

- **WHEN** sheet 只有 `<sheetData/>`
- **THEN** `rowCount() == 0`、`colCount() == 0`、`dimension()` 为 `None`

#### Scenario: 稀疏行的 rowValues

- **WHEN** 第 2 行只有 C 列有值 `3`
- **THEN** `rowValues(2)` 返回 `[(3, Number(3.0))]`，长度 1

### Requirement: 单元格类型映射

`<c t="…">` SHALL 按下表转换，未知 `t` SHALL 记 `UnknownCellType` 并按 `Text` 保留原文：

| `t` | `<v>` / 内容 | 结果 |
|---|---|---|
| 缺省 / `n` | 十进制字符串 | `Number(Float64.parse)`；解析失败 → `Text` 原文 + `NumberParseFailed` |
| `s` | 索引 | 查 sharedStrings；越界 → `Empty` + `SharedStringIndexOutOfRange` |
| `inlineStr` | `<is><t>`（或 `<is><r><t>`） | `Text`（多段拼接，忽略字体） |
| `str` | 文本 | `Text` |
| `b` | `0` / `1`（也接受 `true`/`false`） | `Boolean` |
| `e` | 错误码 | `Error("#DIV/0!")` |
| `d` | ISO 8601 | `DateTime.parse`；失败 → `Text` 原文 + `NumberParseFailed` |

`t="s"` 且 `loadSharedStrings = false` SHALL 得到 `Empty`（不查表、不报错）。

#### Scenario: 布尔

- **WHEN** `<c r="A1" t="b"><v>1</v></c>`
- **THEN** 值为 `Boolean(true)`

#### Scenario: 数字解析失败保留原文

- **WHEN** `<c r="A1"><v>1,5</v></c>`
- **THEN** 值为 `Text("1,5")`，并有一条 `NumberParseFailed`

#### Scenario: 未知类型降级

- **WHEN** `<c r="A1" t="zzz"><v>abc</v></c>`
- **THEN** 值为 `Text("abc")`，并有一条 `UnknownCellType`

### Requirement: 稀疏性与 `r` 缺失的推断

解析 SHALL 用 `<c>` 的 `r` 属性定位行列，**SHALL NOT** 按出现顺序推断。
`r` 缺失时 SHALL 按「同一行内前一个单元格的列 + 1」推断（行首缺省为 1）并记
`MissingCellRef`；`r` 存在但非法 SHALL 按同一规则推断并记 `InvalidCellRef`。
`<row>` 的 `r` 缺失时 SHALL 按「上一行的行号 + 1」推断（首行为 1）并记 `MissingRowIndex`。

#### Scenario: 稀疏行的正确坐标

- **WHEN** `<row r="100"><c r="Z100"><v>7</v></c></row>`
- **THEN** `cell(100, 26)` 为 `Number(7.0)`，其余列全部 `None`

#### Scenario: 列号推断

- **WHEN** `<row r="4"><c r="B4"><v>1</v></c><c><v>2</v></c></row>`
- **THEN** 第二个单元格落在 `(4, 3)`，并有一条 `MissingCellRef`

#### Scenario: 行号推断

- **WHEN** 连续两个 `<row>` 都没有 `r`，前面最后一行的 `r` 是 7
- **THEN** 两行分别是 8 与 9，各有一条 `MissingRowIndex`

### Requirement: sharedStrings 解析

`xl/sharedStrings.xml` SHALL 用事件流解析，按 `<si>` 出现顺序建表：

- `<si><t>…</t></si>` SHALL 取该文本；
- `<si>` 内多个 `<r><t>…</t></r>` SHALL **全部按顺序拼接**；
- `<rPh>`（注音）及其内部 `<t>` SHALL **跳过**，不计入文本；
- `<t xml:space="preserve">` SHALL 保留首尾空白；无该属性时 SHALL 保留原文（**不 trim**——
  删空白会让 `" "` 变成空串，与 Excel 显示不符）；
- `count` / `uniqueCount` SHALL NOT 参与校验（真实文件里常常不准）。

`sharedStrings.xml` 不存在但文件里有 `t="s"` 的单元格 SHALL 按"表为空、索引越界"处理：
该格 `Empty` + `SharedStringIndexOutOfRange`，**不抛异常**。

#### Scenario: 富文本拼接

- **WHEN** `<si><r><t>Rich</t></r><r><t xml:space="preserve"> text</t></r></si>`
- **THEN** 表项是 `"Rich text"`（中间空格保留）

#### Scenario: 注音被跳过

- **WHEN** `<si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></si>`
- **THEN** 表项是 `"東京"`，不含 `トウキョウ`

### Requirement: 日期识别默认开启

`ExcelReadOptions.autoDetectDate` 默认 `true`。开启时，`t` 缺省的数值单元格 SHALL 在
「该单元格的 `s` 索引指向的 `numFmtId` 是日期/时间格式」时返回 `Date`：

- 内置 `numFmtId ∈ {14,15,16,17,18,19,20,21,22,45,46,47}`；
- 自定义 `formatCode` 先净化再判定：去掉 `[...]`、`"..."`、`\x`、`_x`、`*x`，转小写；
  净化后含 `{y,m,d,h,s}` 至少一个，**且** 含 `-`/`/`/`:` 之一或只由这些字符与分隔符组成；
- `m` 是月还是分钟：同段连续格式字符内紧邻 `h` 或 `s` 时为分钟，否则为月。

serial → `DateTime` SHALL 按基准处理：

| 基准 | 规则 |
|---|---|
| 1900（默认） | `serial 1..59` → 1899-12-31 + serial 天；`serial == 60` → `Number(60)` + `DateSerial60`；`serial >= 61` → 1899-12-30 + serial 天 |
| 1904 | `serial 0` = 1904-01-01，`1899 → 1904` 无闰年 bug |

小数部分 SHALL 作为当天时间（按 `86400` 秒/天换算，四舍五入到秒）。

`autoDetectDate = false` SHALL 一律返回 `Number`（原始序列号）；
`loadStyles = false` 且 `autoDetectDate = true` SHALL **自动降级为 `false`** 并记
`AutoDetectDateDisabled`（不抛异常，宽容优于打断）。
选项 `date1904 = Some(x)` 与 `workbookPr` 相反时 SHALL 以选项为准并记 `DateBaseMismatch`。

#### Scenario: 内置格式识别

- **WHEN** `<c r="B2" s="3"><v>45231</v></c>` 且 `cellXfs[3].numFmtId = 14`
- **THEN** 值为 `Date`，其日期为 `2023-11-01`

#### Scenario: 关闭识别后是原始数字

- **WHEN** 同样的单元格，`autoDetectDate = false`
- **THEN** 值为 `Number(45231.0)`

#### Scenario: 1900 闰年假日期

- **WHEN** 日期格式的单元格 `<v>60</v>`
- **THEN** 值为 `Number(60.0)`，并有一条 `DateSerial60`

#### Scenario: 自定义格式的 m 歧义

- **WHEN** `formatCode = "yyyy-mm-dd"` 与 `"h:mm"` 各一格
- **THEN** 两格都是 `Date`（前者 `m` 是月，后者 `m` 是分钟，两者都判为日期/时间）

#### Scenario: 非日期格式不被误判

- **WHEN** `formatCode` 依次为 `0.00` / `#,##0` / `0.00%` / `"日期："0.00` / `[Red]0.00`
- **THEN** 全部返回 `Number`（不是 `Date`）

#### Scenario: `[h]` 在 M1 按日期处理

- **WHEN** `numFmtId = 46`（`[h]:mm:ss`）的单元格
- **THEN** 值为 `Date`，并有一条 `UnsupportedTimeFormat`

### Requirement: 合并单元格

`<mergeCells><mergeCell ref="A2:B2"/>` SHALL 记录到 `Worksheet`：

```cangjie
public func mergedRanges(): ArrayList<String>       // 原样保留文件里的顺序
public func mergedRangeAt(row: Int64, col: Int64): ?String
public func mergedValue(row: Int64, col: Int64): ?CellValue   // 所属区域左上角的值
public func merge(range: String): Unit
public func merge(from: String, to: String): Unit             // 等价于 merge("$from:$to")
public func unmerge(range: String): Bool
```

`mergedRangeAt` SHALL 支持跨行列的多格区域（`A1:C3`）；`mergedValue` 对非合并格 SHALL
返回该格自身的值。`merge` 与已有区域重叠 SHALL 抛 `ExcelException`；
`unmerge` 找不到区域 SHALL 返回 `false`（不抛）。

#### Scenario: 跨列表头

- **WHEN** 只有 `A1` 有值 `"合计"`，且存在 `A1:C1`
- **THEN** `mergedValue(1, 2)` 与 `mergedValue(1, 3)` 都是 `Some(Text("合计"))`

#### Scenario: 非合并区域

- **WHEN** 区域是 `A1:C1` 时查 `mergedRangeAt(1, 4)`
- **THEN** 返回 `None`

### Requirement: 读取选项与截断

```cangjie
public class ExcelReadOptions {
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0          // 0 = 不限
    public var maxCols: Int64 = 0
    public var skipSheets: Array<String> = []
}
```

M1 SHALL NOT 提供 `eager` 与 `loadTheme`（前者 M3，后者依赖 M2 的 theme 解析）。

`maxRows` / `maxCols` 超限 SHALL **截断并记 warning**（`MaxRowsTruncated` / `MaxColsTruncated`），
不抛异常。`skipSheets` SHALL 按名精确匹配跳过该 sheet 的解析并记 `SheetSkipped`。

#### Scenario: 行数截断

- **WHEN** 表有 100 行，`maxRows = 10`
- **THEN** `rowCount() == 10`，有一条 `MaxRowsTruncated`

#### Scenario: 跳过指定 sheet

- **WHEN** `skipSheets = ["Sheet2"]`
- **THEN** `sheet("Sheet2")` 为 `None`（不解析），`Sheet1` 正常

### Requirement: 读取宽容

单个坏单元格 SHALL NOT 让整个文件失败：`t="s"` 越界、数字解析失败、`r` 非法、
未知 `t` 四种情况都按上面各条的降级路径处理并记 warning。
只有「不是有效 ZIP」「缺 `workbook.xml`」「workbook.xml 本身解析失败」三种情况 SHALL 抛
`ExcelException`。

#### Scenario: 三种致命情况

- **WHEN** 依次给零字节输入、没有 `xl/workbook.xml` 的包、XML 语法错误的 `workbook.xml`
- **THEN** 三次都抛 `ExcelException`，消息分别含「不是有效的 xlsx 文件」/「缺少 workbook.xml」/
  「workbook.xml」
