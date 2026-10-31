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
import fountain::f_xml.{XmlElement, XmlParser}
import fountain::f_zip.ZipReader

/** workbook.xml 里的一张表与它的部件路径。 */
internal struct SheetEntry {
    let name: String
    let partName: String

    init(name: String, partName: String) {
        this.name = name
        this.partName = partName
    }
}

/** 包级信息：sheet 清单、日期基准、告警。 */
internal class PackageInfo {
    let sheets: ArrayList<SheetEntry>
    let date1904: Bool
    let warnings: ArrayList<ExcelWarning>

    init(sheets: ArrayList<SheetEntry>, date1904: Bool, warnings: ArrayList<ExcelWarning>) {
        this.sheets = sheets
        this.date1904 = date1904
        this.warnings = warnings
    }
}

/**
 * 读 `xl/workbook.xml` / `xl/_rels/workbook.xml.rels`，得到"sheet 名 → 部件路径"。
 *
 * 单元格解析在 [WorksheetParser]；这里只关心包结构。
 */
internal class PackageReader {
    static func read(zip: ZipReader): PackageInfo {
        let warnings = ArrayList<ExcelWarning>()
        let workbookBytes = match (zip.read("xl/workbook.xml")) {
            case Some(bytes) => bytes
            case None => throw ExcelException("缺少 workbook.xml，可能不是 xlsx 文件")
        }
        let doc = try {
            XmlParser.parse(workbookBytes)
        } catch (e: Exception) {
            throw ExcelException("workbook.xml 解析失败", e)
        }
        let root = match (doc.root) {
            case Some(r) => r
            case None => throw ExcelException("缺少 workbook.xml，可能不是 xlsx 文件")
        }
        let date1904 = match (root.child("workbookPr")) {
            case Some(pr) => match (pr.attr("date1904")) {
                case Some(v) => v == "1" || v.toAsciiLower() == "true"
                case None => false
            }
            case None => false
        }
        var relationships = ArrayList<(String, String)>()
        match (zip.read("xl/_rels/workbook.xml.rels")) {
            case Some(relBytes) =>
                let relDoc = try {
                    XmlParser.parse(relBytes)
                } catch (e: Exception) {
                    throw ExcelException("workbook.xml.rels 解析失败", e)
                }
                if (let Some(relRoot) <- relDoc.root) {
                    for (rel in relRoot.childrenOf("Relationship")) {
                        let id = rel.attr("Id") ?? ""
                        let target = rel.attr("Target") ?? ""
                        if (!id.isEmpty() && !target.isEmpty()) {
                            relationships.add((id, resolvePart(target)))
                        }
                    }
                }
            case None => ()
        }
        let sheets = ArrayList<SheetEntry>()
        let sheetsElement = root.child("sheets")
        if (let Some(container) <- sheetsElement) {
            var ordinal: Int64 = 0
            for (sheet in container.childrenOf("sheet")) {
                ordinal++
                let name = sheet.attr("name") ?? "Sheet${ordinal}"
                let rid = sheet.attr(NS_REL, "id") ?? sheet.attr("id") ?? ""
                var partName = ""
                for (pair in relationships) {
                    if (pair[0] == rid) {
                        partName = pair[1]
                        break
                    }
                }
                if (partName.isEmpty() || !zip.contains(partName)) {
                    warnings.add(
                        ExcelWarning(
                            ExcelWarningKind.SheetEntryMissing,
                            "sheet「${name}」的部件不存在（r:id=${rid}）",
                            sheet: Some(name)
                        )
                    )
                    continue
                }
                sheets.add(SheetEntry(name, partName))
            }
        }
        PackageInfo(sheets, date1904, warnings)
    }

    /** `Target` 可能是绝对部件名（`/xl/...`）或相对 workbook（`worksheets/...`）。 */
    private static func resolvePart(target: String): String {
        if (target.startsWith("/")) {
            return target[1..]
        }
        if (target.startsWith("xl/")) {
            return target
        }
        "xl/${target}"
    }
}
