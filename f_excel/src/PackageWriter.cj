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

private let NS_XDR: String = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
private let NS_A: String = "http://schemas.openxmlformats.org/drawingml/2006/main"

private func xdr(local: String): QName {
    QName(local, prefix: Some("xdr"), uri: Some(NS_XDR))
}

private func a(local: String): QName {
    QName(local, prefix: Some("a"), uri: Some(NS_A))
}

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
        var drawingIndex: Int64 = 0
        var mediaIndex: Int64 = 0
        let sheetDrawing = ArrayList<Int64>()
        let sheetMedia = ArrayList<ArrayList<String>>()
        let usedFormats = ArrayList<ImageFormat>()
        for (sheet in sheets) {
            let images = sheet.sheetImages()
            let media = ArrayList<String>()
            if (images.size > 0) {
                drawingIndex++
                sheetDrawing.add(drawingIndex)
                for (image in images) {
                    mediaIndex++
                    media.add("image${mediaIndex}.${image.format.extension()}")
                    usedFormats.add(image.format)
                }
            } else {
                sheetDrawing.add(0)
            }
            sheetMedia.add(media)
        }
        let zip = ZipWriter(output)
        let styles = StylePool()
        zip.add("[Content_Types].xml", contentTypes(count, sheetDrawing: sheetDrawing, formats: usedFormats))
        zip.add("_rels/.rels", rootRels())
        let names = ArrayList<String>()
        for (sheet in sheets) {
            names.add(sheet.name)
        }
        zip.add("xl/workbook.xml", workbookXmlFromNames(names.toArray(), date1904))
        zip.add("xl/_rels/workbook.xml.rels", workbookRels(count))
        for (i in 0..sheets.size) {
            let images = sheets[i].sheetImages()
            var drawingRel: ?String = None
            if (images.size > 0) {
                let drawing = sheetDrawing[i]
                drawingRel = Some("rId1")
                let media = sheetMedia[i]
                for (j in 0..images.size) {
                    zip.add("xl/media/${media[j]}", images[j].data)
                }
                zip.add("xl/drawings/drawing${drawing}.xml", drawingXml(images))
                zip.add("xl/drawings/_rels/drawing${drawing}.xml.rels", drawingRels(media))
                zip.add("xl/worksheets/_rels/sheet${i + 1}.xml.rels", sheetRels(drawing))
            }
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
                    cells.add(Cell(pair[0], pair[1], style: sheets[i].styleOf(rowIndex, pair[0])))
                }
                writer.row(RowData(rowIndex, cells.toArray()))
            }
            writer.end(sheets[i].mergedRanges(), drawingRel: drawingRel)
            entry.close()
        }
        zip.add("xl/styles.xml", StylesWriter.write(styles))
        zip.close()
    }

    private static func newWriter(buffer: ByteBuffer): XmlWriter {
        XmlWriter(buffer)
    }

    internal static func contentTypes(
        sheetCount: Int64,
        sheetDrawing!: ArrayList<Int64> = ArrayList<Int64>(),
        formats!: ArrayList<ImageFormat> = ArrayList<ImageFormat>()
    ): Array<Byte> {
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
        var hasPng = false
        var hasJpeg = false
        for (format in formats) {
            match (format) {
                case Png => hasPng = true
                case Jpeg => hasJpeg = true
            }
        }
        if (hasPng) {
            xml.emptyElement(
                ct("Default"),
                attributes: [XmlAttribute(QName("Extension"), "png"), XmlAttribute(QName("ContentType"), "image/png")]
            )
        }
        if (hasJpeg) {
            xml.emptyElement(
                ct("Default"),
                attributes: [XmlAttribute(QName("Extension"), "jpeg"), XmlAttribute(QName("ContentType"), "image/jpeg")]
            )
        }
        for (drawing in sheetDrawing) {
            if (drawing > 0) {
                xml.emptyElement(
                    ct("Override"),
                    attributes: [
                        XmlAttribute(QName("PartName"), "/xl/drawings/drawing${drawing}.xml"),
                        XmlAttribute(
                            QName("ContentType"),
                            "application/vnd.openxmlformats-officedocument.drawing+xml"
                        )
                    ]
                )
            }
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

    private static func drawingXml(images: ArrayList<SheetImage>): Array<Byte> {
        let buffer = ByteBuffer(256 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(xdr("wsDr"), attributes: [XmlAttribute(QName("xmlns:r"), NS_REL)])
        for (i in 0..images.size) {
            let image = images[i]
            xml.startElement(xdr("twoCellAnchor"), attributes: [XmlAttribute(QName("editAs"), "oneCell")])
            writeAnchor(xml, "from", image.from)
            writeAnchor(xml, "to", image.to)
            xml.startElement(xdr("pic"))
            xml.startElement(xdr("nvPicPr"))
            xml.emptyElement(
                xdr("cNvPr"),
                attributes: [XmlAttribute(QName("id"), "${i + 1}"), XmlAttribute(QName("name"), "Picture ${i + 1}")]
            )
            xml.startElement(xdr("cNvPicPr"))
            xml.emptyElement(a("picLocks"), attributes: [XmlAttribute(QName("noChangeAspect"), "1")])
            xml.endElement(xdr("cNvPicPr"))
            xml.endElement(xdr("nvPicPr"))
            xml.startElement(xdr("blipFill"))
            xml.emptyElement(a("blip"), attributes: [XmlAttribute(QName("r:embed"), "rId${i + 1}")])
            xml.startElement(a("stretch"))
            xml.emptyElement(a("fillRect"))
            xml.endElement(a("stretch"))
            xml.endElement(xdr("blipFill"))
            xml.startElement(xdr("spPr"))
            xml.startElement(a("xfrm"))
            xml.emptyElement(a("off"), attributes: [XmlAttribute(QName("x"), "0"), XmlAttribute(QName("y"), "0")])
            xml.emptyElement(a("ext"), attributes: [XmlAttribute(QName("cx"), "0"), XmlAttribute(QName("cy"), "0")])
            xml.endElement(a("xfrm"))
            xml.startElement(a("prstGeom"), attributes: [XmlAttribute(QName("prst"), "rect")])
            xml.emptyElement(a("avLst"))
            xml.endElement(a("prstGeom"))
            xml.endElement(xdr("spPr"))
            xml.endElement(xdr("pic"))
            xml.emptyElement(xdr("clientData"))
            xml.endElement(xdr("twoCellAnchor"))
        }
        xml.endElement(xdr("wsDr"))
        xml.flush()
        buffer.bytes()
    }

    private static func writeAnchor(xml: XmlWriter, tag: String, ref: CellRef): Unit {
        xml.startElement(xdr(tag))
        xml.startElement(xdr("col"))
        xml.text((ref.col - 1).toString())
        xml.endElement(xdr("col"))
        xml.startElement(xdr("colOff"))
        xml.text("0")
        xml.endElement(xdr("colOff"))
        xml.startElement(xdr("row"))
        xml.text((ref.row - 1).toString())
        xml.endElement(xdr("row"))
        xml.startElement(xdr("rowOff"))
        xml.text("0")
        xml.endElement(xdr("rowOff"))
        xml.endElement(xdr(tag))
    }

    private static func drawingRels(media: ArrayList<String>): Array<Byte> {
        let buffer = ByteBuffer(64 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("Relationships", uri: Some(NS_PKG_REL)))
        for (i in 0..media.size) {
            xml.emptyElement(
                rel("Relationship"),
                attributes: [
                    XmlAttribute(QName("Id"), "rId${i + 1}"),
                    XmlAttribute(QName("Type"), "${NS_REL}/image"),
                    XmlAttribute(QName("Target"), "../media/${media[i]}")
                ]
            )
        }
        xml.endElement(QName("Relationships"))
        xml.flush()
        buffer.bytes()
    }

    private static func sheetRels(drawing: Int64): Array<Byte> {
        let buffer = ByteBuffer(64 * 1024)
        let xml = newWriter(buffer)
        xml.writeDeclaration(encoding: "UTF-8", standalone: Some(true))
        xml.startElement(QName("Relationships", uri: Some(NS_PKG_REL)))
        xml.emptyElement(
            rel("Relationship"),
            attributes: [
                XmlAttribute(QName("Id"), "rId1"),
                XmlAttribute(QName("Type"), "${NS_REL}/drawing"),
                XmlAttribute(QName("Target"), "../drawings/drawing${drawing}.xml")
            ]
        )
        xml.endElement(QName("Relationships"))
        xml.flush()
        buffer.bytes()
    }

}
