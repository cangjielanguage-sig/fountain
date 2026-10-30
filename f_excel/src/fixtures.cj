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

import std.io.ByteBuffer
import fountain::f_zip.ZipWriter

internal let NS_MAIN: String = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
internal let NS_REL: String = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
internal let NS_PKG_REL: String = "http://schemas.openxmlformats.org/package/2006/relationships"
internal let NS_CONTENT_TYPES: String = "http://schemas.openxmlformats.org/package/2006/content-types"

internal func contentTypesXml(sheetCount: Int64): String {
    var overrides = ""
    for (i in 1..=sheetCount) {
        overrides +=
            "<Override PartName=\"/xl/worksheets/sheet${i}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
        "<Types xmlns=\"${NS_CONTENT_TYPES}\">" +
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
        overrides + "</Types>"
}

internal func rootRelsXml(): String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
        "<Relationships xmlns=\"${NS_PKG_REL}\">" +
        "<Relationship Id=\"rId1\" Type=\"${NS_REL}/officeDocument\" Target=\"xl/workbook.xml\"/>" +
        "</Relationships>"
}

internal func workbookXml(sheetNames: Array<String>, date1904!: Bool = false): String {
    var sheets = ""
    for (i in 0..sheetNames.size) {
        sheets +=
            "<sheet name=\"${escapeXml(sheetNames[i])}\" sheetId=\"${i + 1}\" r:id=\"rId${i + 1}\"/>"
    }
    let pr = if (date1904) {
        "<workbookPr date1904=\"1\"/>"
    } else {
        ""
    }
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
        "<workbook xmlns=\"${NS_MAIN}\" xmlns:r=\"${NS_REL}\">" + pr +
        "<sheets>${sheets}</sheets></workbook>"
}

internal func workbookRelsXml(sheetCount: Int64): String {
    var rels = ""
    for (i in 1..=sheetCount) {
        rels +=
            "<Relationship Id=\"rId${i}\" Type=\"${NS_REL}/worksheet\" Target=\"worksheets/sheet${i}.xml\"/>"
    }
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
        "<Relationships xmlns=\"${NS_PKG_REL}\">" + rels + "</Relationships>"
}

internal func worksheetXml(rows: String): String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
        "<worksheet xmlns=\"${NS_MAIN}\"><sheetData>${rows}</sheetData></worksheet>"
}

internal func escapeXml(value: String): String {
    var out = ""
    for (r in value.runes()) {
        match (r) {
            case r'&' => out += "&amp;"
            case r'<' => out += "&lt;"
            case r'>' => out += "&gt;"
            case r'"' => out += "&quot;"
            case _ => out += r.toString()
        }
    }
    out
}

/** 用 f_zip 拼一个最小 xlsx（测试夹具）。`sheets` 按顺序对应 sheet1..N.xml。 */
internal func buildXlsx(
    sheets: Array<String>,
    names!: Array<String> = ["Sheet1"],
    parts!: Array<(String, String)> = [],
    date1904!: Bool = false,
    includeWorkbook!: Bool = true,
    includeRels!: Bool = true
): Array<Byte> {
    let out = ByteBuffer(4 * 1024 * 1024)
    let zip = ZipWriter(out)
    zip.add("[Content_Types].xml", contentTypesXml(Int64(sheets.size)).toArray())
    zip.add("_rels/.rels", rootRelsXml().toArray())
    if (includeWorkbook) {
        zip.add("xl/workbook.xml", workbookXml(names, date1904: date1904).toArray())
    }
    if (includeRels) {
        zip.add("xl/_rels/workbook.xml.rels", workbookRelsXml(Int64(sheets.size)).toArray())
    }
    for (i in 0..sheets.size) {
        zip.add("xl/worksheets/sheet${i + 1}.xml", sheets[i].toArray())
    }
    for (part in parts) {
        zip.add(part[0], part[1].toArray())
    }
    zip.close()
    out.bytes()
}
