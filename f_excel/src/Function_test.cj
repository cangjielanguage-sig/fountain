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
public class Function_test {
    private static func setup(): (ExcelDocument, CalcEngine) {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Number(1.0))
        sheet.setCell("A2", CellValue.Number(2.0))
        sheet.setCell("A3", CellValue.Number(3.0))
        sheet.setCell("A4", CellValue.Text("x"))
        sheet.setCell("A5", CellValue.Empty)
        sheet.setCell("B1", CellValue.Number(10.0))
        sheet.setCell("B2", CellValue.Number(20.0))
        sheet.setCell("B3", CellValue.Number(30.0))
        (doc, CalcEngine(doc))
    }

    private static func calc(doc: ExcelDocument, engine: CalcEngine, formula: String): CalcValue {
        doc.sheet("Sheet1").getOrThrow().setCell("Y1", CellValue.Formula(formula, None))
        engine.evaluate("Sheet1", "Y1")
    }

    private static func number(doc: ExcelDocument, engine: CalcEngine, formula: String): Float64 {
        match (calc(doc, engine, formula)) {
            case Number(v) => v
            case _ => -999999.0
        }
    }

    private static func text(doc: ExcelDocument, engine: CalcEngine, formula: String): String {
        calcToText(calc(doc, engine, formula))
    }

    private static func truth(doc: ExcelDocument, engine: CalcEngine, formula: String): Bool {
        match (calc(doc, engine, formula)) {
            case Boolean(v) => v
            case _ => false
        }
    }

    @TestCase
    public func mathFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=SUM(A1:A3)"), 6.0)
        @Assert(number(doc, engine, "=SUM(A1:A3,B1:B3)"), 66.0)
        @Assert(number(doc, engine, "=PRODUCT(A1:A3)"), 6.0)
        @Assert(number(doc, engine, "=ABS(-2)"), 2.0)
        @Assert(number(doc, engine, "=SIGN(-3)"), -1.0)
        @Assert(number(doc, engine, "=SQRT(9)"), 3.0)
        @Assert(number(doc, engine, "=INT(2.9)"), 2.0)
        @Assert(number(doc, engine, "=INT(-2.1)"), -3.0)
        @Assert(number(doc, engine, "=ROUND(2.345,2)"), 2.35)
        @Assert(number(doc, engine, "=ROUND(-2.345,2)"), -2.35)
        @Assert(number(doc, engine, "=ROUNDUP(2.341,2)"), 2.35)
        @Assert(number(doc, engine, "=ROUNDDOWN(2.349,2)"), 2.34)
        @Assert(number(doc, engine, "=TRUNC(2.9)"), 2.0)
        @Assert(number(doc, engine, "=MOD(7,3)"), 1.0)
        @Assert(number(doc, engine, "=MOD(-7,3)"), 2.0)
        @Assert(number(doc, engine, "=POWER(2,10)"), 1024.0)
        match (calc(doc, engine, "=SQRT(-1)")) {
            case Error(e) => @Assert(e, CalcError.Num)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func conditionalAggregates(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=SUMIF(A1:A3,\">1\")"), 5.0)
        @Assert(number(doc, engine, "=SUMIF(A1:A3,\">1\",B1:B3)"), 50.0)
        @Assert(number(doc, engine, "=SUMIFS(B1:B3,A1:A3,\">1\")"), 50.0)
        @Assert(number(doc, engine, "=AVERAGEIF(A1:A3,\">1\")"), 2.5)
    }

    @TestCase
    public func statisticsFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=AVERAGE(A1:A3)"), 2.0)
        @Assert(number(doc, engine, "=COUNT(A1:A3)"), 3.0)
        @Assert(number(doc, engine, "=COUNTA(A1:A4)"), 4.0)
        @Assert(number(doc, engine, "=COUNTBLANK(A1:A5)"), 1.0)
        @Assert(number(doc, engine, "=COUNTIF(A1:A3,\">1\")"), 2.0)
        @Assert(number(doc, engine, "=COUNTIFS(A1:A3,\">1\",B1:B3,\">25\")"), 1.0)
        @Assert(number(doc, engine, "=MIN(A1:A3)"), 1.0)
        @Assert(number(doc, engine, "=MAX(A1:B3)"), 30.0)
        @Assert(number(doc, engine, "=MEDIAN(A1:A3)"), 2.0)
        @Assert(number(doc, engine, "=MEDIAN(A1:B1)"), 5.5)
    }

    @TestCase
    public func logicalFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(text(doc, engine, "=IF(TRUE,\"y\",\"n\")"), "y")
        @Assert(number(doc, engine, "=IFS(FALSE,1,TRUE,2)"), 2.0)
        @Assert(truth(doc, engine, "=AND(TRUE,1,1=1)"), true)
        @Assert(truth(doc, engine, "=OR(FALSE,0)"), false)
        @Assert(truth(doc, engine, "=NOT(TRUE)"), false)
        @Assert(truth(doc, engine, "=XOR(TRUE,FALSE)"), true)
        @Assert(text(doc, engine, "=IFERROR(1/0,\"e\")"), "e")
        @Assert(text(doc, engine, "=IFNA(#N/A,\"n\")"), "n")
        @Assert(text(doc, engine, "=IFNA(1,\"n\")"), "1")
        @Assert(text(doc, engine, "=SWITCH(2,1,\"a\",2,\"b\",\"z\")"), "b")
        @Assert(text(doc, engine, "=SWITCH(9,1,\"a\",2,\"b\",\"z\")"), "z")
    }

    @TestCase
    public func textFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(text(doc, engine, "=CONCATENATE(\"a\",1)"), "a1")
        @Assert(text(doc, engine, "=CONCAT(\"x\",TRUE)"), "xTRUE")
        @Assert(number(doc, engine, "=LEN(\"中文\")"), 2.0)
        @Assert(text(doc, engine, "=LEFT(\"abc\",2)"), "ab")
        @Assert(text(doc, engine, "=RIGHT(\"abc\",2)"), "bc")
        @Assert(text(doc, engine, "=MID(\"abcdef\",2,3)"), "bcd")
        @Assert(text(doc, engine, "=TRIM(\"  a  b  \")"), "a b")
        @Assert(text(doc, engine, "=UPPER(\"ab\")"), "AB")
        @Assert(text(doc, engine, "=LOWER(\"AB\")"), "ab")
        @Assert(text(doc, engine, "=TEXT(1234.5,\"#,##0.00\")"), "1,234.50")
        @Assert(text(doc, engine, "=TEXT(0.5,\"0%\")"), "50%")
        @Assert(number(doc, engine, "=VALUE(\"1,234\")"), 1234.0)
    }

    @TestCase
    public func dateFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=YEAR(DATE(2024,2,29))"), 2024.0)
        @Assert(number(doc, engine, "=MONTH(DATE(2024,2,29))"), 2.0)
        @Assert(number(doc, engine, "=DAY(DATE(2024,2,29))"), 29.0)
        @Assert(number(doc, engine, "=YEAR(DATE(2024,13,1))"), 2025.0)
        @Assert(number(doc, engine, "=HOUR(0.5)"), 12.0)
        @Assert(number(doc, engine, "=MINUTE(0.5)"), 0.0)
        @Assert(number(doc, engine, "=SECOND(0.5)"), 0.0)
        @Assert(number(doc, engine, "=TODAY()") > 40000.0, true)
        @Assert(number(doc, engine, "=NOW()") > 40000.0, true)
    }

    @TestCase
    public func lookupFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=VLOOKUP(2,A1:B3,2,FALSE)"), 20.0)
        @Assert(number(doc, engine, "=VLOOKUP(2.5,A1:B3,2,TRUE)"), 20.0)
        match (calc(doc, engine, "=VLOOKUP(99,A1:B3,2,FALSE)")) {
            case Error(e) => @Assert(e, CalcError.NotAvailable)
            case _ => @Assert(false, true)
        }
        @Assert(number(doc, engine, "=INDEX(A1:B3,2,2)"), 20.0)
        @Assert(number(doc, engine, "=MATCH(2,A1:A3,0)"), 2.0)
        @Assert(number(doc, engine, "=MATCH(2.5,A1:A3,1)"), 2.0)
    }

    @TestCase
    public func infoFunctions(): Unit {
        let (doc, engine) = setup()
        @Assert(truth(doc, engine, "=ISBLANK(A5)"), true)
        @Assert(truth(doc, engine, "=ISBLANK(A1)"), false)
        @Assert(truth(doc, engine, "=ISERROR(1/0)"), true)
        @Assert(truth(doc, engine, "=ISNUMBER(1)"), true)
        @Assert(truth(doc, engine, "=ISTEXT(\"a\")"), true)
        @Assert(truth(doc, engine, "=ISLOGICAL(TRUE)"), true)
        @Assert(truth(doc, engine, "=ISNA(#N/A)"), true)
        @Assert(truth(doc, engine, "=ISNA(1)"), false)
    }

    @TestCase
    public func registryCoversCoreList(): Unit {
        var missing = 0
        for (name in CORE_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(CORE_FUNCTION_NAMES.size), 62)
        @Assert(lookupFunction("sum").isSome(), true)
        @Assert(lookupFunction("NO_SUCH_FN").isNone(), true)
    }
}
