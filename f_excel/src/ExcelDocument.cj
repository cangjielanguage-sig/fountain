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
import std.fs.{File, OpenMode, Path}
import std.io.{InputStream, OutputStream}
import fountain::f_zip.ZipReader

/**
 * 一份工作簿（整文档模型）。
 *
 * 读取是**整文档**语义：构造时把全部 sheet 解析进 [Worksheet]；要逐行处理大表用
 * [ExcelSheetStream]（内存与行数无关）。
 */
public class ExcelDocument {
    private let sheetList = ArrayList<Worksheet>()
    private var date1904Flag = false
    private let warnings_ = ArrayList<ExcelWarning>()

    /** 新建一个空白工作簿，默认含 `Sheet1`，不发任何 I/O。 */
    public init() {
        this.sheetList.add(Worksheet("Sheet1"))
    }

    public init(input: InputStream, options!: ExcelReadOptions = ExcelReadOptions()) {
        let zip = try {
            ZipReader(input)
        } catch (e: Exception) {
            throw ExcelException("不是有效的 xlsx 文件", e)
        }
        try {
            load(zip, options)
        } finally {
            zip.close()
        }
    }

    public init(path: Path, options!: ExcelReadOptions = ExcelReadOptions()) {
        let file = try {
            File(path, OpenMode.Read)
        } catch (e: Exception) {
            throw ExcelException("无法打开文件：${path}", e)
        }
        let zip = try {
            ZipReader(file)
        } catch (e: Exception) {
            try {
                file.close()
            } catch (_: Exception) {}
            throw ExcelException("不是有效的 xlsx 文件", e)
        }
        try {
            load(zip, options)
        } finally {
            zip.close()
            try {
                file.close()
            } catch (_: Exception) {}
        }
    }

    private func load(zip: ZipReader, options: ExcelReadOptions): Unit {
        let info = try {
            PackageReader.read(zip)
        } catch (e: ExcelException) {
            throw e
        } catch (e: Exception) {
            throw ExcelException("不是有效的 xlsx 文件", e)
        }
        this.date1904Flag = match (options.date1904) {
            case Some(v) => v
            case None => info.date1904
        }
        for (warning in info.warnings) {
            warnings_.add(warning)
        }
        var sst = SharedStringTable.empty()
        if (options.loadSharedStrings) {
            match (zip.read("xl/sharedStrings.xml")) {
                case Some(bytes) =>
                    sst = try {
                        SharedStringTable.load(bytes)
                    } catch (e: Exception) {
                        throw ExcelException("sharedStrings.xml 解析失败", e)
                    }
                case None => ()
            }
        }
        var styles = StylesLite.empty()
        if (options.loadStyles) {
            match (zip.read("xl/styles.xml")) {
                case Some(bytes) => styles = StylesLite.load(bytes)
                case None => ()
            }
        } else if (options.autoDetectDate) {
            warnings_.add(
                ExcelWarning(
                    ExcelWarningKind.AutoDetectDateDisabled,
                    "loadStyles=false，日期识别自动降级为关闭"
                )
            )
        }
        for (entry in info.sheets) {
            var skipped = false
            for (name in options.skipSheets) {
                if (name == entry.name) {
                    skipped = true
                    break
                }
            }
            if (skipped) {
                warnings_.add(
                    ExcelWarning(ExcelWarningKind.SheetSkipped, "按选项跳过 sheet", sheet: Some(entry.name))
                )
                continue
            }
            let sheet = Worksheet(entry.name)
            match (zip.read(entry.partName)) {
                case Some(bytes) =>
                    let parsed = WorksheetParser.parseSheet(
                        bytes,
                        options,
                        sst,
                        entry.name,
                        styles: styles,
                        date1904Override: Some(this.date1904Flag)
                    )
                    for (row in parsed.rows) {
                        for (entry in parsed.richTexts) {
                            if (entry[0] == row.index) {
                                sheet.setRichText(entry[0], entry[1], entry[2])
                            }
                        }
                        for (cell in row.cells) {
                            sheet.setCell(row.index, cell.col, cell.value)
                            match (cell.style) {
                                case Some(style) => sheet.setStyle(row.index, cell.col, style)
                                case None => ()
                            }
                        }
                    }
                    for (format in parsed.cfList) {
                        for (rule in format.rules) {
                            try {
                                sheet.addConditionalFormat(format.range, rule)
                            } catch (e: ExcelException) {
                                warnings_.add(
                                    ExcelWarning(
                                        ExcelWarningKind.SheetEntryMissing,
                                        e.message,
                                        sheet: Some(entry.name)
                                    )
                                )
                            }
                        }
                    }
                    sheet.setDimension(parsed.dimension)
                    for (range in parsed.merges) {
                        try {
                            sheet.merge(range)
                        } catch (e: ExcelException) {
                            warnings_.add(
                                ExcelWarning(ExcelWarningKind.SheetEntryMissing, e.message, sheet: Some(entry.name))
                            )
                        }
                    }
                    for (warning in parsed.warnings) {
                        warnings_.add(warning)
                    }
                case None =>
                    warnings_.add(
                        ExcelWarning(
                            ExcelWarningKind.SheetEntryMissing,
                            "sheet 部件读取失败：${entry.partName}",
                            sheet: Some(entry.name)
                        )
                    )
            }
            sheetList.add(sheet)
        }
        if (sheetList.size == 0) {
            sheetList.add(Worksheet("Sheet1"))
        }
    }

