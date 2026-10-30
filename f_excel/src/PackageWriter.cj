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
import std.io.{ByteBuffer, OutputStream}
import fountain::f_xml.{QName, XmlAttribute, XmlWriter}
import fountain::f_zip.ZipWriter

private func ct(local: String): QName {
    QName(local, uri: Some(NS_CONTENT_TYPES))
}

private func rel(local: String): QName {
    QName(local, uri: Some(NS_PKG_REL))
}

private func xl(local: String): QName {
    QName(local, uri: Some(NS_MAIN))
}

/** OPC 包生成：内容类型、rels、workbook、worksheet、styles。 */
internal class PackageWriter {
    static func write(
        output: OutputStream,
        sheets: ArrayList<Worksheet>,
        date1904: Bool,
        warnings: ArrayList<ExcelWarning>
    ): Unit {
        let count = Int64(sheets.size)
        let zip = ZipWriter(output)
        let styles = StyleTable()
        zip.add("[Content_Types].xml", contentTypes(count))
        zip.add("_rels/.rels", rootRels())
        let names = ArrayList<String>()
        for (sheet in sheets) {
            names.add(sheet.name)
        }
        zip.add("xl/workbook.xml", workbookXmlFromNames(names.toArray(), date1904))
        zip.add("xl/_rels/workbook.xml.rels", workbookRels(count))
        for (i in 0..sheets.size) {
            let entry = zip.openEntry("xl/worksheets/sheet${i + 1}.xml")
            let writer = SheetXmlWriter(entry, styles, date1904, sheets[i].name, warnings)
            writer.begin(sheets[i].dimension())
            for (rowIndex in 1..=sheets[i].rowCount()) {
                let values = sheets[i].rowValues(rowIndex)
                if (values.size == 0) {
                    continue
                }
                let cells = ArrayList<Cell>()
                for (pair in values) {
                    cells.add(Cell(pair[0], pair[1]))
                }
                writer.row(RowData(rowIndex, cells.toArray()))
            }
            writer.end(sheets[i].mergedRanges())
            entry.close()
        }
        zip.add("xl/styles.xml", stylesXml(styles))
        zip.close()
    }

    private static func newWriter(buffer: ByteBuffer): XmlWriter {
        XmlWriter(buffer)
    }

    internal static func contentTypes(sheetCount: Int64): Array<Byte> {
        let buffer = ByteBuffer(256 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("Types", uri: Some(NS_CONTENT_TYPES)))
        xml.emptyElement(
            ct("Default"),
            attributes: [
                XmlAttribute(QName("Extension"), "rels"),
                XmlAttribute(
                    QName("ContentType"),
                    "application/vnd.openxmlformats-package.relationships+xml"
                )
            ]
        )
        xml.emptyElement(
            ct("Default"),
            attributes: [XmlAttribute(QName("Extension"), "xml"), XmlAttribute(QName("ContentType"), "application/xml")]
        )
        xml.emptyElement(
            ct("Override"),
            attributes: [
                XmlAttribute(QName("PartName"), "/xl/workbook.xml"),
                XmlAttribute(
                    QName("ContentType"),
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
                )
            ]
        )
        for (i in 1..=sheetCount) {
            xml.emptyElement(
                ct("Override"),
                attributes: [
                    XmlAttribute(QName("PartName"), "/xl/worksheets/sheet${i}.xml"),
                    XmlAttribute(
                        QName("ContentType"),
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
                    )
                ]
            )
        }
        xml.emptyElement(
            ct("Override"),
            attributes: [
                XmlAttribute(QName("PartName"), "/xl/styles.xml"),
                XmlAttribute(
                    QName("ContentType"),
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
                )
            ]
        )
        xml.endElement(QName("Types"))
        xml.flush()
        buffer.bytes()
    }

    internal static func rootRels(): Array<Byte> {
        let buffer = ByteBuffer(64 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("Relationships", uri: Some(NS_PKG_REL)))
        xml.emptyElement(
            rel("Relationship"),
            attributes: [
                XmlAttribute(QName("Id"), "rId1"),
                XmlAttribute(QName("Type"), "${NS_REL}/officeDocument"),
                XmlAttribute(QName("Target"), "xl/workbook.xml")
            ]
        )
        xml.endElement(QName("Relationships"))
        xml.flush()
        buffer.bytes()
    }

