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

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Worksheet_test {
    @TestCase
    public func threeAccessFormsAgree(): Unit {
        let sheet = Worksheet("S")
        sheet.setCell(2, 3, CellValue.Text("x"))
        @Assert(sheet.cell(2, 3).getOrThrow().toString(), "x")
        @Assert(sheet.cell("C2").getOrThrow().toString(), "x")
        @Assert(sheet.cell(CellRef(2, 3)).getOrThrow().toString(), "x")
        sheet.setCell("D4", CellValue.Number(4.0))
        @Assert(sheet.cell(4, 4).getOrThrow().toString(), "4.000000")
        sheet.setCell(CellRef(5, 5), CellValue.Boolean(true))
        @Assert(sheet.cell("E5").getOrThrow().toString(), "TRUE")
    }

    @TestCase
    public func outOfRangeAndMissing(): Unit {
        let sheet = Worksheet("S")
        @Assert(sheet.cell(0, 1).isNone(), true)
        @Assert(sheet.cell(1, 0).isNone(), true)
        @Assert(sheet.cell(EXCEL_MAX_ROW + 1, 1).isNone(), true)
        @Assert(sheet.cell(1, 1).isNone(), true)
        var thrown = false
        try {
            sheet.setCell(0, 1, CellValue.Empty)
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(sheet.cell("A0").isNone(), true)
    }

    @TestCase
    public func countsAndRowValues(): Unit {
        let sheet = Worksheet("S")
        sheet.setCell("C5", CellValue.Text("c"))
        sheet.setCell("A5", CellValue.Text("a"))
        @Assert(sheet.rowCount(), 5)
        @Assert(sheet.colCount(), 3)
        let values = sheet.rowValues(5)
        @Assert(values.size, 2)
        @Assert(values[0][0], 1)
        @Assert(values[1][0], 3)
        @Assert(sheet.rowValues(6).size, 0)
    }

    @TestCase
    public func clearAndRange(): Unit {
        let sheet = Worksheet("S")
        sheet.setCell("A1", CellValue.Text("a"))
        sheet.setCell("B2", CellValue.Text("b"))
        sheet.clearCell("A1")
        @Assert(sheet.cell("A1").isNone(), true)
        let block = sheet.range("A1", "B2")
        @Assert(block.size, 2)
        @Assert(block[0].size, 2)
        @Assert(block[0][0].toString(), "")
        @Assert(block[1][1].toString(), "b")
    }

    @TestCase
    public func mergeAndMergedValue(): Unit {
        let sheet = Worksheet("S")
        sheet.setCell("A1", CellValue.Text("top"))
        sheet.merge("A1:C2")
        @Assert(sheet.mergedRanges().size, 1)
        @Assert(sheet.mergedRangeAt(2, 3).getOrThrow(), "A1:C2")
        @Assert(sheet.mergedValue(2, 3).getOrThrow().toString(), "top")
        @Assert(sheet.mergedValue(5, 5).isNone(), true)
        var thrown = false
        try {
            sheet.merge("B2:D3")
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
        @Assert(sheet.unmerge("A1:C2"), true)
        @Assert(sheet.unmerge("A1:C2"), false)
    }
}
