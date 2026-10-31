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
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class M2d_test {
    @TestCase
    public func elapsedFormatReadsAsTimeSpan(): Unit {
        let sheetXml = worksheetXml(
            "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>4.5</v></c></row>"
        )
        let styles = stylesXml([0, 46])
        let doc = ExcelDocument(ByteBuffer(buildXlsx([sheetXml], parts: [("xl/styles.xml", styles)])))
        let sheet = doc.sheet("Sheet1").getOrThrow()
        match (sheet.cell("A1").getOrThrow()) {
            case TimeSpan(value) => @Assert(value.toSeconds(), 388800)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func timeSpanRoundTrips(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.TimeSpan(Duration.minute * 90))
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let back = ExcelDocument(ByteBuffer(buffer.bytes())).sheet("Sheet1").getOrThrow()
        match (back.cell("A1").getOrThrow()) {
            case TimeSpan(value) => @Assert(value.toSeconds(), 5400)
            case _ => @Assert(false, true)
        }
        match (back.styleOf(1, 1)) {
            case Some(style) => match (style.numberFormat) {
                case Custom(code) => @Assert(code.contains("[h]"), true)
                case _ => @Assert(false, true)
            }
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func largeHourTimeSpan(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.TimeSpan(Duration.hour * 100))
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let back = ExcelDocument(ByteBuffer(buffer.bytes())).sheet("Sheet1").getOrThrow()
        match (back.cell("A1").getOrThrow()) {
            case TimeSpan(value) => @Assert(value.toSeconds(), 360000)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func richTextRunsAreParsed(): Unit {
        let sharedStrings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<sst xmlns=\"${NS_MAIN}\" count=\"1\" uniqueCount=\"1\">" +
            "<si><r><rPr><b/><sz val=\"14\"/><color rgb=\"FFFF0000\"/><rFont val=\"Arial\"/></rPr><t>粗</t></r>" +
            "<r><t>细</t></r></si></sst>"
        let sheetXml = worksheetXml("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>")
        let doc = ExcelDocument(
            ByteBuffer(
                buildXlsx([sheetXml], parts: [("xl/sharedStrings.xml", sharedStrings)])
            )
        )
        let sheet = doc.sheet("Sheet1").getOrThrow()
        match (sheet.cell("A1").getOrThrow()) {
            case Text(value) => @Assert(value, "粗细")
            case _ => @Assert(false, true)
        }
        let rich = sheet.richText(1, 1).getOrThrow()
        @Assert(rich.runs.size, 2)
        @Assert(rich.text(), "粗细")
        @Assert(rich.runs[0].font.isSome(), true)
        let font = rich.runs[0].font.getOrThrow()
        @Assert(font.bold, true)
        @Assert(font.size.getOrThrow(), 14.0)
        @Assert(font.color.getOrThrow(), "FFFF0000")
        @Assert(font.name.getOrThrow(), "Arial")
        @Assert(rich.runs[1].font.isNone(), true)
    }

    @TestCase
    public func plainSharedStringHasNoRichText(): Unit {
        let sharedStrings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<sst xmlns=\"${NS_MAIN}\" count=\"1\" uniqueCount=\"1\"><si><t>abc</t></si></sst>"
        let sheetXml = worksheetXml("<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>")
        let doc = ExcelDocument(
            ByteBuffer(
                buildXlsx([sheetXml], parts: [("xl/sharedStrings.xml", sharedStrings)])
            )
        )
        let sheet = doc.sheet("Sheet1").getOrThrow()
        @Assert(sheet.richText(1, 1).isNone(), true)
        match (sheet.cell("A1").getOrThrow()) {
            case Text(value) => @Assert(value, "abc")
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func richTextFlattensOnWrite(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        let runs = ArrayList<TextRun>()
        runs.add(
            TextRun("粗", font: Some(RunFont(bold: true)))
        )
        runs.add(TextRun("细"))
        sheet.setRichText(1, 1, RichText(runs))
        sheet.setCell("A1", CellValue.Text("粗细"))
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let back = ExcelDocument(ByteBuffer(buffer.bytes())).sheet("Sheet1").getOrThrow()
        match (back.cell("A1").getOrThrow()) {
            case Text(value) => @Assert(value, "粗细")
            case _ => @Assert(false, true)
        }
        @Assert(back.richText(1, 1).isNone(), true)
    }
}
