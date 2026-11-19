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
public class Array_test {
    private static func setup(): (ExcelDocument, CalcEngine) {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("A2", CellValue.Number(2.0))
        sheet.setCell("A3", CellValue.Number(3.0))
        sheet.setCell("B1", CellValue.Number(10.0))
        sheet.setCell("B2", CellValue.Number(20.0))
        sheet.setCell("B3", CellValue.Number(30.0))
        sheet.setCell("C1", CellValue.Number(5.0))
        sheet.setCell("C2", CellValue.Number(5.0))
        (doc, CalcEngine(doc))
    }

    private static func calc(doc: ExcelDocument, engine: CalcEngine, formula: String): CalcValue {
        doc.sheet("Sheet1").getOrThrow().setCell("Y1", CellValue.Formula(formula, None))
        engine.evaluate("Sheet1", "Y1")
    }

    private static func number(doc: ExcelDocument, engine: CalcEngine, formula: String): Float64 {
        match (calcToNumber(scalarize(calc(doc, engine, formula)))) {
            case Some(v) => v
            case None => -999999.0
        }
    }

    @TestCase
    public func arrayArithmeticBroadcasts(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=SUM(A1:A3*B1:B3)"), 140.0)
        @Assert(number(doc, engine, "=SUM({1,2;3,4}*2)"), 20.0)
        @Assert(number(doc, engine, "=SUM(A1:A3+1)"), 9.0)
        match (calc(doc, engine, "=SUM({1,2}*{1,2,3})")) {
            case Error(e) => @Assert(e, CalcError.Value)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func filterSelectsRows(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=SUM(FILTER(A1:A3,B1:B3>15))"), 5.0)
        @Assert(calcToText(calc(doc, engine, "=FILTER(A1:A3,B1:B3>100,\"none\")")), "none")
        match (calc(doc, engine, "=SUM(FILTER(A1:A3,B1:B3>100))")) {
            case Error(e) => @Assert(e, CalcError.Calc)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func sortAndUnique(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=INDEX(SORT(A1:A3,1,-1),1,1)"), 3.0)
        @Assert(number(doc, engine, "=INDEX(SORT(A1:A3),1,1)"), 1.0)
        @Assert(number(doc, engine, "=SUM(UNIQUE(C1:C2))"), 5.0)
        @Assert(number(doc, engine, "=SUM(SEQUENCE(3,1,1,1))"), 6.0)
        @Assert(number(doc, engine, "=INDEX(SEQUENCE(2,3),2,3)"), 6.0)
    }
}
