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
import std.io.ByteBuffer
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_xml.{XmlElement, XmlParser}
import fountain::f_zip.ZipReader

@Test
public class RoundTrip_test {
    private static func bytes(doc: ExcelDocument, options!: ExcelWriteOptions = ExcelWriteOptions()): Array<Byte> {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer, options: options)
        buffer.bytes()
    }

    @TestCase
    public func sevenValueTypes(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Empty)
        sheet.setCell("B1", CellValue.Number(1.25))
        sheet.setCell("C1", CellValue.Text("文本"))
        sheet.setCell("D1", CellValue.Boolean(false))
        sheet.setCell("E1", CellValue.Error("#N/A"))
        sheet.setCell("F1", CellValue.Formula("A1+B1", Some(CellValue.Number(2.25))))
        sheet.setCell(
            "G1",
            CellValue.Date(DateTime.ofUTC(year: 2024, month: 2, dayOfMonth: 29, hour: 0, minute: 0, second: 0, nanosecond: 0))
        )
        let back = ExcelDocument(ByteBuffer(bytes(doc))).sheet("Sheet1").getOrThrow()
        @Assert(match (back.cell("A1").getOrThrow()) {
            case Empty => true
            case _ => false
        }, true)
        @Assert(match (back.cell("B1").getOrThrow()) {
            case Number(v) => v
            case _ => 0.0
        }, 1.25)
        @Assert(back.cell("C1").getOrThrow().toString(), "文本")
        @Assert(back.cell("D1").getOrThrow().toString(), "FALSE")
        @Assert(back.cell("E1").getOrThrow().toString(), "#N/A")
        @Assert(match (back.cell("F1").getOrThrow()) {
            case Formula(src, cached) => "${src}|${cached.getOrThrow().toString()}"
            case _ => "?"
        }, "A1+B1|2.250000")
        @Assert(match (back.cell("G1").getOrThrow()) {
            case Date(dt) => "${dt.year}-${dt.month.toInteger()}-${dt.dayOfMonth}"
            case _ => "not-date"
        }, "2024-2-29")
    }

    @TestCase
    public func textEdgeCases(): Unit {
        let samples = ["  a  ", "a&<b>\"c\"", "a\r\nb", "中文😀", ""]
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        for (i in 0..samples.size) {
            sheet.setCell("A${i + 1}", CellValue.Text(samples[i]))
        }
        let back = ExcelDocument(ByteBuffer(bytes(doc))).sheet("Sheet1").getOrThrow()
        for (i in 0..samples.size) {
            @Assert(back.cell("A${i + 1}").getOrThrow().toString(), samples[i])
        }
    }

    @TestCase
    public func numericPrecision(): Unit {
        let samples = [0.1, 1.0 / 3.0, 1e-10, -2.5, 1e20]
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        for (i in 0..samples.size) {
            sheet.setCell("A${i + 1}", CellValue.Number(samples[i]))
        }
        let back = ExcelDocument(ByteBuffer(bytes(doc))).sheet("Sheet1").getOrThrow()
        for (i in 0..samples.size) {
            let value = match (back.cell("A${i + 1}").getOrThrow()) {
                case Number(v) => v
                case _ => 0.0
            }
            @Assert(value, samples[i])
        }
    }

    @TestCase
    public func date1904RoundTrip(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell(
            "A1",
            CellValue.Date(DateTime.ofUTC(year: 2024, month: 1, dayOfMonth: 2, hour: 0, minute: 0, second: 0, nanosecond: 0))
        )
        let options = ExcelWriteOptions()
        options.date1904 = Some(true)
        let back = ExcelDocument(ByteBuffer(bytes(doc, options: options)))
        @Assert(back.date1904, true)
        @Assert(match (back.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow()) {
            case Date(dt) => "${dt.year}-${dt.month.toInteger()}-${dt.dayOfMonth}"
            case _ => "not-date"
        }, "2024-1-2")
    }

    @TestCase
    public func twoSheetsAndMerges(): Unit {
        let doc = ExcelDocument()
        doc.addSheet("二")
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Text("x"))
        doc.sheet("Sheet1").getOrThrow().merge("A1:B1")
        doc.sheet("二").getOrThrow().setCell("A1", CellValue.Text("y"))
        doc.sheet("二").getOrThrow().merge("A1:A3")
        let back = ExcelDocument(ByteBuffer(bytes(doc)))
        @Assert(back.sheetCount(), 2)
        @Assert(back.sheet("Sheet1").getOrThrow().mergedRanges()[0], "A1:B1")
        @Assert(back.sheet("二").getOrThrow().mergedRanges()[0], "A1:A3")
    }
}

@Test
public class PackageStructure_test {
    private static func parse(bytes: Array<Byte>, name: String): XmlElement {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let data = reader.read(name).getOrThrow()
            XmlParser.parse(data).root.getOrThrow()
        } finally {
            reader.close()
        }
    }

    @TestCase
    public func requiredPartsAndParseable(): Unit {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        let doc = ExcelDocument()
        doc.write(buffer)
        let bytes = buffer.bytes()
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let names = ArrayList<String>()
            for (entry in reader.entries()) {
                names.add(entry.name)
            }
            for (required in [
                "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml"
            ]) {
                @Assert(names.contains(required), true)
            }
        } finally {
            reader.close()
        }
        for (part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml"]) {
            let root = parse(bytes, part)
            @Assert(!root.name.local.isEmpty(), true)
        }
    }

    @TestCase
    public func relsHaveNoDanglingIds(): Unit {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        let doc = ExcelDocument()
        doc.addSheet("二")
        doc.write(buffer)
        let bytes = buffer.bytes()
        let workbook = parse(bytes, "xl/workbook.xml")
        let rels = parse(bytes, "xl/_rels/workbook.xml.rels")
        let ids = ArrayList<String>()
        for (rel in rels.childrenOf("Relationship")) {
            ids.add(rel.attr("Id") ?? "")
        }
        let sheets = workbook.child("sheets").getOrThrow()
        for (sheet in sheets.childrenOf("sheet")) {
            let rid = sheet.attr(NS_REL, "id") ?? ""
            @Assert(ids.contains(rid), true)
            @Assert(sheet.attr("name").isSome(), true)
        }
    }

    @TestCase
    public func stylesTableIsConsistent(): Unit {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell(
            "A1",
            CellValue.Date(DateTime.ofUTC(year: 2024, month: 1, dayOfMonth: 1, hour: 0, minute: 0, second: 0, nanosecond: 0))
        )
        doc.write(buffer)
        let styles = parse(buffer.bytes(), "xl/styles.xml")
        let fills = styles.child("fills").getOrThrow()
        @Assert(fills.childrenOf("fill")[0].child("patternFill").getOrThrow().attr("patternType").getOrThrow(), "none")
        @Assert(fills.childrenOf("fill")[1].child("patternFill").getOrThrow().attr("patternType").getOrThrow(), "gray125")
        let xfs = styles.child("cellXfs").getOrThrow().childrenOf("xf")
        @Assert(xfs.size >= 2, true)
        @Assert(xfs[0].attr("numFmtId").getOrThrow(), "0")
        @Assert(xfs[1].attr("numFmtId").getOrThrow(), "14")
    }
}