    internal static func workbookXmlFromNames(sheets: Array<String>, date1904: Bool): Array<Byte> {
        let buffer = ByteBuffer(128 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(
            QName("workbook", uri: Some(NS_MAIN)),
            attributes: [XmlAttribute(QName("xmlns:r"), NS_REL)]
        )
        if (date1904) {
            xml.emptyElement(xl("workbookPr"), attributes: [XmlAttribute(QName("date1904"), "1")])
        }
        xml.startElement(xl("sheets"))
        for (i in 0..sheets.size) {
            xml.emptyElement(
                xl("sheet"),
                attributes: [
                    XmlAttribute(QName("name"), sheets[i]),
                    XmlAttribute(QName("sheetId"), "${i + 1}"),
                    XmlAttribute(QName("r:id"), "rId${i + 1}")
                ]
            )
        }
        xml.endElement(xl("sheets"))
        xml.endElement(QName("workbook"))
        xml.flush()
        buffer.bytes()
    }

    internal static func workbookRels(sheetCount: Int64): Array<Byte> {
        let buffer = ByteBuffer(128 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("Relationships", uri: Some(NS_PKG_REL)))
        for (i in 1..=sheetCount) {
            xml.emptyElement(
                rel("Relationship"),
                attributes: [
                    XmlAttribute(QName("Id"), "rId${i}"),
                    XmlAttribute(QName("Type"), "${NS_REL}/worksheet"),
                    XmlAttribute(QName("Target"), "worksheets/sheet${i}.xml")
                ]
            )
        }
        xml.emptyElement(
            rel("Relationship"),
            attributes: [
                XmlAttribute(QName("Id"), "rId${sheetCount + 1}"),
                XmlAttribute(QName("Type"), "${NS_REL}/styles"),
                XmlAttribute(QName("Target"), "styles.xml")
            ]
        )
        xml.endElement(QName("Relationships"))
        xml.flush()
        buffer.bytes()
    }

    internal static func stylesXml(styles: StyleTable): Array<Byte> {
        let buffer = ByteBuffer(128 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("styleSheet", uri: Some(NS_MAIN)))
        xml.startElement(xl("fonts"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.startElement(xl("font"))
        xml.emptyElement(xl("sz"), attributes: [XmlAttribute(QName("val"), "11")])
        xml.endElement(xl("font"))
        xml.endElement(xl("fonts"))
        xml.startElement(xl("fills"), attributes: [XmlAttribute(QName("count"), "2")])
        xml.startElement(xl("fill"))
        xml.emptyElement(xl("patternFill"), attributes: [XmlAttribute(QName("patternType"), "none")])
        xml.endElement(xl("fill"))
        xml.startElement(xl("fill"))
        xml.emptyElement(xl("patternFill"), attributes: [XmlAttribute(QName("patternType"), "gray125")])
        xml.endElement(xl("fill"))
        xml.endElement(xl("fills"))
        xml.startElement(xl("borders"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.startElement(xl("border"))
        xml.emptyElement(xl("left"))
        xml.emptyElement(xl("right"))
        xml.emptyElement(xl("top"))
        xml.emptyElement(xl("bottom"))
        xml.emptyElement(xl("diagonal"))
        xml.endElement(xl("border"))
        xml.endElement(xl("borders"))
        xml.startElement(xl("cellStyleXfs"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.emptyElement(
            xl("xf"),
            attributes: [
                XmlAttribute(QName("numFmtId"), "0"),
                XmlAttribute(QName("fontId"), "0"),
                XmlAttribute(QName("fillId"), "0"),
                XmlAttribute(QName("borderId"), "0")
            ]
        )
        xml.endElement(xl("cellStyleXfs"))
        let formats = styles.numFmtIds()
        xml.startElement(xl("cellXfs"), attributes: [XmlAttribute(QName("count"), formats.size.toString())])
        for (numFmtId in formats) {
            let attrs = ArrayList<XmlAttribute>()
            attrs.add(XmlAttribute(QName("numFmtId"), numFmtId.toString()))
            attrs.add(XmlAttribute(QName("fontId"), "0"))
            attrs.add(XmlAttribute(QName("fillId"), "0"))
            attrs.add(XmlAttribute(QName("borderId"), "0"))
            attrs.add(XmlAttribute(QName("xfId"), "0"))
            if (numFmtId != 0) {
                attrs.add(XmlAttribute(QName("applyNumberFormat"), "1"))
            }
            xml.emptyElement(xl("xf"), attributes: attrs.toArray())
        }
        xml.endElement(xl("cellXfs"))
        xml.startElement(xl("cellStyles"), attributes: [XmlAttribute(QName("count"), "1")])
        xml.emptyElement(
            xl("cellStyle"),
            attributes: [
                XmlAttribute(QName("name"), "Normal"),
                XmlAttribute(QName("xfId"), "0"),
                XmlAttribute(QName("builtinId"), "0")
            ]
        )
        xml.endElement(xl("cellStyles"))
        xml.endElement(QName("styleSheet"))
        xml.flush()
        buffer.bytes()
    }
}
