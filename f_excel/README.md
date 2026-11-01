# f_excel

Excel（xlsx / OOXML）读写模块：**流式解析、流式生成**、日期识别、合并单元格。

- 包名：`fountain::f_excel`
- 依赖：`f_base`、`f_log`、`f_util`、`f_xml`（XML 解析 / 增量生成）、`f_zip`（OOXML 容器）
- 设计文档：[`doc/f_excel模块设计.md`](doc/f_excel模块设计.md)
- 规格与任务：[`doc/spec/implement-f-excel-m1/`](doc/spec/implement-f-excel-m1/)

## 能力（M1）

| 能力 | 说明 |
|---|---|
| 整文档读 | `ExcelDocument(input)` / `ExcelDocument(path)`：sheet 清单、值类型、sharedStrings、合并区域、日期识别 |
| 整文档写 | `ExcelDocument.write(output)` / `write(path)`：`inlineStr`、多 sheet、合并、日期/时长绑样式、图片、完整样式 |
| **流式读** | `ExcelSheetStream.open(path/input)` → `RowReader`：逐行拉取，**内存与行数无关** |
| **流式写** | `ExcelWriter`：行迭代器 → `f_xml.XmlWriter` 增量事件 → `f_zip.openEntry` 推模式压缩 |
| 值类型 | `Empty` / `Number` / `Text` / `Boolean` / `Error` / `Date` / `Formula`（只保留原文 + 缓存，不求值） |
| 日期 | 内置 14–22 / 45–47 与自定义格式启发式；1900 / 1904 两种基准；serial 60 保留为数字并告警 |
| 图片（写） | `Worksheet.addImage(path/bytes, from, to)`：png / jpeg，锚定到单元格区域；读侧暂不导入图片 |
| 样式 | `CellStyle` / `Font` / `Fill` / `Border` / `Alignment` / `Protection` / `Color` 全量读写；`styles.xml` 的 numFmts/fonts/fills/borders/cellXfs/cellStyles；样式池按值去重 |
| 公式 | 解析 + 求值 + 依赖图：`CalcEngine.evaluate` / `recalculate`；350 个函数；共享公式平移；循环引用 `#CIRC!` |
| 时长 / 富文本 | `[h]:mm:ss` 读取为 `CellValue.TimeSpan`；`Worksheet.richText` 暴露 sharedStrings 的分段字体 |
| 条件格式 | `<conditionalFormatting>` / 13 种 `CfRuleType` / `dxfs` 解析与写回；`matchedRules` 求值（cellIs/expression/文本/colorScale/dataBar/iconSet） |

全量 `cjpm test`：**183 通过 / 0 失败**。

## 用法

### 读整份文档

```cangjie
import fountain::f_excel.*
import std.fs.Path

let doc = ExcelDocument(Path("/data/a.xlsx"))
let sheet = doc.sheet("Sheet1").getOrThrow()
let value = sheet.cell("A1")                       // ?CellValue
println(sheet.mergedValue(2, 1))                   // 合并区域左上角的值
```

### 写整份文档

```cangjie
let doc = ExcelDocument()
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.setCell("A1", CellValue.Text("名称"))
sheet.setCell("B1", CellValue.Number(0.1))
sheet.merge("A1:B1")
doc.write(Path("/data/out.xlsx"))
```

### 按需解析 / 字符串索引

```cangjie
let options = ExcelReadOptions()
options.eager = false                  // 首次访问 sheet 才解析
let doc = ExcelDocument(Path("big.xlsx"), options: options)

let streamOptions = ExcelStreamReadOptions()
streamOptions.sharedStringsIndex = true // 字符串表落临时文件，按需读取
let stream = ExcelSheetStream.open(Path("big.xlsx"), options: streamOptions)
```

### 公式求值

```cangjie
let engine = CalcEngine(doc)
let value = engine.evaluate("Sheet1", "B2")     // 单格，带依赖递归
engine.recalculate(writeBack: true)              // 全表重算并写回缓存值
```

### 样式

```cangjie
sheet.setCell("A1", CellValue.Number(1234.5))
sheet.setStyle(1, 1, CellStyle(
    numberFormat: NumberFormat.Builtin(4),
    font: Font(bold: true, color: Color.Rgb("FFFF0000")),
    fill: Fill.solid(Color.Rgb("FFFFFF00")),
    alignment: Alignment(horizontal: Horizontal.Center, wrapText: true)
))
```

### 插入图片

```cangjie
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.addImage(Path("/data/logo.png"), "A4", "E12")   // 锚定 A4:E12
```

