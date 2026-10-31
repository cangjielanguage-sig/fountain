# f_excel

Excel (xlsx / OOXML) reader and writer: **streaming parse, streaming generate**, date detection, merged cells.

- Package: `fountain::f_excel`
- Dependencies: `f_base`, `f_log`, `f_util`, `f_xml` (XML parsing / incremental writing), `f_zip` (OOXML container)
- Design document: [`doc/f_excel模块设计.md`](doc/f_excel模块设计.md) (Chinese)
- Specs and tasks: [`doc/spec/implement-f-excel-m1/`](doc/spec/implement-f-excel-m1/)

## Capabilities (M1)

| Capability | Description |
|---|---|
| Whole-document read | `ExcelDocument(input)` / `ExcelDocument(path)`: sheet list, value types, sharedStrings, merged ranges, date detection |
| Whole-document write | `ExcelDocument.write(output)` / `write(path)`: `inlineStr`, multiple sheets, merges, date/duration styles, images, full styles |
| **Streaming read** | `ExcelSheetStream.open(path/input)` → `RowReader`: pull rows one by one, **memory independent of row count** |
| **Streaming write** | `ExcelWriter`: row iterator → `f_xml.XmlWriter` incremental events → `f_zip.openEntry` push-mode compression |
| Value kinds | `Empty` / `Number` / `Text` / `Boolean` / `Error` / `Date` / `Formula` (source + cached only, never evaluated) |
| Dates | Built-in 14–22 / 45–47 plus custom-format heuristics; 1900 / 1904 bases; serial 60 kept as a number with a warning |
| Images (write) | `Worksheet.addImage(path/bytes, from, to)`: png / jpeg anchored to a cell range; the read side does not import images yet |
| Styles | Full read/write of `CellStyle` / `Font` / `Fill` / `Border` / `Alignment` / `Protection` / `Color`; `styles.xml` numFmts/fonts/fills/borders/cellXfs/cellStyles; value-deduplicated style pool |
| Formulas | Parse + evaluate + dependency graph: `CalcEngine.evaluate` / `recalculate`; 350 functions; shared-formula shifting; `#CIRC!` on cycles |
| Duration / rich text | `[h]:mm:ss` reads as `CellValue.TimeSpan`; `Worksheet.richText` exposes sharedStrings run fonts |
| Conditional formatting | `<conditionalFormatting>` / 13 `CfRuleType`s / `dxfs` read & write; `matchedRules` evaluation (cellIs/expression/text/colorScale/dataBar/iconSet) |

Full `cjpm test`: **183 passed / 0 failed**.

## Usage

### Read a workbook

```cangjie
import fountain::f_excel.*
import std.fs.Path

let doc = ExcelDocument(Path("/data/a.xlsx"))
let sheet = doc.sheet("Sheet1").getOrThrow()
let value = sheet.cell("A1")                       // ?CellValue
println(sheet.mergedValue(2, 1))                   // top-left value of the merged range
```

### Write a workbook

```cangjie
let doc = ExcelDocument()
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.setCell("A1", CellValue.Text("name"))
sheet.setCell("B1", CellValue.Number(0.1))
sheet.merge("A1:B1")
doc.write(Path("/data/out.xlsx"))
```

### Lazy parsing / shared-string index

```cangjie
let options = ExcelReadOptions()
options.eager = false                  // parse a sheet on first access
let doc = ExcelDocument(Path("big.xlsx"), options: options)

let streamOptions = ExcelStreamReadOptions()
streamOptions.sharedStringsIndex = true // spool sharedStrings and read on demand
let stream = ExcelSheetStream.open(Path("big.xlsx"), options: streamOptions)
```

### Formula evaluation

```cangjie
let engine = CalcEngine(doc)
let value = engine.evaluate("Sheet1", "B2")     // single cell, recursive dependencies
engine.recalculate(writeBack: true)              // recalculate all and write back caches
```

### Styles

```cangjie
sheet.setCell("A1", CellValue.Number(1234.5))
sheet.setStyle(1, 1, CellStyle(
    numberFormat: NumberFormat.Builtin(4),
    font: Font(bold: true, color: Color.Rgb("FFFF0000")),
    fill: Fill.solid(Color.Rgb("FFFFFF00")),
    alignment: Alignment(horizontal: Horizontal.Center, wrapText: true)
))
```

