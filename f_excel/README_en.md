# f_excel

Excel (xlsx / OOXML) reader and writer: **streaming parse, streaming generate**, styles and formulas.

- Package: `fountain::f_excel`
- Dependencies: `f_base`, `f_log`, `f_util`, `f_xml` (XML event parsing / DOM), `f_zip` (OOXML container)
- Design document: [`doc/f_excel模块设计.md`](doc/f_excel模块设计.md) (Chinese)

## Status

Module skeleton is in place; capabilities land milestone by milestone (M1 → M4) together with unit tests.

| Milestone | Scope |
|---|---|
| M1 | Worksheet / sharedStrings / merged cells reading, minimal viable output, date detection |
| M2 | Full style read/write, formula engine, `TimeSpan`, streaming generation |
| M3 | On-demand sheet parsing, array formulas, full function library |
| M4 | Conditional formatting semantics |

## Design highlights

- **Streaming parse**: pull rows one by one (`ExcelSheetStream` iterator); memory is independent of row count.
  `Path` input uses `f_zip` seek windows; non-seekable input is spooled to a temp file so it stays truly streaming.
- **Streaming generate**: `ExcelWriter` consumes a row iterator, and `f_zip.addFileStream` writes compressed
  XML as it is produced — peak memory is one row plus the compression buffer.
- **XML is delegated to `f_xml`**: namespace prefixes are matched via `QName.local`; no hand-written tag scanner.

## Usage

See chapter 2 of the design document; the usage section here is filled in once M1 lands.
