# Spec Delta — f-excel-stream-write

## ADDED Requirements

### Requirement: 构造时一次给全 sheet 清单

```cangjie
public class ExcelWriter {
    public init(output: OutputStream,
                sheetNames: Array<String>,
                options!: ExcelWriteOptions = ExcelWriteOptions())
    public func writeSheet(name: String, rows: Iterator<RowData>,
                           options!: SheetWriteOptions = SheetWriteOptions()): Unit
    public func finish(): Unit
    public prop rowsWritten: Int64
}
```

`sheetNames` SHALL 在构造时固定：`[Content_Types].xml` 里每个 worksheet 的 `<Override>` 必须在
ZIP 第一条写出，而 ZIP 是顺序写、无法回填。构造 SHALL 校验：非空、无重名、每个名字符合
sheet 命名规则（≤31 字符、不含 `[]:*?/\`），违反抛 `ExcelException`。

构造 SHALL 立刻写出 `[Content_Types].xml`、`_rels/.rels`、`xl/workbook.xml`、
`xl/_rels/workbook.xml.rels` 四个小部件。

#### Scenario: 重名拒绝

- **WHEN** `ExcelWriter(out, ["a", "a"])`
- **THEN** 抛 `ExcelException`，消息含冲突的名字

#### Scenario: 空清单拒绝

- **WHEN** `ExcelWriter(out, [])`
- **THEN** 抛 `ExcelException`（xlsx 至少要一个 sheet）

#### Scenario: 元数据部件先落地

- **WHEN** 构造完成后立即用 `ZipReader` 读**已写出的字节**
- **THEN** 前四个条目就是 ContentTypes / .rels / workbook / workbook.rels

### Requirement: 写入顺序必须与构造一致

`writeSheet(name, rows)` SHALL 按 `sheetNames` 的顺序被调用：第 N 次调用 SHALL 写
`xl/worksheets/sheetN.xml`，且 `name` SHALL 等于 `sheetNames[N]`；不一致 SHALL 抛
`ExcelException`，消息给出期望的名字与实际的名字。

`writeSheet` SHALL 在返回前把 `rows` 消费完（`next()` 返回 `None` 即该 sheet 结束）——
`f_zip` 是拉模式，f_excel 不额外起线程。`rows` 迭代器自身抛出的异常 SHALL 原样上抛，
并让 writer 进入 `Failed` 状态。

#### Scenario: 名字不匹配

- **WHEN** `sheetNames = ["a", "b"]`，第一次调用 `writeSheet("b", …)`
- **THEN** 抛 `ExcelException`，消息含期望 `a` 与实际 `b`

#### Scenario: 一次消费完

- **WHEN** 传一个每次 `next()` 计数的迭代器，共 100 行
- **THEN** `writeSheet` 返回时计数为 101（100 次有值 + 1 次 `None`）

#### Scenario: 迭代器异常上抛

- **WHEN** 迭代器在第 50 行抛 `ExcelException("数据源断了")`
- **THEN** `writeSheet` 抛出同一个异常，且 writer 后续 `writeSheet`/`finish` 都抛

### Requirement: sheet 内容与最小列信息

每个 worksheet SHALL 为：

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="…/spreadsheetml/2006/main">
  [<dimension ref="…"/>]        <!-- 仅当 SheetWriteOptions.dimension 有值 -->
  <sheetData>
    <row r="1">…</row>
    …
  </sheetData>
  [<mergeCells>…</mergeCells>] <!-- 仅当有合并区域 -->
</worksheet>
```

`<dimension>` 默认 SHALL 省略（流式写时不可能预先知道范围；ECMA-376 里 `minOccurs=0`）。
`<sheetData/>` SHALL 始终写出（schema 里 `minOccurs=1`），即使没有任何行。

`SheetWriteOptions` 在 M1 SHALL 只有 `dimension: ?String`。

#### Scenario: 省略 dimension

- **WHEN** 不设 `dimension`
- **THEN** sheet XML 里没有 `<dimension>`

#### Scenario: 显式 dimension

- **WHEN** `dimension = "A1:C10"`
- **THEN** `<dimension ref="A1:C10"/>` 出现在 `<sheetData>` 之前

#### Scenario: 空 sheet

- **WHEN** 迭代器立刻返回 `None`
- **THEN** 写出 `<sheetData/>`（或 `<sheetData></sheetData>`），文件仍能打开

### Requirement: 行号必须严格递增

`<sheetData>` 内 `<row>` 的 `r` 必须升序。`writeSheet` SHALL 校验
`row.index` 严格大于上一行，否则抛 `ExcelException("行号必须严格递增：上一次 N，本次 M")`。
SHALL NOT 静默排序（静默排序要求整表缓存，正好废掉流式）。

`row.index < 1` 或 `> 1048576` SHALL 抛 `ExcelException`；
`cell.col < 1` 或 `> 16384` SHALL 抛；`cells` 的 `col` 非升序 SHALL 抛。