### Insert an image

```cangjie
let sheet = doc.sheet("Sheet1").getOrThrow()
sheet.addImage(Path("/data/logo.png"), "A4", "E12")   // anchored to A4:E12
```

### Streaming write (large tables, constant memory)

```cangjie
let writer = ExcelWriter(out, ["detail"])
writer.writeSheet("detail", rows.iterator())       // rows: Iterator<RowData>
writer.finish()                                    // writes central directory + EOCD; readable afterwards
```

### Streaming read (parse while reading)

```cangjie
let stream = ExcelSheetStream.open(Path("/data/big.xlsx"))
try {
    let reader = stream.rows("detail").getOrThrow()
    while (let Some(row) <- reader.next()) {
        for (cell in row.cells) {
            // cell.col / cell.value
        }
    }
    println(reader.mergedRanges())                 // available only after the stream ends
} finally {
    stream.close()
}
```

### Large-table copy (constant memory on both ends)

```cangjie
let src = ExcelSheetStream.open(Path("/data/big.xlsx"))
let out = File("/data/copy.xlsx", OpenMode.Write)
let writer = ExcelWriter(out, ["detail"])
writer.writeSheet("detail", src.rows("detail").getOrThrow())
writer.finish()
src.close()
out.close()
```

## API reference

### Constants and coordinates

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

`CellRef` equality and ordering use only `row` / `col`; `$` only affects the `toA1()` rendering.

### Value types

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

- `Formula(src, cached)`: `src` has no leading `=`; reads keep the source and cached value without
  automatic evaluation.
- Date formats produce `Date`; `[h]:mm:ss` duration formats produce `TimeSpan`.
- `Some(CellValue.Empty)` means the file contains a `<c>` with an empty value; `None` means the cell
  does not exist.

### `ExcelDocument`

```cangjie
public class ExcelDocument {
    public init()                                      // empty workbook with Sheet1
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

- Construction parses the whole workbook (`eager = true`); with `eager = false` a sheet is parsed on
  first access, and `InputStream` input is first spooled to a temp file.
- `write(output)` **does not close** the caller's stream; `write(path)` creates / closes the file and
  may leave a partial file on failure.
- Sheet names cannot be empty, longer than 31 characters, or contain `[]:*?/\`; duplicates throw
  `ExcelException`.

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

- Cell coordinates are 1-based; out-of-range `setCell` / `setStyle` throws `ExcelException`, while
  reads return `None`.
- `range` returns a top-left → bottom-right block; missing cells are `CellValue.Empty`.
- Merged ranges may not overlap; `merge` throws on overlap and `unmerge` returns whether it removed
  the range.
- `matchedRules` evaluates only rules that do not need the formula engine; use
  `CalcEngine.matchedRules` for `expression` rules.
- Images are write-only (png / jpeg, selected by file extension); reads do not import images.

### Styles

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

| Type | Key fields / constructors |
| --- | --- |
| `Color` | `Rgb(String)` / `Theme(Int64, Float64)` / `Indexed(Int64)` |
| `Font` | `name?` / `size` / `bold` / `italic` / `underline` / `strike` / `color?` / `family` / `charset` / `scheme?` |
| `Fill` | `patternType` / `fgColor?` / `bgColor?` / `gradient?`; `Fill.solid(color)` / `Fill.none()` |
| `Border` | `left` / `right` / `top` / `bottom` / `diagonal`; `BorderSide(style!, color!)` |
| `Alignment` | `horizontal` / `vertical` / `wrapText` / `textRotation` / `indent` / `shrinkToFit` |
| `Protection` | `locked` / `hidden` |
| `Gradient` | `kind` / `degree` / `stops: ArrayList<GradientStop>` |

The style pool deduplicates by value; a `CellStyle` can be passed directly to `Worksheet.setStyle`.

### Streaming read

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

- `open(path)` uses `ZipReader(path)` with seeking; `open(input)` spools to a temp file by default,
  and with `spool = false` falls back to full buffering and records `SpoolDisabled`.
- `next()` advances parsing; `None` means the sheet ended.
- `mergedRanges()` returns empty and records `MergedRangesUnavailable` before the sheet ends.
- Closing a `RowReader` ends the current sheet only; `ExcelSheetStream.close()` releases the ZIP and
  spool temp file.

### Streaming write

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

- `sheetNames` must be supplied in full at construction and `writeSheet` must follow that order;
  otherwise `ExcelException`.
- `RowData.index` must strictly increase; `cells` must be strictly increasing by `col`.
- `finish()` writes `styles.xml` and closes the ZIP; the writer is unusable afterwards. After a
  failure all writes throw and the caller should discard the output.
- `rowsWritten` is the current sheet's row count and resets on each `writeSheet`.

### Row model

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

Read and write share the same types, so a `RowReader` can be passed directly to
`ExcelWriter.writeSheet` as an `Iterator<RowData>`.

### Formula calculation

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

- No automatic recalculation: reads use cached values, `evaluate` is explicit evaluation, and
  `recalculate` is explicit recalculation.
- `writeBack = true` writes results into the cached value while preserving the formula source.
- Cycles produce `#CIRC!`; array spill conflicts write `#SPILL!`.

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

