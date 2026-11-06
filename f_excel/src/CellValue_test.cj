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
public class CellValue_test {
    @TestCase
    public func stringBranches(): Unit {
        @Assert(CellValue.Empty.toString(), "")
        @Assert(CellValue.Text("hi").toString(), "hi")
        @Assert(CellValue.Boolean(true).toString(), "TRUE")
        @Assert(CellValue.Boolean(false).toString(), "FALSE")
        @Assert(CellValue.Error("#DIV/0!").toString(), "#DIV/0!")
    }

    @TestCase
    public func formulaKeepsSourceAndCache(): Unit {
        let withCache = CellValue.Formula("SUM(A1:A10)", Some(CellValue.Number(55.0)))
        @Assert(match (withCache) {
            case Formula(src, _) => src
            case _ => ""
        }, "SUM(A1:A10)")
        let noCache = CellValue.Formula("A1*2", None)
        @Assert(match (noCache) {
            case Formula(_, cached) => cached.isNone()
            case _ => false
        }, true)
    }

    @TestCase
    public func numberFormatEquality(): Unit {
        @Assert(NumberFormat.General == NumberFormat.General, true)
        @Assert(NumberFormat.Builtin(14) == NumberFormat.Builtin(14), true)
        @Assert(NumberFormat.Builtin(14) == NumberFormat.Builtin(22), false)
        @Assert(NumberFormat.Custom("0.00") == NumberFormat.Custom("0.00"), true)
        @Assert(NumberFormat.General == NumberFormat.Custom("0"), false)
        @Assert(NumberFormat.General != NumberFormat.Builtin(1), true)
    }

    @TestCase
    public func rowAndCellValueSemantics(): Unit {
        let row = RowData(5, [Cell(3, CellValue.Text("x"))], height: Some(18.0))
        @Assert(row.index, 5)
        @Assert(row.cells.size, 1)
        @Assert(row.cells[0].col, 3)
        @Assert(row.height.getOrThrow(), 18.0)
        // 值语义：改副本不影响原件
        var copy = row
        copy = RowData(6, [])
        @Assert(row.index, 5)
        @Assert(copy.index, 6)
    }

    @TestCase
    public func warningCarriesLocation(): Unit {
        let warning = ExcelWarning(
            ExcelWarningKind.NumberParseFailed,
            "不是数字",
            sheet: Some("明细"),
            ref: Some(CellRef(2, 3))
        )
        @Assert(warning.kind, ExcelWarningKind.NumberParseFailed)
        @Assert(warning.toString(), "NumberParseFailed: 不是数字 [明细!C2]")
    }

    @TestCase
    public func exceptionCatchableAsException(): Unit {
        var message = ""
        try {
            throw ExcelException("坏文件")
        } catch (e: Exception) {
            message = e.message
        }
        @Assert(message, "坏文件")
    }
}
