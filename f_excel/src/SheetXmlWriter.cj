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
import fountain::f_base.StringGenerator
import fountain::f_xml.{QName, XmlAttribute, XmlWriter}

/** `cellXfs` 的最小样式表：索引即单元格的 `s`。 */
internal class StyleTable {
    /** 每个 `s` 指向的 `numFmtId`；`s = 0` 恒为 General。 */
    private let formats = ArrayList<Int64>()

    init() {
        formats.add(0)
    }

    func indexOf(numFmtId: Int64): Int64 {
        for (i in 0..formats.size) {
            if (formats[i] == numFmtId) {
                return i
            }
        }
        formats.add(numFmtId)
        Int64(formats.size - 1)
    }

    func numFmtIds(): ArrayList<Int64> {
        formats
    }
}

/**
 * 把 [RowData] 映射成 `f_xml.XmlWriter` 的增量事件。
 *
 * 不拼 XML 文本、不做转义——转义由 `XmlWriter` 唯一负责；这里只保留控制字符剔除、
 * 数字格式化与 Excel 上限校验。
 */
private func xl(local: String): QName {
    QName(local, uri: Some(NS_MAIN))
}

internal class SheetXmlWriter {
    private let xml: XmlWriter
    private let styles: StyleTable
    private let date1904: Bool
    private let sheetName: String
    private let warnings: ArrayList<ExcelWarning>
    private let xmlSpace = XmlAttribute(
        QName("space", prefix: Some("xml"), uri: Some("http://www.w3.org/XML/1998/namespace")),
        "preserve"
    )

    init(
        output: OutputStream,
        styles: StyleTable,
        date1904: Bool,
        sheetName: String,
        warnings: ArrayList<ExcelWarning>
    ) {
        this.xml = XmlWriter(output)
        this.styles = styles
        this.date1904 = date1904
        this.sheetName = sheetName
        this.warnings = warnings
    }

    func begin(dimension: ?String): Unit {
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(
            QName("worksheet", uri: Some(NS_MAIN)),
            attributes: [XmlAttribute(QName("xmlns:r"), NS_REL)]
        )
        match (dimension) {
            case Some(ref) => xml.emptyElement(xl("dimension"), attributes: [XmlAttribute(QName("ref"), ref)])
            case None => ()
        }
        xml.startElement(xl("sheetData"))
    }

    func row(data: RowData): Unit {
        let attrs = ArrayList<XmlAttribute>()
        attrs.add(XmlAttribute(QName("r"), data.index.toString()))
        match (data.height) {
            case Some(h) => attrs.add(XmlAttribute(QName("ht"), formatNumber(h)))
            case None => ()
        }
        xml.startElement(xl("row"), attributes: attrs.toArray())
        for (cell in data.cells) {
            writeCell(data.index, cell)
        }
        xml.endElement(xl("row"))
    }

    func end(merges: ArrayList<String>, drawingRel!: ?String = None): Unit {
        xml.endElement(xl("sheetData"))
        if (merges.size > 0) {
            xml.startElement(xl("mergeCells"), attributes: [XmlAttribute(QName("count"), merges.size.toString())])
            for (range in merges) {
                xml.emptyElement(xl("mergeCell"), attributes: [XmlAttribute(QName("ref"), range)])
            }
            xml.endElement(xl("mergeCells"))
        }
        match (drawingRel) {
            case Some(relId) => xml.emptyElement(xl("drawing"), attributes: [XmlAttribute(QName("r:id"), relId)])
            case None => ()
        }
        xml.endElement(QName("worksheet"))
        xml.flush()
    }

