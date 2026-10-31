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
public class M3CellStore_test {
    @TestCase
    public func randomOrderEquivalence(): Unit {
        let store = CellStore()
        let keys: Array<Int64> = [500, 3, 900, 1, 700, 42]
        for (key in keys) {
            store.add(key, CellValue.Number(Float64(key)))
        }
        @Assert(store.size(), 6)
        for (key in keys) {
            match (store.get(key)) {
                case Some(Number(v)) => @Assert(v, Float64(key))
                case _ => @Assert(false, true)
            }
        }
        @Assert(store.get(999).isNone(), true)
        @Assert(store.remove(3), true)
        @Assert(store.get(3).isNone(), true)
        @Assert(store.remove(3), false)
    }

    @TestCase
    public func rowEntriesAreSorted(): Unit {
        let store = CellStore()
        store.add(2 * (EXCEL_MAX_COL + 1) + 5, CellValue.Text("e"))
        store.add(2 * (EXCEL_MAX_COL + 1) + 1, CellValue.Text("a"))
        store.add(2 * (EXCEL_MAX_COL + 1) + 3, CellValue.Text("c"))
        let entries = store.rowEntries(2, EXCEL_MAX_COL)
        @Assert(entries.size, 3)
        @Assert(entries[0][0], 1)
        @Assert(entries[1][0], 3)
        @Assert(entries[2][0], 5)
    }

    @TestCase
    public func worksheetSemanticsUnchanged(): Unit {
        let sheet = Worksheet("S")
        sheet.setCell("B2", CellValue.Number(2.0))
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("C3", CellValue.Text("x"))
        @Assert(match (sheet.cell("A1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 1.0)
        @Assert(sheet.rowValues(2).size, 1)
        @Assert(sheet.rowValues(2)[0][0], 2)
        sheet.setCell("B2", CellValue.Empty)
        @Assert(sheet.cell("B2").getOrThrow().toString(), "")
        sheet.clearCell("B2")
        @Assert(sheet.cell("B2").isNone(), true)
    }

    @TestCase
    public func bulkInsertKeepsOrder(): Unit {
        let sheet = Worksheet("S")
        let total: Int64 = 20_000
        var row: Int64 = 1
        while (row <= total / 10) {
            var col: Int64 = 1
            while (col <= 10) {
                sheet.setCell(row, col, CellValue.Number(Float64(row * 10 + col)))
                col++
            }
            row++
        }
        @Assert(sheet.rowCount(), total / 10)
        @Assert(sheet.colCount(), 10)
        let values = sheet.rowValues(1000)
        @Assert(values.size, 10)
        @Assert(values[0][0], 1)
        @Assert(match (values[9][1]) {
            case Number(v) => v
            case _ => -1.0
        }, 10010.0)
    }

    @TestCase
    public func registryHas350Functions(): Unit {
        let total = Int64(CORE_FUNCTION_NAMES.size) + Int64(EXTENDED_FUNCTION_NAMES.size) +
            Int64(STAT_TEXT_FUNCTION_NAMES.size) + Int64(MATH_ENG_FUNCTION_NAMES.size) +
            Int64(DYN_FIN_FUNCTION_NAMES.size) + Int64(DIST_DB_FUNCTION_NAMES.size) + 4
        @Assert(total, 350)
    }
}