### 流式写（大表，内存恒定）

```cangjie
let writer = ExcelWriter(out, ["明细"])
writer.writeSheet("明细", rows.iterator())         // rows: Iterator<RowData>
writer.finish()                                    // 写中央目录 + EOCD，之后才能读
```

### 流式读（边读边解析）

```cangjie
let stream = ExcelSheetStream.open(Path("/data/big.xlsx"))
try {
    let reader = stream.rows("明细").getOrThrow()
    while (let Some(row) <- reader.next()) {
        for (cell in row.cells) {
            // cell.col / cell.value
        }
    }
    println(reader.mergedRanges())                 // 流结束后才有值
} finally {
    stream.close()
}
```

### 大表复制（两端常量内存）

```cangjie
let src = ExcelSheetStream.open(Path("/data/big.xlsx"))
let out = File("/data/copy.xlsx", OpenMode.Write)
let writer = ExcelWriter(out, ["明细"])
writer.writeSheet("明细", src.rows("明细").getOrThrow())
writer.finish()
src.close()
out.close()
```

## API 参考

### 常量与坐标

```cangjie
public let EXCEL_MAX_ROW: Int64 = 1_048_576
public let EXCEL_MAX_COL: Int64 = 16_384
public let F_EXCEL_VERSION: String

public func columnIndex(letters: String): ?Int64
public func columnLetters(col: Int64): String

public struct CellRef <: Comparable<CellRef> & Equatable<CellRef> & ToString {
    public let row: Int64
    public let col: Int64
    public let rowAbs: Bool
    public let colAbs: Bool
    public init(row: Int64, col: Int64, rowAbs!: Bool = false, colAbs!: Bool = false)
    public static func parse(s: String): ?CellRef
    public static func parseRange(s: String): ?(CellRef, CellRef)
    public func toString(): String
    public func toA1(): String
    public func compare(that: CellRef): Ordering
}
```

`CellRef` 的相等与排序只看 `row` / `col`；`$` 只影响 `toA1()` 的显示。

### 值类型

```cangjie
public enum NumberFormat {
    | General
    | Builtin(Int64)
    | Custom(String)
}

public enum CellValue {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(String)
    | Date(DateTime)
    | TimeSpan(Duration)
    | Formula(String, Option<CellValue>)
}
```

- `Formula(src, cached)`：`src` 不带前导 `=`，读取时只保留原文与缓存值，不自动求值。
- 日期格式返回 `Date`；`[h]:mm:ss` 时长格式返回 `TimeSpan`。
- `Some(CellValue.Empty)` 表示文件中存在该 `<c>` 但值为空；`None` 表示单元格不存在。

### `ExcelDocument`

```cangjie
public class ExcelDocument {
    public init()                                      // 空白工作簿，默认 Sheet1
    public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions())
    public init(path: Path, options!: ExcelReadOptions = ExcelReadOptions())

    public func sheets(): ArrayList<Worksheet>
    public func sheet(name: String): ?Worksheet
    public func sheetAt(index: Int64): ?Worksheet
    public func sheetCount(): Int64
    public func addSheet(name: String): Worksheet
    public func removeSheet(name: String): Bool
    public func renameSheet(oldName: String, newName: String): Bool
    public prop date1904: Bool
    public func warnings(): ArrayList<ExcelWarning>
    public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions())
    public func write(path: Path, options!: ExcelWriteOptions = ExcelWriteOptions())
}
```

- 构造即解析整份文档（`eager = true`）；`eager = false` 时首次访问 sheet 才解析，`InputStream` 输入会先落临时文件。
- `write(output)` **不关闭**调用方的流；`write(path)` 负责创建 / 关闭文件，失败会留下残缺文件。
- sheet 名不能为空、超过 31 字符或包含 `[]:*?/\`，重复名抛 `ExcelException`。

### `Worksheet`

```cangjie
public class Worksheet {
    public prop name: String
    public func rowCount(): Int64
    public func colCount(): Int64
    public func dimension(): ?String

    public func cell(row: Int64, col: Int64): ?CellValue
    public func cell(ref: String): ?CellValue
    public func cell(ref: CellRef): ?CellValue
    public func setCell(row: Int64, col: Int64, value: CellValue): Unit
    public func setCell(ref: String, value: CellValue): Unit
    public func setCell(ref: CellRef, value: CellValue): Unit
    public func clearCell(row: Int64, col: Int64): Unit
    public func clearCell(ref: String): Unit
    public func rowValues(row: Int64): Array<(Int64, CellValue)>
    public func range(from: String, to: String): Array<Array<CellValue>>

