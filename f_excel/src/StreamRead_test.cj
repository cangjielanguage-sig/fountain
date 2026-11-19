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
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class StreamRead_test {
    private static func bytes(rows: String): Array<Byte> {
        buildXlsx([worksheetXml(rows)])
    }

    @TestCase
    public func readsRowsAndNames(): Unit {
        let data = bytes(
            "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"B1\" t=\"inlineStr\"><is><t>x</t></is></c></row>" +
                "<row r=\"3\"><c r=\"C3\"><v>3</v></c></row>"
        )
        let stream = ExcelSheetStream.open(ByteBuffer(data))
        try {
            @Assert(stream.sheetNames(), ["Sheet1"])
            let reader = stream.rows("Sheet1").getOrThrow()
            let first = reader.next().getOrThrow()
            @Assert(first.index, 1)
            @Assert(first.cells.size, 2)
            let second = reader.next().getOrThrow()
            @Assert(second.index, 3)
            @Assert(second.cells[0].col, 3)
            @Assert(reader.next().isNone(), true)
            @Assert(reader.next().isNone(), true)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func missingSheetReturnsNone(): Unit {
        let stream = ExcelSheetStream.open(ByteBuffer(bytes("")))
        try {
            @Assert(stream.rows("不存在").isNone(), true)
            @Assert(stream.rowsAt(5).isNone(), true)
            @Assert(stream.rowsAt(-1).isNone(), true)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func channelParityWithDocument(): Unit {
        let rows =
            "<row r=\"1\"><c r=\"A1\"><v>42</v></c></row>" +
                "<row r=\"2\"><c r=\"B2\" t=\"inlineStr\"><is><t>文本</t></is></c></row>"
        let data = bytes(rows)
        let doc = ExcelDocument(ByteBuffer(data))
        let stream = ExcelSheetStream.open(ByteBuffer(data))
        try {
            let reader = stream.rows("Sheet1").getOrThrow()
            let sheet = doc.sheet("Sheet1").getOrThrow()
            var index: Int64 = 1
            while (let Some(row) <- reader.next()) {
                for (cell in row.cells) {
                    let fromDoc = sheet.cell(row.index, cell.col).getOrThrow()
                    @Assert(cell.value.toString(), fromDoc.toString())
                }
                index++
            }
            @Assert(index, 3)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func mergedRangesTiming(): Unit {
        let xml =
            "<?xml version=\"1.0\"?><worksheet xmlns=\"${NS_MAIN}\"><sheetData>" +
                "<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>" +
                "</sheetData><mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells></worksheet>"
        let stream = ExcelSheetStream.open(ByteBuffer(buildXlsx([xml])))
        try {
            let reader = stream.rows("Sheet1").getOrThrow()
            @Assert(reader.mergedRanges().size, 0)
            while (let Some(_) <- reader.next()) {}
            @Assert(reader.mergedRanges().size, 1)
            @Assert(reader.mergedRanges()[0], "A1:B1")
            @Assert(stream.warnings().size > 0, true)
            @Assert(stream.warnings()[0].kind, ExcelWarningKind.MergedRangesUnavailable)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func closeSemantics(): Unit {
        let stream = ExcelSheetStream.open(ByteBuffer(bytes("<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>")))
        let reader = stream.rows("Sheet1").getOrThrow()
        reader.close()
        reader.close()
        var thrown = false
        try {
            reader.next()
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
        stream.close()
        stream.close()
        thrown = false
        try {
            stream.rows("Sheet1")
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    @TestCase
    public func spoolDisabledWarning(): Unit {
        let options = ExcelStreamReadOptions()
        options.spool = false
        let stream = ExcelSheetStream.open(
            ByteBuffer(bytes("<row r=\"1\"><c r=\"A1\"><v>1</v></c></row>")),
            options: options
        )
        try {
            @Assert(stream.warnings()[0].kind, ExcelWarningKind.SpoolDisabled)
            let reader = stream.rows("Sheet1").getOrThrow()
            @Assert(reader.next().getOrThrow().index, 1)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func rowOrderViolationKeepsOrder(): Unit {
        let stream = ExcelSheetStream.open(
            ByteBuffer(
                bytes(
                    "<row r=\"9\"><c r=\"A9\"><v>9</v></c></row>" +
                        "<row r=\"3\"><c r=\"A3\"><v>3</v></c></row>"
                )
            )
        )
        try {
            let reader = stream.rows("Sheet1").getOrThrow()
            @Assert(reader.next().getOrThrow().index, 9)
            @Assert(reader.next().getOrThrow().index, 3)
            @Assert(reader.next().isNone(), true)
            var found = false
            for (warning in stream.warnings()) {
                if (warning.kind == ExcelWarningKind.RowOrderViolation) {
                    found = true
                }
            }
            @Assert(found, true)
        } finally {
            stream.close()
        }
    }

    @TestCase
    public func earlyCloseAllowsReopen(): Unit {
        let stream = ExcelSheetStream.open(
            ByteBuffer(bytes("<row r=\"1\"><c r=\"A1\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\"><v>2</v></c></row>"))
        )
        try {
            let first = stream.rows("Sheet1").getOrThrow()
            @Assert(first.next().getOrThrow().index, 1)
            first.close()
            let second = stream.rows("Sheet1").getOrThrow()
            @Assert(second.next().getOrThrow().index, 1)
        } finally {
            stream.close()
        }
    }
}