`CalcError.toString()` returns the Excel text (`#DIV/0!`, etc.); use `CalcValue.isError()` /
`asError()` for checks.

### Conditional formatting

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

`CfRuleType` covers the common ECMA-376 rules (`cellIs` / `expression` / text / colorScale /
dataBar / iconSet and others) plus blank / error / `aboveAverage` extensions; `Cfvo` describes
`min` / `max` / `num` / `percent` / `percentile` / `formula` thresholds. `matchedRules` returns
`CfMatch(rule, format)` ordered by `priority`, stopping after a `stopIfTrue` hit.

### Rich text and images

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

`RichText` is read-only: `Worksheet.richText` returns segmented sharedStrings fonts, while writing
still uses `inlineStr` and flattens to plain text. Images support png / jpeg anchored to a
`[from, to]` cell range; the reader does not import images.

### Options

```cangjie
public class ExcelReadOptions {
    public var autoDetectDate: Bool = true
    public var date1904: ?Bool = None
    public var loadStyles: Bool = true
    public var loadSharedStrings: Bool = true
    public var maxRows: Int64 = 0          // 0 = unlimited
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
    public var date1904: ?Bool = None      // None = follow the document; streaming uses 1900
}

public class SheetWriteOptions {
    public var dimension: ?String = None   // None = omit <dimension>
    public var maxCellStyles: Int64 = 64000
}
```

### Exceptions and warnings

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

Warnings do not stop parsing and are available from `ExcelDocument.warnings()` /
`ExcelSheetStream.warnings()` / `ExcelWriter.warnings()`; structural failures throw
`ExcelException`.

## Known gaps (M1 scope)

- **Styles**: only date `numFmtId` and a fixed minimal `styles.xml`; fonts / fills / borders / alignment / theme colors are M2.
- **Formulas**: source and cached value only; no evaluation, no dependency graph.
- **Rich text**: read-only; the writer flattens it to plain text (styles are lost).
- **Images**: write-only (png / jpeg, two-cell anchor); the reader does not import them, so they are lost on a round trip.
- **Conditional formatting**: `timePeriod` / `aboveAverage` are preserved but not evaluated; icon sets do not generate images.
- **Shared-string writing**: `inlineStr` only; `xl/sharedStrings.xml` is never produced.
- **Merged ranges in streaming read**: unavailable during the stream (`<mergeCells>` follows `<sheetData>`); `mergedRanges()` is valid after it ends.
- **Resident memory in streaming read**: only `sharedStrings` grows with the file; disable it with `loadSharedStrings = false`.
- No charts / pivot tables / comments / data validation / ods.

## Tests and fixtures

- `cjpm test` green (183 cases).
- Fixtures build minimal xlsx packages in memory with `f_zip.ZipWriter` (`fixtures.cj`); no external sample files.
- "Real Excel opens it without repair" is a manual acceptance item, recorded in `doc/spec/implement-f-excel-m1/verification.md`.
