# f_excel

Excel (xlsx / OOXML) reader and writer: **streaming parse, streaming generate**, date detection, merged cells.

- Package: `fountain::f_excel`
- Dependencies: `f_base`, `f_log`, `f_util`, `f_xml` (XML parsing / incremental writing), `f_zip` (OOXML container)
- Design document: [`doc/f_excel模块设计.md`](doc/f_excel模块设计.md) (Chinese)
- Specs and tasks: [`doc/spec/implement-f-excel-m1/`](doc/spec/implement-f-excel-m1/)

## Capabilities (M1)

| Capability | Description |
|---|---|
| Whole-document read | `ExcelDocument(input)` / `ExcelDocument(path)`: sheet list, seven value kinds, sharedStrings, merged ranges, date detection |
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

Full `cjpm test`: **181 passed / 0 failed**.

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

## Known gaps (M1 scope)

- **Styles**: only date `numFmtId` and a fixed minimal `styles.xml`; fonts / fills / borders / alignment / theme colors are M2.
- **Formulas**: source and cached value only; no evaluation, no dependency graph.
- **Durations / rich text**: `[h]:mm:ss` comes back as `Date` plus a warning; rich text is flattened to `Text`.
- **Images**: write-only (png / jpeg, two-cell anchor); the reader does not import them, so they are lost on a round trip.
- **Conditional formatting**: `timePeriod` / `aboveAverage` are preserved but not evaluated; icon sets do not generate images.
- **Shared-string writing**: `inlineStr` only; `xl/sharedStrings.xml` is never produced.
- **Merged ranges in streaming read**: unavailable during the stream (`<mergeCells>` follows `<sheetData>`); `mergedRanges()` is valid after it ends.
- **Resident memory in streaming read**: only `sharedStrings` grows with the file; disable it with `loadSharedStrings = false`.
- No charts / pivot tables / comments / data validation / ods.

## Tests and fixtures

- `cjpm test` green (181 cases).
- Fixtures build minimal xlsx packages in memory with `f_zip.ZipWriter` (`fixtures.cj`); no external sample files.
- "Real Excel opens it without repair" is a manual acceptance item, recorded in `doc/spec/implement-f-excel-m1/verification.md`.
