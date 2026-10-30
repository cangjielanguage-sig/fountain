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
| Whole-document write | `ExcelDocument.write(output)` / `write(path)`: minimal viable package (`inlineStr`), multiple sheets, merges, dates bound to styles |
| **Streaming read** | `ExcelSheetStream.open(path/input)` → `RowReader`: pull rows one by one, **memory independent of row count** |
| **Streaming write** | `ExcelWriter`: row iterator → `f_xml.XmlWriter` incremental events → `f_zip.openEntry` push-mode compression |
| Value kinds | `Empty` / `Number` / `Text` / `Boolean` / `Error` / `Date` / `Formula` (source + cached only, never evaluated) |
| Dates | Built-in 14–22 / 45–47 plus custom-format heuristics; 1900 / 1904 bases; serial 60 kept as a number with a warning |

Full `cjpm test`: **86 passed / 0 failed**.

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
- **Conditional formatting**: not preserved (M4 evaluates it semantically).
- **Shared-string writing**: `inlineStr` only; `xl/sharedStrings.xml` is never produced.
- **Merged ranges in streaming read**: unavailable during the stream (`<mergeCells>` follows `<sheetData>`); `mergedRanges()` is valid after it ends.
- **Resident memory in streaming read**: only `sharedStrings` grows with the file; disable it with `loadSharedStrings = false`.
- No charts / images / pivot tables / comments / data validation / ods.

## Tests and fixtures

- `cjpm test` green (86 cases).
- Fixtures build minimal xlsx packages in memory with `f_zip.ZipWriter` (`fixtures.cj`); no external sample files.
- "Real Excel opens it without repair" is a manual acceptance item, recorded in `doc/spec/implement-f-excel-m1/verification.md`.