    private func writeCell(rowIndex: Int64, cell: Cell): Unit {
        let ref = "${columnLetters(cell.col)}${rowIndex}"
        let attrs = ArrayList<XmlAttribute>()
        attrs.add(XmlAttribute(QName("r"), ref))
        match (cell.value) {
            case Empty => xml.emptyElement(xl("c"), attributes: attrs.toArray())
            case Text(text) =>
                let cleaned = stripControl(text)
                checkTextLength(cleaned)
                attrs.add(XmlAttribute(QName("t"), "inlineStr"))
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("is"))
                let textAttrs = if (needsPreserve(cleaned)) {
                    [xmlSpace]
                } else {
                    Array<XmlAttribute>()
                }
                xml.startElement(xl("t"), attributes: textAttrs)
                if (!cleaned.isEmpty()) {
                    xml.text(cleaned)
                }
                xml.endElement(xl("t"))
                xml.endElement(xl("is"))
                xml.endElement(xl("c"))
            case Number(value) =>
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("v"))
                xml.text(formatNumber(value))
                xml.endElement(xl("v"))
                xml.endElement(xl("c"))
            case Boolean(value) =>
                attrs.add(XmlAttribute(QName("t"), "b"))
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("v"))
                xml.text(if (value) { "1" } else { "0" })
                xml.endElement(xl("v"))
                xml.endElement(xl("c"))
            case Error(code) =>
                checkErrorCode(code)
                attrs.add(XmlAttribute(QName("t"), "e"))
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("v"))
                xml.text(code)
                xml.endElement(xl("v"))
                xml.endElement(xl("c"))
            case Formula(source, cached) =>
                checkFormulaLength(source)
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("f"))
                xml.text(source)
                xml.endElement(xl("f"))
                match (cached) {
                    case Some(value) => writeCachedValue(value)
                    case None => ()
                }
                xml.endElement(xl("c"))
            case Date(value) =>
                let numFmtId = match (cell.numberFormat) {
                    case Some(Builtin(id)) => if (id >= 14 && id <= 22 || id >= 45 && id <= 47) {
                        id
                    } else {
                        warnFormat()
                        dateStyleFor(value, date1904)
                    }
                    case Some(_) =>
                        warnFormat()
                        dateStyleFor(value, date1904)
                    case None => dateStyleFor(value, date1904)
                }
                attrs.add(XmlAttribute(QName("s"), styles.indexOf(numFmtId).toString()))
                xml.startElement(xl("c"), attributes: attrs.toArray())
                xml.startElement(xl("v"))
                xml.text(formatNumber(serialFromDateTime(value, date1904)))
                xml.endElement(xl("v"))
                xml.endElement(xl("c"))
        }
    }

    private func writeCachedValue(value: CellValue): Unit {
        match (value) {
            case Number(v) =>
                xml.startElement(xl("v"))
                xml.text(formatNumber(v))
                xml.endElement(xl("v"))
            case Text(v) =>
                xml.startElement(xl("v"))
                xml.text(v)
                xml.endElement(xl("v"))
            case Boolean(v) =>
                xml.startElement(xl("v"))
                xml.text(if (v) { "1" } else { "0" })
                xml.endElement(xl("v"))
            case Error(v) =>
                xml.startElement(xl("v"))
                xml.text(v)
                xml.endElement(xl("v"))
            case _ => ()
        }
    }

    private func warnFormat(): Unit {
        warnings.add(
            ExcelWarning(
                ExcelWarningKind.NumberFormatNotSupportedInM1,
                "M1 不支持的日期格式，按内置日期格式写出",
                sheet: Some(sheetName)
            )
        )
    }

    private func checkTextLength(value: String): Unit {
        var count: Int64 = 0
        for (_ in value.runes()) {
            count++
        }
        if (count > 32767) {
            throw ExcelException("单元格文本 ${count} 字符，超过 Excel 上限 32767")
        }
    }

    private func checkFormulaLength(value: String): Unit {
        var count: Int64 = 0
        for (_ in value.runes()) {
            count++
        }
        if (count > 8192) {
            throw ExcelException("公式 ${count} 字符，超过 Excel 上限 8192")
        }
    }

    private func checkErrorCode(code: String): Unit {
        let allowed = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]
        for (item in allowed) {
            if (item == code) {
                return
            }
        }
        throw ExcelException("非法的错误值：${code}")
    }

    private static func needsPreserve(value: String): Bool {
        let runes = ArrayList<Rune>()
        for (r in value.runes()) {
            runes.add(r)
        }
        if (runes.size == 0) {
            return false
        }
        isSpaceRune(runes[0]) || isSpaceRune(runes[runes.size - 1])
    }

    private static func isSpaceRune(r: Rune): Bool {
        r == r' ' || r == r'\t' || r == r'\n' || r == r'\r'
    }

    /** 剔除 XML 1.0 非法字符；有剔除时记一条 warning（每格最多一条）。 */
    private func stripControl(value: String): String {
        let out = StringGenerator()
        var stripped = false
        for (r in value.runes()) {
            let cp = Int64(r.position())
            let invalid = cp <= 0x08 || cp == 0x0B || cp == 0x0C || (cp >= 0x0E && cp <= 0x1F) ||
                cp == 0x7F || cp == 0xFFFE || cp == 0xFFFF
            if (invalid) {
                stripped = true
            } else {
                out.append<Rune>(r)
            }
        }
        if (stripped) {
            warnings.add(
                ExcelWarning(
                    ExcelWarningKind.ControlCharStripped,
                    "单元格文本里的非法控制字符已剔除",
                    sheet: Some(sheetName)
                )
            )
        }
        out.toString()
    }
}
