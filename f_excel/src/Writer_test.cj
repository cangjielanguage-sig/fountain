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
import std.convert.*
import std.io.ByteBuffer
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_zip.ZipReader

@Test
public class Writer_test {
    private static func writeDoc(doc: ExcelDocument): Array<Byte> {
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        buffer.bytes()
    }

    private static func textOf(bytes: Array<Byte>, name: String): String {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            String.fromUtf8(reader.read(name).getOrThrow())
        } finally {
            reader.close()
        }
    }

    private static func entryNames(bytes: Array<Byte>): Array<String> {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            let out = ArrayList<String>()
            for (entry in reader.entries()) {
                out.add(entry.name)
            }
            out.toArray()
        } finally {
            reader.close()
        }
    }

    @TestCase
    public func numberShortestRoundTrip(): Unit {
        @Assert(formatNumber(1.0), "1")
        @Assert(formatNumber(0.1), "0.1")
        @Assert(formatNumber(-2.5), "-2.5")
        @Assert(formatNumber(1e20), "1e+20")
        let third = formatNumber(1.0 / 3.0)
        @Assert(Float64.parse(third), 1.0 / 3.0)
        var thrown = false
        try {
            formatNumber(Float64.NaN)
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    @TestCase
    public func packageLayout(): Unit {
        let bytes = writeDoc(ExcelDocument())
        let names = entryNames(bytes)
        @Assert(names[0], "[Content_Types].xml")
        @Assert(names.contains("xl/workbook.xml"), true)
        @Assert(names.contains("xl/styles.xml"), true)
        @Assert(names.contains("xl/worksheets/sheet1.xml"), true)
        let types = textOf(bytes, "[Content_Types].xml")
        @Assert(types.contains("/xl/worksheets/sheet1.xml"), true)
        @Assert(types.contains("/xl/styles.xml"), true)
        let styles = textOf(bytes, "xl/styles.xml")
        @Assert(styles.contains("patternType=\"none\""), true)
        @Assert(styles.contains("patternType=\"gray125\""), true)
        @Assert(styles.contains("builtinId=\"0\""), true)
        let sheet = textOf(bytes, "xl/worksheets/sheet1.xml")
        @Assert(sheet.contains("<sheetData/>"), true)
    }

    @TestCase
    public func roundTripValues(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Text("中文😀"))
        sheet.setCell("B1", CellValue.Number(0.1))
        sheet.setCell("C1", CellValue.Boolean(true))
        sheet.setCell("D1", CellValue.Error("#DIV/0!"))
        sheet.setCell("E1", CellValue.Formula("SUM(B1:B3)", Some(CellValue.Number(55.0))))
        let bytes = writeDoc(doc)
        let reread = ExcelDocument(ByteBuffer(bytes))
        let back = reread.sheet("Sheet1").getOrThrow()
        @Assert(back.cell("A1").getOrThrow().toString(), "中文😀")
        @Assert(match (back.cell("B1").getOrThrow()) {
            case Number(v) => v
            case _ => 0.0
        }, 0.1)
        @Assert(back.cell("C1").getOrThrow().toString(), "TRUE")
        @Assert(back.cell("D1").getOrThrow().toString(), "#DIV/0!")
        @Assert(match (back.cell("E1").getOrThrow()) {
            case Formula(src, _) => src
            case _ => ""
        }, "SUM(B1:B3)")
    }

    @TestCase
    public func whitespacePreserved(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Text("  a  "))
        let bytes = writeDoc(doc)
        @Assert(textOf(bytes, "xl/worksheets/sheet1.xml").contains("xml:space=\"preserve\""), true)
        let back = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow()
        @Assert(back.cell("A1").getOrThrow().toString(), "  a  ")
    }

    @TestCase
    public func controlCharsStrippedWithWarning(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Text(String.fromUtf8([97u8, 1u8, 98u8])))
        let bytes = writeDoc(doc)
        let back = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow()
        @Assert(back.cell("A1").getOrThrow().toString(), "ab")
        @Assert(doc.warnings().size, 1)
        @Assert(doc.warnings()[0].kind, ExcelWarningKind.ControlCharStripped)
    }

    @TestCase
    public func invalidErrorCodeRejected(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Error("#FOO!"))
        var message = ""
        try {
            writeDoc(doc)
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("#FOO!"), true)
    }

    @TestCase
    public func dateWritesSerialAndStyle(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell(
            "A1",
            CellValue.Date(DateTime.ofUTC(year: 2023, month: 11, dayOfMonth: 1, hour: 0, minute: 0, second: 0, nanosecond: 0))
        )
        let bytes = writeDoc(doc)
        let sheet = textOf(bytes, "xl/worksheets/sheet1.xml")
        @Assert(sheet.contains("<v>45231</v>"), true)
        @Assert(sheet.contains(" s=\"1\""), true)
        let styles = textOf(bytes, "xl/styles.xml")
        @Assert(styles.contains("numFmtId=\"14\""), true)
    }

    @TestCase
    public func mergesAfterSheetData(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Text("top"))
        sheet.merge("A1:C1")
        let bytes = writeDoc(doc)
        let xml = textOf(bytes, "xl/worksheets/sheet1.xml")
        let mergeAt = xml.indexOf("<mergeCells") ?? -1
        let dataEnd = xml.indexOf("</sheetData>") ?? -1
        @Assert(mergeAt > dataEnd, true)
        @Assert(xml.contains("<mergeCell ref=\"A1:C1\"/>"), true)
        @Assert(!xml.contains("r=\"B1\""), true)
        let back = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow()
        @Assert(back.mergedRanges().size, 1)
    }

    @TestCase
    public func outputStreamStaysOpen(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        ExcelDocument().write(buffer)
        buffer.write("tail".toArray())
        @Assert(buffer.bytes().size > 4, true)
    }

    @TestCase
    public func multiSheetWorkbook(): Unit {
        let doc = ExcelDocument()
        doc.addSheet("二")
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Text("one"))
        doc.sheet("二").getOrThrow().setCell("A1", CellValue.Text("two"))
        let bytes = writeDoc(doc)
        let workbook = textOf(bytes, "xl/workbook.xml")
        @Assert(workbook.contains("name=\"Sheet1\""), true)
        @Assert(workbook.contains("name=\"二\""), true)
        @Assert(workbook.contains("xmlns:r="), true)
        let back = ExcelDocument(ByteBuffer(bytes))
        @Assert(back.sheetCount(), 2)
        @Assert(back.sheet("二").getOrThrow().cell("A1").getOrThrow().toString(), "two")
    }
}
