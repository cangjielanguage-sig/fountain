# Spec Delta — f-excel-stream-read

## ADDED Requirements

### Requirement: 两种打开入口与输入处置

```cangjie
public class ExcelSheetStream {
    public static func open(path: Path,
                            options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public static func open(input: InputStream,
                            options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public func sheetNames(): Array<String>
    public func rows(sheet: String): ?RowReader
    public func rowsAt(index: Int64): ?RowReader
    public func warnings(): ArrayList<ExcelWarning>
    public func close(): Unit
}
```

`open(path)` SHALL 走 `ZipReader(path)`，条目按需解压——**真流式**。
`open(input)` SHALL 在 `spool = true`（默认）时先把输入按固定 64 KB 缓冲拷进临时文件，
再用路径通道打开；`spool = false` SHALL 走 `ZipReader(input)` 全量缓冲，并记
`SpoolDisabled`（"已退化为全量缓冲"）。

`spool` 目录解析顺序 SHALL 为：`options.spoolDir` → `TMPDIR` →
`env.getTempDirectory()` → `env.getWorkingDirectory().join(".fountain_tmp")`（自动创建）。
四级全失败 SHALL 抛 `ExcelException`，消息提示改用 `spoolDir` 或 `spool = false`。

#### Scenario: 流输入默认落临时文件

- **WHEN** `open(input)` 传一个 20 MB 的 `ByteArrayStream`
- **THEN** 构造后进程里没有 20 MB 的包缓冲（`spool = true`），且 `sheetNames()` 正确

#### Scenario: spool 关闭时退化并告警

- **WHEN** `open(input, ExcelStreamReadOptions(spool: false))`
- **THEN** 功能正常，`warnings()` 有一条 `SpoolDisabled`

#### Scenario: spool 目录不可写

- **WHEN** `spoolDir` 指向一个只读目录
- **THEN** `open` 抛 `ExcelException`，消息含 `spoolDir` 与 `spool = false` 两个出路

### Requirement: 开流前的一次性装载

`open` SHALL 在返回前完成三件事（KB~MB 级，一次性）：

1. `xl/workbook.xml` + `xl/_rels/workbook.xml.rels`（DOM）→ sheet 名与部件路径；
2. `xl/styles.xml`（DOM）→ `cellXfs` 索引 → 是否日期（`loadStyles = false` 时跳过）；
3. `xl/sharedStrings.xml`（事件流）→ 字符串表（`loadSharedStrings = false` 时跳过）。

`sheetNames()` SHALL 按 workbook 里的顺序返回**可读取**的 sheet 名
（rels 缺失或无对应部件的 sheet 不出现，且各记一条 `SheetSkipped` / `SheetEntryMissing`）。

#### Scenario: 缺 workbook.xml

- **WHEN** 包里没有 `xl/workbook.xml`
- **THEN** `open` 抛 `ExcelException`，消息含 `缺少 workbook.xml`

#### Scenario: 不是 ZIP

- **WHEN** 输入是纯文本
- **THEN** `open` 抛 `ExcelException("不是有效的 xlsx 文件")`，`caused` 是 `ZipException`

### Requirement: `RowReader` 是拉模式迭代器

```cangjie
public class RowReader <: Iterator<RowData> {
    public func next(): Option<RowData>
    public func close(): Unit
    public func mergedRanges(): ArrayList<String>   // 流结束后才有值，见下条
}
```

`next()` SHALL 只在被调用时才推进 XML 解析；返回 `None` 表示该 sheet 结束。
`next()` SHALL 幂等：返回 `None` 之后继续调用仍返回 `None`（**不抛**）。
`close()` SHALL 提前结束本 sheet（释放条目游标），但 SHALL NOT 关闭 `ExcelSheetStream`；
`close()` 之后 `next()` SHALL 抛 `ExcelException("流已关闭")`。

`rows(sheet)` 对不存在的名字 SHALL 返回 `None`；`rowsAt(index)` 越界 SHALL 返回 `None`。
同一 `ExcelSheetStream` 上 SHALL 可以多次 `rows(同 sheet)` 得到**新的独立游标**
（ZIP 条目可重复解压）。

#### Scenario: 提前 close 后可重读

- **WHEN** 读 10 行后 `reader.close()`，再 `rows(sheet)` 取新 reader
- **THEN** 新 reader 从第 1 行开始

#### Scenario: None 之后仍 None

- **WHEN** 连续调用 `next()` 三次，第二次起返回 `None`
- **THEN** 第三次仍返回 `None`，不抛异常

#### Scenario: close 之后抛错

- **WHEN** `reader.close()` 后再 `next()`
- **THEN** 抛 `ExcelException`，消息含「流已关闭」

### Requirement: 行产出语义

| 情况 | 行为 |
|---|---|
| `<row r="5">` | `RowData.index = 5`，`cells` 按 `col` 升序 |
| `<row>` 无 `r` | 按「上一行 + 1」推断（首行为 1）+ `MissingRowIndex` |
| `<row r="5"/>` | 产出 `cells` 为空的行；有 `ht` 则带上 `height` |
| 中间缺行（3 之后直接 7） | **不补空行**，调用方按 `index` 自行对齐 |
| `<c>` 无 `r` | 按「同行前一列 + 1」推断 + `MissingCellRef` |
| 行号乱序（9 之后 3） | **照原样产出** + `RowOrderViolation`，不重排、不抛 |
| 单元格值 | 与整文档通道完全相同的 `t` 类型表、日期识别、`sharedStrings` 查表 |
| 公式 | 只给原文 + 缓存值，不求值 |
| 超出 `maxRows` / `maxCols` | 截断 + `MaxRowsTruncated` / `MaxColsTruncated`，流正常结束 |

