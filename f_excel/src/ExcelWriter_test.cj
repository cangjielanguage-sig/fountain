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

/** 计数迭代器：验证 `writeSheet` 把行消费完（多取一次拿到 None）。 */
internal class CountingRows <: Iterator<RowData> {
    private let items: Array<RowData>
    private var index = 0
    var pulls = 0

    init(items: Array<RowData>) {
        this.items = items
    }

    public func next(): Option<RowData> {
        pulls++
        if (index >= items.size) {
            return None<RowData>
        }
        let value = items[index]
        index++
        Some(value)
    }
}

@Test
public class ExcelWriter_test {
    private static func row(index: Int64, values: Array<CellValue>): RowData {
        let cells = ArrayList<Cell>()
        for (i in 0..values.size) {
            cells.add(Cell(i + 1, values[i]))
        }
        RowData(index, cells.toArray())
    }

    @TestCase
    public func streamingRoundTrip(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["明细"])
        let rows: Array<RowData> = [
            row(1, [CellValue.Text("名称"), CellValue.Number(1.5)]),
            row(2, [CellValue.Text("甲"), CellValue.Boolean(true)])
        ]
        writer.writeSheet("明细", rows.iterator())
        @Assert(writer.rowsWritten, 2)
        writer.finish()
        let back = ExcelDocument(ByteBuffer(buffer.bytes()))
        let sheet = back.sheet("明细").getOrThrow()
        @Assert(sheet.cell("A1").getOrThrow().toString(), "名称")
        @Assert(sheet.cell("B2").getOrThrow().toString(), "TRUE")
        @Assert(sheet.rowCount(), 2)
    }

    @TestCase
    public func wrongSheetOrderFails(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["一", "二"])
        var message = ""
        try {
            writer.writeSheet("二", ArrayList<RowData>().iterator())
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("顺序不一致"), true)
        var again = ""
        try {
            writer.writeSheet("一", ArrayList<RowData>().iterator())
        } catch (e: ExcelException) {
            again = e.message
        }
        @Assert(again.contains("已失败"), true)
    }

    @TestCase
    public func rowOrderMustIncrease(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["S"])
        let rows: Array<RowData> = [row(2, [CellValue.Number(1.0)]), row(1, [CellValue.Number(2.0)])]
        var message = ""
        try {
            writer.writeSheet("S", rows.iterator())
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("严格递增"), true)
    }

    @TestCase
    public func finishRequiresAllSheets(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["一", "二"])
        writer.writeSheet("一", ArrayList<RowData>().iterator())
        var message = ""
        try {
            writer.finish()
        } catch (e: ExcelException) {
            message = e.message
        }
        @Assert(message.contains("未写"), true)
    }

    @TestCase
    public func consumesIteratorToEnd(): Unit {
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["S"])
        let rows: Array<RowData> = [row(1, [CellValue.Number(1.0)]), row(2, [CellValue.Number(2.0)])]
        let counting = CountingRows(rows)
        writer.writeSheet("S", counting)
        writer.finish()
        @Assert(counting.pulls, 3)
    }

    @TestCase
    public func readerFeedsWriterDirectly(): Unit {
        let source = buildXlsx([
            worksheetXml("<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>x</t></is></c></row>" +
                "<row r=\"2\"><c r=\"B2\"><v>2</v></c></row>")
        ])
        let stream = ExcelSheetStream.open(ByteBuffer(source))
        let buffer = ByteBuffer(1024 * 1024)
        let writer = ExcelWriter(buffer, ["Sheet1"])
        try {
            writer.writeSheet("Sheet1", stream.rows("Sheet1").getOrThrow())
            writer.finish()
        } finally {
            stream.close()
        }
        let back = ExcelDocument(ByteBuffer(buffer.bytes()))
        @Assert(back.sheet("Sheet1").getOrThrow().cell("A1").getOrThrow().toString(), "x")
        @Assert(match (back.sheet("Sheet1").getOrThrow().cell("B2").getOrThrow()) {
            case Number(v) => v
            case _ => 0.0
        }, 2.0)
    }

    @TestCase
    public func constructorValidation(): Unit {
        let buffer = ByteBuffer(1024)
        var empty = false
        try {
            ExcelWriter(buffer, Array<String>())
        } catch (_: ExcelException) {
            empty = true
        }
        @Assert(empty, true)
        var duplicate = false
        try {
            ExcelWriter(buffer, ["A", "A"])
        } catch (_: ExcelException) {
            duplicate = true
        }
        @Assert(duplicate, true)
        var badName = false
        try {
            ExcelWriter(buffer, ["a/b"])
        } catch (_: ExcelException) {
            badName = true
        }
        @Assert(badName, true)
    }
}