#### Scenario: 乱序拒绝

- **WHEN** 依次写 `index = 5` 与 `index = 3`
- **THEN** 第二行抛 `ExcelException`，消息含 5 与 3

#### Scenario: 重复行号拒绝

- **WHEN** 连续两行都是 `index = 5`
- **THEN** 抛 `ExcelException`（严格递增，不是非递减）

#### Scenario: 列号越界

- **WHEN** 某行含 `Cell(col: 16385, …)`
- **THEN** 抛 `ExcelException`，消息含 16385 与上限

### Requirement: 单元格内容与写侧上限

单元格 XML SHALL 与整文档模式（`f-excel-writer`）**逐字节一致**——两条通路共用同一个
`WorksheetXmlWriter`，不允许出现"流式写出来的和普通写出来的不一样"。

上限（超限抛 `ExcelException`，不截断）：文本 32767 字符、公式 8192 字符、
行 1048576、列 16384。日期 SHALL 绑定内置日期格式（同 `f-excel-writer` 的三档规则）。

#### Scenario: 与整文档一致

- **WHEN** 同一组 `RowData` 分别经 `ExcelWriter` 与 `ExcelDocument.write` 输出
- **THEN** 两个 `sheet1.xml` 的解压内容逐字节相同（`dimension` 都不设时）

#### Scenario: 超长文本

- **WHEN** 某格 32768 字符
- **THEN** 抛 `ExcelException`，消息含实际长度

### Requirement: 样式表在最后写

`xl/styles.xml` SHALL 在所有 sheet 之后写出（ZIP 条目顺序不要求与 OPC 逻辑一致）。
M1 的样式表是**固定最小表**（同 `f-excel-writer`），单元格的 `s` 索引是常量。

#### Scenario: styles 在 sheet 之后

- **WHEN** 检查生成包的条目顺序
- **THEN** `xl/styles.xml` 出现在最后一个 worksheet 之后

### Requirement: 完成与失败语义

```
Writing ──(任一异常)──▶ Failed ──(finish/writeSheet)──▶ 抛 ExcelException("流式写入已失败：<原因>")
Writing ──(finish 成功)──▶ Finished
```

- `finish()` SHALL 写出 `xl/styles.xml` 并 `close()` 底层 `ZipWriter`（写中央目录 + EOCD）；
- `finish()` 之前 output SHALL NOT 是有效 xlsx（缺中央目录）；
- `finish()` 之后任何 `writeSheet` / `finish` SHALL 抛 `ExcelException`；
- **失败即残缺**：中途异常后已写出的字节无法回滚，f_excel SHALL NOT 试图"跳过坏行继续写"；
- SHALL NOT 提供 `cancel()`：中途取消与失败同义。

`rowsWritten` SHALL 反映**当前 sheet** 已写行数（每次 `writeSheet` 归零）。

#### Scenario: finish 之前不是有效包

- **WHEN** `writeSheet` 完成后不调 `finish`，直接读已写出的字节
- **THEN** `ZipReader` 抛 `ZipException`（找不到 EOCD）

#### Scenario: 失败后一律抛

- **WHEN** 第 3 行行号乱序后，再调 `writeSheet` 或 `finish`
- **THEN** 都抛 `ExcelException`，消息含原始失败原因

#### Scenario: finish 之后不可再用

- **WHEN** `finish()` 成功后调 `writeSheet`
- **THEN** 抛 `ExcelException`，消息含「已完成」

### Requirement: flush 粒度

文本缓冲 SHALL 在「满 8 KB」或「一行结束」时冲刷到 `ZipWriter.addFileStream` 的流；
SHALL NOT 每行 `flush()` 底层 `OutputStream`（会把 deflate 打碎，反而更慢）。
底层 `OutputStream` 的 flush 只发生在 `finish()`。

#### Scenario: 底层写入次数远小于行数

- **WHEN** 写 1 万行、每行 1 个短文本，用一个计次的 `OutputStream`
- **THEN** 底层 `write` 调用次数是"压缩块"量级，显著少于 1 万

### Requirement: 与流式读直连

`RowReader` 实现 `Iterator<RowData>`，SHALL 可以不经过任何中间类型直接传给 `writeSheet`。
这条组合的最小闭环是"大表复制"：`src.rows(sheet)` → `writer.writeSheet(sheet, rows)`，
两端常量内存。

#### Scenario: 大表复制

- **WHEN** 用 `ExcelSheetStream` 读一张 10 万行表并直接喂给 `ExcelWriter`
- **THEN** 写出成功、行数与内容一致，且不把整表装进内存

#### Scenario: 中间 close 得到完整的前缀表

- **WHEN** `RowReader` 读了 100 行后 `close()`（`next()` 返回 `None`）
- **THEN** `writeSheet` 正常返回，写出的是 100 行的完整表（不是残缺包）