`cells` SHALL 只含实际出现的单元格（稀疏行不补 A/B 这类空位）。

#### Scenario: 稀疏行

- **WHEN** `<row r="5"><c r="C5"><v>1</v></c></row>`
- **THEN** `RowData(index: 5, cells: [Cell(col: 3, value: Number(1.0))])`

#### Scenario: 乱序不抛

- **WHEN** 依次出现 `<row r="9">`、`<row r="3">`
- **THEN** 依次产出 index 9 与 3，并有一条 `RowOrderViolation`

#### Scenario: 空行照产出

- **WHEN** `<row r="5" ht="30"/>`
- **THEN** 产出 `cells` 为空、`height == Some(30.0)` 的行

#### Scenario: 行号截断

- **WHEN** `maxRows = 10` 但表有 100 行
- **THEN** 产出 10 行后返回 `None`，并有一条 `MaxRowsTruncated`

### Requirement: 合并区域在流结束后才可用

`<mergeCells>` 在 worksheet schema 里位于 `<sheetData>` **之后**，逐行拉取时读不到。
因此 `RowReader.mergedRanges()` SHALL 在 `next()` 首次返回 `None` **之后**才有值；
在读过程中调用 SHALL 返回空数组并记 `MergedRangesUnavailable`（返回空数组而不是 `None`，
避免调用方误以为"没有合并区域"）。

`ExcelSheetStream.lastMergedRanges(sheet: String): ArrayList<String>` SHALL 返回**最近一次读完**
该 sheet 时收集到的合并区域；未读完时返回空数组。

这条缺口 SHALL 写进类注释与 README：它是"边读边解析"的固有代价，不是实现偷懒；
需要 `mergedValue()` 的场景应改用 `ExcelDocument`。

#### Scenario: 流中为空、流后有值

- **WHEN** 表里有 `A1:C1` 合并，先读 3 行时调 `mergedRanges()`，读到 `None` 后再调
- **THEN** 第一次是空数组且有一条 `MergedRangesUnavailable`；第二次是 `["A1:C1"]`

#### Scenario: 提前 close 不产出合并区域

- **WHEN** 只读 2 行就 `close()`，然后调 `mergedRanges()`
- **THEN** 仍是空数组（没有读完 sheetData，拿不到 `<mergeCells>`）

### Requirement: 流式读取选项

```cangjie
public class ExcelStreamReadOptions {
    public var spool: Bool = true
    public var spoolDir: ?Path = None
    public var loadRowHeight: Bool = true
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0
}
```

`loadRowHeight = false` SHALL 让所有 `RowData.height` 为 `None`（省一次属性解析）。
`loadSharedStrings = false` SHALL 让 `t="s"` 的单元格变 `Empty`（不查表、不报错）。
`loadStyles = false` 且 `autoDetectDate = true` SHALL 自动降级并记 `AutoDetectDateDisabled`。

#### Scenario: 关共享字符串

- **WHEN** `loadSharedStrings = false`，表里都是 `t="s"`
- **THEN** 所有文本格是 `Empty`，且没有 `SharedStringIndexOutOfRange`

#### Scenario: 关行高

- **WHEN** `loadRowHeight = false`，但 XML 里有 `ht="30"`
- **THEN** `RowData.height` 为 `None`

### Requirement: 生命周期、异常与清理

下列约定 SHALL 成立：

| 事项 | 约定 |
|---|---|
| `close()` | 幂等；关闭所有 `RowReader`、删除 spool 临时文件、关闭 `ZipReader` |
| 再 `next()` | `close()` 之后抛 `ExcelException("流已关闭")` |
| 解析中途出错 | 关闭当前条目流并记 warning，`next()` 抛 `ExcelException`（消息带 sheet 名与行号）；`ExcelSheetStream` 本身**可继续读下一个 sheet** |
| 临时文件 | `close()` 删除；异常路径由 `try-finally` 清理 |
| 并发 | 同一 `ExcelSheetStream` 上 SHALL NOT 多线程同时 `next()`（文档写明；`sharedStrings` 只读共享安全，条目游标各自独立） |

#### Scenario: 坏 sheet 不影响下一个

- **WHEN** sheet1 的 XML 在中间截断，由 try 捕获异常后再 `rows("sheet2")`
- **THEN** 仍能正常逐行读取 sheet2

#### Scenario: close 删除临时文件

- **WHEN** `open(input)`（spool）后 `close()`
- **THEN** 临时文件不存在

#### Scenario: close 幂等

- **WHEN** 连续调用 `close()` 两次
- **THEN** 两次都不抛异常

### Requirement: 内存与行数无关

除 `sharedStrings` 表外，流式读的常驻内存 SHALL 与行数无关：当前行 `RowData` 用完即丢，
`styles`/`workbook`/`rels` 只装一次，解压与 XML 事件缓冲固定。
`loadSharedStrings = false` SHALL 把 `sharedStrings` 这一项也降为 0。

#### Scenario: 百万行逐行读

- **WHEN** 逐行读完一份 100 万行的 sheet（`loadSharedStrings = false`）
- **THEN** 进程内存峰值不随行数增长（人工记录，不作门禁）
