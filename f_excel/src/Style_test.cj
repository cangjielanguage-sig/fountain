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
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_zip.ZipReader

@Test
public class Style_test {
    private static func textOf(bytes: Array<Byte>, name: String): String {
        let reader = ZipReader(ByteBuffer(bytes))
        try {
            String.fromUtf8(reader.read(name).getOrThrow())
        } finally {
            reader.close()
        }
    }

    @TestCase
    public func valueSemantics(): Unit {
        let base = CellStyle()
        let bold = base.withFont(Font(bold: true))
        @Assert(base.font.bold, false)
        @Assert(bold.font.bold, true)
        @Assert(base.withFill(Fill.solid(Color.Rgb("FFFF0000"))).fill.patternType.toString(), "solid")
    }

    @TestCase
    public func fullStyleRoundTrip(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        let style = CellStyle(
            numberFormat: NumberFormat.Builtin(4),
            font: Font(name: "Arial", size: 14.0, bold: true, italic: true,
                underline: Underline.Single, color: Color.Theme(4, 0.4)),
            fill: Fill.solid(Color.Rgb("FFFFFF00")),
            border: Border(
                left: BorderSide(style: BorderStyle.Thin, color: Color.Rgb("FF000000")),
                bottom: BorderSide(style: BorderStyle.Double)
            ),
            alignment: Alignment(horizontal: Horizontal.Center, vertical: Vertical.Center, wrapText: true)
        )
        sheet.setCell("A1", CellValue.Number(1234.5))
        sheet.setStyle(1, 1, style)
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let bytes = buffer.bytes()
        let stylesXml = textOf(bytes, "xl/styles.xml")
        @Assert(stylesXml.contains("numFmtId=\"4\""), true)
        @Assert(stylesXml.contains("rgb=\"FFFFFF00\""), true)
        @Assert(stylesXml.contains("theme=\"4\""), true)
        @Assert(stylesXml.contains("style=\"thin\""), true)
        @Assert(stylesXml.contains("horizontal=\"center\""), true)

        let back = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow()
        let read = back.styleOf(1, 1).getOrThrow()
        @Assert(read.font.name.getOrThrow(), "Arial")
        @Assert(read.font.size, 14.0)
        @Assert(read.font.bold, true)
        @Assert(read.font.italic, true)
        @Assert(read.font.underline.toString(), "single")
        @Assert(read.fill.patternType.toString(), "solid")
        @Assert(read.border.left.style.toString(), "thin")
        @Assert(read.border.bottom.style.toString(), "double")
        @Assert(read.alignment.horizontal.toString(), "center")
        @Assert(read.alignment.wrapText, true)
        @Assert(match (read.numberFormat) {
            case Builtin(id) => id
            case _ => -1
        }, 4)
        @Assert(read.font.color.isSome(), true)
    }

    @TestCase
    public func customNumberFormatRoundTrip(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.23456))
        sheet.setStyle(1, 1, CellStyle(numberFormat: NumberFormat.Custom("0.000")))
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let bytes = buffer.bytes()
        let stylesXml = textOf(bytes, "xl/styles.xml")
        @Assert(stylesXml.contains("formatCode=\"0.000\""), true)
        let read = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow().styleOf(1, 1).getOrThrow()
        @Assert(match (read.numberFormat) {
            case Custom(code) => code
            case _ => ""
        }, "0.000")
    }

    @TestCase
    public func styleDedup(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        let style = CellStyle(font: Font(bold: true))
        for (i in 1..=200) {
            sheet.setCell(i, 1, CellValue.Number(Float64(i)))
            sheet.setStyle(i, 1, style)
        }
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let stylesXml = textOf(buffer.bytes(), "xl/styles.xml")
        // 默认样式 + 粗体 = 2 条 cellXfs
        @Assert(stylesXml.contains("<cellXfs count=\"2\">"), true)
        // 字体也只有默认 + 粗体
        @Assert(stylesXml.contains("<fonts count=\"2\">"), true)
    }

    @TestCase
    public func stylePoolLimit(): Unit {
        let pool = StylePool()
        pool.getOrAdd(CellStyle(font: Font(bold: true)), 2)
        var message = ""
        try {
            pool.getOrAdd(CellStyle(font: Font(italic: true)), 2)
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("maxCellStyles"), true)
    }

    @TestCase
    public func dateAutoStyleStillWorks(): Unit {
        let doc = ExcelDocument()
        doc.sheet("Sheet1").getOrThrow().setCell(
            "A1",
            CellValue.Date(DateTime.ofUTC(year: 2024, month: 1, dayOfMonth: 1, hour: 0, minute: 0, second: 0, nanosecond: 0))
        )
        let buffer = ByteBuffer(4 * 1024 * 1024)
        doc.write(buffer)
        let bytes = buffer.bytes()
        let stylesXml = textOf(bytes, "xl/styles.xml")
        @Assert(stylesXml.contains("numFmtId=\"14\""), true)
        let back = ExcelDocument(ByteBuffer(bytes)).sheet("Sheet1").getOrThrow()
        @Assert(match (back.cell("A1").getOrThrow()) {
            case Date(_) => true
            case _ => false
        }, true)
    }
}
