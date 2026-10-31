/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_excel

import std.collection.ArrayList
import std.io.OutputStream
import fountain::f_zip.ZipWriter

/**
 * 流式写入：`Iterator<RowData>` → `f_xml.XmlWriter` 增量事件 → `ZipWriter.openEntry`。
 *
 * sheet 清单必须在构造时一次给全（`[Content_Types].xml` 是第一个条目，ZIP 顺序写无法回填）。
 * 失败即残缺：中途异常后 `writeSheet` / `finish` 一律抛，产物由调用方丢弃。
 */
public class ExcelWriter {
    private let zip: ZipWriter
    private let names: Array<String>
    private let options: ExcelWriteOptions
    private let styles = StylePool()
    private let warnings_ = ArrayList<ExcelWarning>()
    private var nextSheet = 0
    private var failed = false
    private var finished = false
    private var failure = ""
    private var rowsWritten_ = 0

    public init(
        output: OutputStream,
        sheetNames: Array<String>,
        options!: ExcelWriteOptions = ExcelWriteOptions()
    ) {
        if (sheetNames.size == 0) {
            throw ExcelException("sheet 清单不能为空")
        }
        let seen = ArrayList<String>()
        for (name in sheetNames) {
            if (name.isEmpty()) {
                throw ExcelException("sheet 名不能为空")
            }
            if (name.toArray().size > 31) {
                throw ExcelException("sheet 名不得超过 31 个字符：${name}")
            }
            for (b in name.toArray()) {
                if (b == 91u8 || b == 93u8 || b == 58u8 || b == 42u8 || b == 63u8 || b == 47u8 || b == 92u8) {
                    throw ExcelException("sheet 名不能包含 []:*?/\\ 中的字符：${name}")
                }
            }
            for (other in seen) {
                if (other == name) {
                    throw ExcelException("sheet 名重复：${name}")
                }
            }
            seen.add(name)
        }
        this.names = sheetNames
        this.options = options
        this.zip = ZipWriter(output)
        zip.add("[Content_Types].xml", PackageWriter.contentTypes(Int64(sheetNames.size)))
        zip.add("_rels/.rels", PackageWriter.rootRels())
        zip.add(
            "xl/workbook.xml",
            PackageWriter.workbookXmlFromNames(sheetNames, options.date1904 ?? false)
        )
        zip.add("xl/_rels/workbook.xml.rels", PackageWriter.workbookRels(Int64(sheetNames.size)))
    }

    /** 本 sheet 已写行数（每次 `writeSheet` 归零）。 */
    public prop rowsWritten: Int64 {
        get() {
            rowsWritten_
        }
    }

    public func warnings(): ArrayList<ExcelWarning> {
        warnings_
    }

    public func writeSheet(
        name: String,
        rows: Iterator<RowData>,
        options!: SheetWriteOptions = SheetWriteOptions()
    ): Unit {
        ensureUsable()
        if (nextSheet >= names.size) {
            fail("sheet 清单已写完，不能再写 ${name}")
        }
        if (names[nextSheet] != name) {
            fail("sheet 顺序不一致：期望 ${names[nextSheet]}，实际 ${name}")
        }
        let entry = try {
            zip.openEntry("xl/worksheets/sheet${nextSheet + 1}.xml")
        } catch (e: Exception) {
            fail("无法打开条目：${e.message}")
        }
        let date1904 = this.options.date1904 ?? false
        let writer = SheetXmlWriter(entry, styles, date1904, name, warnings_, maxCellStyles: options.maxCellStyles)
        rowsWritten_ = 0
        var lastIndex: Int64 = 0
        try {
            writer.begin(options.dimension)
            while (let Some(row) <- rows.next()) {
                if (row.index < 1 || row.index > EXCEL_MAX_ROW) {
                    throw ExcelException("行号 ${row.index} 超出 1..${EXCEL_MAX_ROW}")
                }
                if (row.index <= lastIndex) {
                    throw ExcelException("行号必须严格递增：${row.index} 在 ${lastIndex} 之后")
                }
                var lastCol: Int64 = 0
                for (cell in row.cells) {
                    if (cell.col < 1 || cell.col > EXCEL_MAX_COL) {
                        throw ExcelException("列号 ${cell.col} 超出 1..${EXCEL_MAX_COL}")
                    }
                    if (cell.col <= lastCol) {
                        throw ExcelException("cells 必须按 col 严格升序：${cell.col} 在 ${lastCol} 之后")
                    }
                    lastCol = cell.col
                }
                writer.row(row)
                rowsWritten_++
                lastIndex = row.index
            }
            writer.end(ArrayList<String>(), ArrayList<ConditionalFormat>())
            entry.close()
        } catch (e: Exception) {
            try {
                entry.close()
            } catch (_: Exception) {}
            fail(e.message)
        }
        nextSheet++
    }

    /** 写 `styles.xml` 并关闭 ZIP（中央目录 + EOCD）；之后不可再用。 */
    public func finish(): Unit {
        ensureUsable()
        if (nextSheet != names.size) {
            fail("还有 ${names.size - nextSheet} 个 sheet 未写")
        }
        try {
            zip.add("xl/styles.xml", StylesWriter.write(styles))
            zip.close()
        } catch (e: Exception) {
            fail(e.message)
        }
        finished = true
    }

    private func ensureUsable(): Unit {
        if (failed) {
            throw ExcelException("流式写入已失败：${failure}")
        }
        if (finished) {
            throw ExcelException("流式写入已完成，不能继续写")
        }
    }

    private func fail(reason: String): Nothing {
        failed = true
        failure = reason
        throw ExcelException("流式写入已失败：${reason}")
    }
}