    public func mergedRanges(): ArrayList<String>
    public func mergedRangeAt(row: Int64, col: Int64): ?String
    public func mergedValue(row: Int64, col: Int64): ?CellValue
    public func merge(range: String): Unit
    public func merge(from: String, to: String): Unit
    public func unmerge(range: String): Bool

    public func styleOf(row: Int64, col: Int64): ?CellStyle
    public func setStyle(row: Int64, col: Int64, style: CellStyle): Unit
    public func richText(row: Int64, col: Int64): ?RichText
    public func setRichText(row: Int64, col: Int64, value: RichText): Unit

    public func conditionalFormats(): ArrayList<ConditionalFormat>
    public func addConditionalFormat(range: String, rule: CfRule): Unit
    public func matchedRules(row: Int64, col: Int64): ArrayList<CfMatch>

    public func addImage(path: Path, from: String, to: String): Unit
    public func addImage(data: Array<Byte>, format: ImageFormat, from: String, to: String): Unit
    public func imageCount(): Int64
}
```

- 单元格坐标从 1 开始；越界 `setCell` / `setStyle` 抛 `ExcelException`，越界读取返回 `None`。
- `range` 返回左上 → 右下的二维块，缺失格子为 `CellValue.Empty`。
- 合并区域不能重叠；`merge` 抛异常，`unmerge` 返回是否删除。
- `matchedRules` 只求值不需要公式引擎的规则；含 `expression` 的规则请用 `CalcEngine.matchedRules`。
- 图片只支持写入（png / jpeg，按文件扩展名判定），读取不导入图片。

### 样式

```cangjie
public struct CellStyle {
    public let numberFormat: NumberFormat
    public let font: Font
    public let fill: Fill
    public let border: Border
    public let alignment: Alignment
    public let protection: Protection
    public let namedStyle: ?String
    public init(numberFormat!: NumberFormat = NumberFormat.General, font!: Font = Font.default(),
        fill!: Fill = Fill.none(), border!: Border = Border.none(),
        alignment!: Alignment = Alignment.default(), protection!: Protection = Protection.default(),
        namedStyle!: ?String = None)
    public func withFont(value: Font): CellStyle
    public func withFill(value: Fill): CellStyle
    public func withNumberFormat(value: NumberFormat): CellStyle
    public func withAlignment(value: Alignment): CellStyle
    public func withBorder(value: Border): CellStyle
}
```

| 类型 | 关键字段 / 构造 |
| --- | --- |
| `Color` | `Rgb(String)` / `Theme(Int64, Float64)` / `Indexed(Int64)` |
| `Font` | `name?` / `size` / `bold` / `italic` / `underline` / `strike` / `color?` / `family` / `charset` / `scheme?` |
| `Fill` | `patternType` / `fgColor?` / `bgColor?` / `gradient?`；`Fill.solid(color)` / `Fill.none()` |
| `Border` | `left` / `right` / `top` / `bottom` / `diagonal`；`BorderSide(style!, color!)` |
| `Alignment` | `horizontal` / `vertical` / `wrapText` / `textRotation` / `indent` / `shrinkToFit` |
| `Protection` | `locked` / `hidden` |
| `Gradient` | `kind` / `degree` / `stops: ArrayList<GradientStop>` |

样式池按值去重，`CellStyle` 可直接传给 `Worksheet.setStyle`。

### 流式读

```cangjie
public class ExcelSheetStream {
    public static func open(path: Path, options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public static func open(input: InputStream, options!: ExcelStreamReadOptions = ExcelStreamReadOptions()): ExcelSheetStream
    public func sheetNames(): Array<String>
    public func rows(sheet: String): ?RowReader
    public func rowsAt(index: Int64): ?RowReader
    public func lastMergedRanges(sheet: String): ArrayList<String>
    public func warnings(): ArrayList<ExcelWarning>
    public func close(): Unit
}

public class RowReader <: Iterator<RowData> {
    public func next(): Option<RowData>
    public func close(): Unit
    public func mergedRanges(): ArrayList<String>
}
```

- `open(path)` 走 `ZipReader(path)` 的 seek；`open(input)` 默认先落临时文件，`spool = false` 时退化为全量缓冲并记 `SpoolDisabled`。
- `next()` 才推进解析；返回 `None` 表示该 sheet 结束。
- 流未结束时 `mergedRanges()` 返回空并记 `MergedRangesUnavailable`；流结束后才可用。
- 关闭 `RowReader` 只结束当前 sheet；`ExcelSheetStream.close()` 才释放 ZIP / spool 临时文件。

### 流式写

```cangjie
public class ExcelWriter {
    public init(output: OutputStream, sheetNames: Array<String>,
        options!: ExcelWriteOptions = ExcelWriteOptions())
    public prop rowsWritten: Int64
    public func warnings(): ArrayList<ExcelWarning>
    public func writeSheet(name: String, rows: Iterator<RowData>,
        options!: SheetWriteOptions = SheetWriteOptions()): Unit
    public func finish(): Unit
}
```

- `sheetNames` 必须在构造时一次给全，`writeSheet` 必须按该顺序写；否则抛 `ExcelException`。
- `RowData.index` 必须严格递增，`cells` 必须按 `col` 严格升序且不重复。
- `finish()` 写 `styles.xml` 并关闭 ZIP；之后 writer 不可再用。中途失败后所有写操作都抛异常，产物应由调用方丢弃。
- `rowsWritten` 是当前 sheet 已写行数，每次 `writeSheet` 归零。

### 行模型

```cangjie
public struct Cell {
    public let col: Int64
    public let value: CellValue
    public let numberFormat: ?NumberFormat
    public let style: ?CellStyle
    public init(col: Int64, value: CellValue, numberFormat!: ?NumberFormat = None,
        style!: ?CellStyle = None)
}

public struct RowData {
    public let index: Int64
    public let cells: Array<Cell>
    public let height: ?Float64
    public init(index: Int64, cells: Array<Cell>, height!: ?Float64 = None)
}
```

读写共用同一组类型，`RowReader` 可直接作为 `Iterator<RowData>` 喂给 `ExcelWriter.writeSheet`。

### 公式计算

```cangjie
public class CalcEngine {
    public init(doc: ExcelDocument)
    public func document(): ExcelDocument
    public func evaluate(sheet: String, ref: String): CalcValue
    public func evaluate(sheet: String, ref: CellRef): CalcValue
    public func evaluateCell(sheet: String, ref: String): CellValue
    public func recalculate(sheet!: ?String = None, writeBack!: Bool = false): CalcReport
    public func matchedRules(sheet: String, row: Int64, col: Int64): ArrayList<CfMatch>
    public func buildGraph(): DependencyGraph
}

public struct CalcReport {
    public let recalculated: Int64
    public let errors: Int64
    public let cycles: ArrayList<String>
    public let issues: ArrayList<String>
}
```

- 默认不自动重算：读取拿缓存值，`evaluate` 是显式求值，`recalculate` 是显式重算。
- `writeBack = true` 把结果写回公式的缓存值，公式原文保留。
- 循环引用产生 `#CIRC!`；数组结果溢出冲突时写 `#SPILL!`。

```cangjie
public enum CalcValue {
    | Empty
    | Number(Float64)
    | Text(String)
    | Boolean(Bool)
    | Error(CalcError)
    | ArrayValue(Array<Array<CalcValue>>)
}

public enum CalcError {
    | Null | DivZero | Value | Ref | Name | Num | NotAvailable
    | GettingData | Circular | Spill | Calc
}
```

`CalcError.toString()` 返回 Excel 文本（`#DIV/0!` 等）；`CalcValue.isError()` / `asError()` 用于判断。

### 条件格式

```cangjie
public struct ConditionalFormat {
    public let range: String
    public let rules: ArrayList<CfRule>
    public init(range: String, rules: ArrayList<CfRule>)
}

public struct CfRule {
    public let ruleType: CfRuleType
    public let priority: Int64
    public let stopIfTrue: Bool
    public let comparison: CfOperator
    public let formulas: ArrayList<String>
    public let text: ?String
    public let format: ?CfFormat
    public let colorScale: ?CfColorScale
    public let dataBar: ?CfDataBar
    public let iconSet: ?CfIconSet
    public init(ruleType: CfRuleType, priority!: Int64 = 1, stopIfTrue!: Bool = false,
        comparison!: CfOperator = CfOperator.NoOperator, formulas!: ArrayList<String> = ArrayList<String>(),
        text!: ?String = None, format!: ?CfFormat = None, colorScale!: ?CfColorScale = None,
        dataBar!: ?CfDataBar = None, iconSet!: ?CfIconSet = None)
}
```

`CfRuleType` 覆盖 ECMA-376 的常用规则（`cellIs` / `expression` / 文本 / colorScale / dataBar /
iconSet 等）以及空白 / 错误 / `aboveAverage` 扩展；`Cfvo` 描述 `min` / `max` / `num` /
`percent` / `percentile` / `formula` 阈值。`matchedRules` 返回 `CfMatch(rule, format)`，
按 `priority` 排序，`stopIfTrue` 命中后停止。

### 富文本与图片

```cangjie
public struct RunFont {
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let size: ?Float64
    public let color: ?String
    public let name: ?String
}
public struct TextRun { public let text: String; public let font: ?RunFont }
public struct RichText { public let runs: ArrayList<TextRun>; public func text(): String }

public enum ImageFormat { | Png | Jpeg }
```

`RichText` 只读：`Worksheet.richText` 返回 sharedStrings 的分段字体，写侧仍写 `inlineStr`
并平坦化为普通文本。图片支持 png / jpeg，锚定到 `[from, to]` 单元格区域，读取侧不导入。

### 选项

```cangjie
public class ExcelReadOptions {
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0          // 0 = 不限
    public var maxCols: Int64 = 0
    public var skipSheets: Array<String> = []
    public var eager: Bool = true
}

public class ExcelStreamReadOptions {
    public var spool: Bool = true
    public var spoolDir: ?Path = None
    public var loadRowHeight: Bool = true
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var sharedStringsIndex: Bool = false
    public var maxRows: Int64 = 0
    public var maxCols: Int64 = 0
}

public class ExcelWriteOptions {
    public var date1904: ?Bool = None      // None = 跟随文档；流式写取 1900
}

public class SheetWriteOptions {
    public var dimension: ?String = None   // None = 省略 <dimension>
    public var maxCellStyles: Int64 = 64000
}
```

### 异常与告警

```cangjie
public open class ExcelException <: BaseException {
    public init(message: String)
    public init(message: String, caused: Exception)
}

public class ExcelWarning {
    public let kind: ExcelWarningKind
    public let message: String
    public let sheet: ?String
    public let ref: ?CellRef
}

public enum ExcelWarningKind {
    | MissingRowIndex | MissingCellRef | InvalidCellRef | RowOrderViolation
    | SharedStringIndexOutOfRange | NumberParseFailed | UnknownCellType | DateSerial60
    | UnsupportedTimeFormat | SharedFormulaUnsupported | ArrayFormulaUnsupported
    | IndexDegraded | AutoDetectDateDisabled | DateBaseMismatch | StylesMissing
    | SheetSkipped | SheetEntryMissing | MaxRowsTruncated | MaxColsTruncated
    | SpoolDisabled | ControlCharStripped | NumberFormatNotSupportedInM1
    | MergedRangesUnavailable
}
```

告警不打断解析，通过 `ExcelDocument.warnings()` / `ExcelSheetStream.warnings()` /
`ExcelWriter.warnings()` 读取；结构性错误抛 `ExcelException`。

## 已知缺口（M1 范围）

- **样式**：`theme1.xml` 只按 tint 线性插值，主题色板未完整解析。
- **公式**：动态数组只做到函数返回数组，`#SPILL!` 溢出未实现；`OFFSET` / `INDIRECT` 为动态依赖，不参与静态依赖图。
- **紧凑存储**：稠密数值表 100 万格 RSS 增量约 3 MB；稀疏/混合表回退到列式坐标存储，约 29 MB。
- **富文本**：只读不写，写侧平坦化为普通文本（样式丢失）。
- **富文本**：只读不写，写侧平坦化为普通文本（样式丢失）。
- **图片**：只支持写入（png / jpeg、两单元格锚定）；读取时不导入图片，含图片的文件往返后图片会丢失。
- **条件格式**：`timePeriod` / `aboveAverage` 只保留不求值；图标集不生成图片。
- **共享字符串写出**：只写 `inlineStr`，不生成 `xl/sharedStrings.xml`。
- **流式读的合并区域**：流中拿不到（`<mergeCells>` 在 `<sheetData>` 之后），流结束后 `mergedRanges()` 才可用。
- **流式读的常驻内存**：只有 `sharedStrings` 随文件增长；`loadSharedStrings = false` 可关。
- 不支持图表 / 数据透视表 / 批注 / 数据验证 / ods。

## 测试与夹具

- `cjpm test` 全绿（183 条）。
- 夹具用 `f_zip.ZipWriter` 现场拼最小 xlsx（`fixtures.cj`），不依赖外部样本文件。
- 「真实 Excel 打开不报修复」属人工验收项，记录见 `doc/spec/implement-f-excel-m1/verification.md`。