    public func sheets(): ArrayList<Worksheet> {
        sheetList
    }

    public func sheet(name: String): ?Worksheet {
        for (s in sheetList) {
            if (s.name == name) {
                return Some(s)
            }
        }
        None<Worksheet>
    }

    public func sheetAt(index: Int64): ?Worksheet {
        if (index < 0 || index >= Int64(sheetList.size)) {
            return None<Worksheet>
        }
        Some(sheetList[index])
    }

    public func sheetCount(): Int64 {
        Int64(sheetList.size)
    }

    private func validateName(name: String): Unit {
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
    }

    public func addSheet(name: String): Worksheet {
        validateName(name)
        if (sheet(name).isSome()) {
            throw ExcelException("sheet 已存在：${name}")
        }
        let sheet = Worksheet(name)
        sheetList.add(sheet)
        sheet
    }

    public func removeSheet(name: String): Bool {
        for (i in 0..sheetList.size) {
            if (sheetList[i].name == name) {
                sheetList.remove(at: i)
                return true
            }
        }
        false
    }

    public func renameSheet(oldName: String, newName: String): Bool {
        validateName(newName)
        if (sheet(oldName).isNone()) {
            return false
        }
        if (sheet(newName).isSome()) {
            throw ExcelException("sheet 已存在：${newName}")
        }
        for (i in 0..sheetList.size) {
            if (sheetList[i].name == oldName) {
                sheetList[i] = Worksheet(newName)
                return true
            }
        }
        false
    }

    public prop date1904: Bool {
        get() {
            date1904Flag
        }
    }

    public func warnings(): ArrayList<ExcelWarning> {
        warnings_
    }

    /** 写出最小可用 xlsx；**不关闭**调用方的流。 */
    public func write(output: OutputStream, options!: ExcelWriteOptions = ExcelWriteOptions()) {
        let base1904 = match (options.date1904) {
            case Some(v) => v
            case None => date1904Flag
        }
        PackageWriter.write(output, sheetList, base1904, warnings_)
    }

    /** 写文件；失败时留下的是残缺文件（ZIP 顺序写无法回滚）。 */
    public func write(path: Path, options!: ExcelWriteOptions = ExcelWriteOptions()) {
        let file = try {
            File(path, OpenMode.Write)
        } catch (e: Exception) {
            throw ExcelException("无法创建文件：${path}", e)
        }
        try {
            write(file, options: options)
        } finally {
            try {
                file.close()
            } catch (_: Exception) {}
        }
    }
}
