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
public class M3Spill_test {
    @TestCase
    public func sequenceSpillsIntoNeighbors(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Formula("SEQUENCE(2,2)", None))
        let report = CalcEngine(doc).recalculate(writeBack: true)
        @Assert(report.errors, 0)
        @Assert(match (sheet.cell("B1").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 2.0)
        @Assert(match (sheet.cell("A2").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 3.0)
        @Assert(match (sheet.cell("B2").getOrThrow()) {
            case Number(v) => v
            case _ => -1.0
        }, 4.0)
    }

    @TestCase
    public func occupiedTargetBecomesSpillError(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Formula("SEQUENCE(2,2)", None))
        sheet.setCell("B2", CellValue.Text("occupied"))
        let report = CalcEngine(doc).recalculate(writeBack: true)
        @Assert(report.errors, 1)
        match (sheet.cell("A1").getOrThrow()) {
            case Formula(_, Some(Error(code))) => @Assert(code, "#SPILL!")
            case _ => @Assert(false, true)
        }
        @Assert(sheet.cell("B2").getOrThrow().toString(), "occupied")
    }
}
