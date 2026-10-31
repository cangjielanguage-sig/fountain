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
public class CellRef_test {
    /** 场景「列号 ↔ 字母边界」。 */
    @TestCase
    public func columnMappingBoundaries(): Unit {
        let cases: Array<(String, Int64)> = [
            ("A", 1), ("Z", 26), ("AA", 27), ("AZ", 52), ("BA", 53), ("ZZ", 702),
            ("AAA", 703), ("XFD", 16384)
        ]
        for (item in cases) {
            @Assert(columnIndex(item[0]).getOrThrow(), item[1])
            @Assert(columnLetters(item[1]), item[0])
        }
    }

    @TestCase
    public func columnIndexRejectsBadInput(): Unit {
        @Assert(columnIndex("1").isNone(), true)
        @Assert(columnIndex("").isNone(), true)
        @Assert(columnIndex("A1").isNone(), true)
        @Assert(columnIndex("XFE").isNone(), true)
        @Assert(columnIndex("a").getOrThrow(), 1)
    }

    @TestCase
    public func columnLettersRejectsOutOfRange(): Unit {
        var thrown = false
        try {
            columnLetters(0)
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
        thrown = false
        try {
            columnLetters(16385)
        } catch (_: ExcelException) {
            thrown = true
        }
        @Assert(thrown, true)
    }

    /** 场景「parse 全表」。 */
    @TestCase
    public func parseTable(): Unit {
        let a1 = CellRef.parse("A1").getOrThrow()
        @Assert(a1.row, 1)
        @Assert(a1.col, 1)
        @Assert(a1.rowAbs, false)
        @Assert(a1.colAbs, false)

        let lower = CellRef.parse("a1").getOrThrow()
        @Assert(lower.row, 1)
        @Assert(lower.col, 1)

        let abs = CellRef.parse(#"$A$1"#).getOrThrow()
        @Assert(abs.rowAbs, true)
        @Assert(abs.colAbs, true)

        let colAbs = CellRef.parse(#"$A1"#).getOrThrow()
        @Assert(colAbs.colAbs, true)
        @Assert(colAbs.rowAbs, false)

        let rowAbs = CellRef.parse(#"A$1"#).getOrThrow()
        @Assert(rowAbs.colAbs, false)
        @Assert(rowAbs.rowAbs, true)

        let leadingZero = CellRef.parse("A01").getOrThrow()
        @Assert(leadingZero.row, 1)

        for (bad in ["A", "1", "A1B", "XFE1", "A1048577", "A0", ""]) {
            @Assert(CellRef.parse(bad).isNone(), true)
        }
    }

    @TestCase
    public func parseRangeTable(): Unit {
        let (from, to) = CellRef.parseRange("A1:B2").getOrThrow()
        @Assert(from.row, 1)
        @Assert(from.col, 1)
        @Assert(to.row, 2)
        @Assert(to.col, 2)

        let (singleFrom, singleTo) = CellRef.parseRange("c3").getOrThrow()
        @Assert(singleFrom.row, 3)
        @Assert(singleTo.col, 3)

        for (bad in ["B2:A1", "A1:B2:C3", "A1:", ":B2", ""]) {
            @Assert(CellRef.parseRange(bad).isNone(), true)
        }
    }

    @TestCase
    public func formatting(): Unit {
        @Assert(CellRef(1, 1).toString(), "A1")
        @Assert(CellRef(1048576, 16384).toString(), "XFD1048576")
        @Assert(CellRef(1, 1, rowAbs: true, colAbs: true).toA1(), #"$A$1"#)
        @Assert(CellRef.parse(#"A$1"#).getOrThrow().toA1(), #"A$1"#)
        @Assert(CellRef.parse(#"A$1"#).getOrThrow().toString(), "A1")
    }

    @TestCase
    public func equalityAndOrdering(): Unit {
        @Assert(CellRef.parse("A1").getOrThrow() == CellRef.parse("a1").getOrThrow(), true)
        @Assert(CellRef.parse(#"$A$1"#).getOrThrow() == CellRef.parse("A1").getOrThrow(), true)
        @Assert(CellRef.parse("B1").getOrThrow() < CellRef.parse("A2").getOrThrow(), true)
        @Assert(CellRef.parse("A1").getOrThrow() < CellRef.parse("A1").getOrThrow(), false)
    }
}
