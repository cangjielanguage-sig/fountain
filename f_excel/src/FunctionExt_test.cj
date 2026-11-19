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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class FunctionExt_test {
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
        sheet.setCell("E1", CellValue.Number(1.0))
        sheet.setCell("F1", CellValue.Number(2.0))
        sheet.setCell("G1", CellValue.Number(3.0))
        sheet.setCell("E2", CellValue.Number(10.0))
        sheet.setCell("F2", CellValue.Number(20.0))
        sheet.setCell("G2", CellValue.Number(30.0))
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

    private static func text(doc: ExcelDocument, engine: CalcEngine, formula: String): String {
        calcToText(calc(doc, engine, formula))
    }

    private static func truth(doc: ExcelDocument, engine: CalcEngine, formula: String): Bool {
        match (calc(doc, engine, formula)) {
            case Boolean(v) => v
            case _ => false
        }
    }

    private static func near(a: Float64, b: Float64): Bool {
        abs(a - b) < 1e-9
    }

    @TestCase
    public func statisticsExtended(): Unit {
        let (doc, engine) = setup()
        @Assert(near(number(doc, engine, "=STDEV.S(A1:A3)"), 1.0), true)
        @Assert(near(number(doc, engine, "=STDEV.P(A1:A3)"), 0.816496580927726), true)
        @Assert(near(number(doc, engine, "=VAR.S(A1:A3)"), 1.0), true)
        @Assert(near(number(doc, engine, "=VAR.P(A1:A3)"), 0.6666666666666666), true)
        @Assert(number(doc, engine, "=LARGE(A1:A3,1)"), 3.0)
        @Assert(number(doc, engine, "=SMALL(A1:A3,1)"), 1.0)
        @Assert(number(doc, engine, "=RANK(2,A1:A3,0)"), 2.0)
        @Assert(number(doc, engine, "=RANK(2,A1:A3,1)"), 2.0)
        @Assert(number(doc, engine, "=PERCENTILE(A1:A3,0.5)"), 2.0)
        @Assert(number(doc, engine, "=QUARTILE(A1:A3,2)"), 2.0)
        @Assert(near(number(doc, engine, "=CORREL(A1:A3,B1:B3)"), 1.0), true)
        @Assert(near(number(doc, engine, "=SLOPE(A1:A3,B1:B3)"), 0.1), true)
        @Assert(near(number(doc, engine, "=INTERCEPT(A1:A3,B1:B3)"), 0.0), true)
        @Assert(near(number(doc, engine, "=FORECAST(4,B1:B3,A1:A3)"), 40.0), true)
        match (calc(doc, engine, "=MODE(A1:A3)")) {
            case Error(e) => @Assert(e, CalcError.NotAvailable)
            case _ => @Assert(false, true)
        }
        @Assert(number(doc, engine, "=MODE(C1:C2)"), 5.0)
    }

    @TestCase
    public func lookupExtended(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=HLOOKUP(2,E1:G2,2,FALSE)"), 20.0)
        @Assert(number(doc, engine, "=LOOKUP(2,A1:A3,B1:B3)"), 20.0)
        @Assert(number(doc, engine, "=XLOOKUP(2,A1:A3,B1:B3)"), 20.0)
        @Assert(text(doc, engine, "=XLOOKUP(99,A1:A3,B1:B3,\"none\")"), "none")
        @Assert(text(doc, engine, "=CHOOSE(2,\"a\",\"b\")"), "b")
        @Assert(number(doc, engine, "=OFFSET(A1,1,0)"), 2.0)
        @Assert(number(doc, engine, "=SUM(OFFSET(A1,0,0,3,1))"), 6.0)
        @Assert(number(doc, engine, "=INDIRECT(\"A2\")"), 2.0)
        @Assert(number(doc, engine, "=SUM(INDIRECT(\"A1:A3\"))"), 6.0)
        @Assert(number(doc, engine, "=ROW(A5)"), 5.0)
        @Assert(number(doc, engine, "=COLUMN(C1)"), 3.0)
        @Assert(number(doc, engine, "=ROWS(A1:B3)"), 3.0)
        @Assert(number(doc, engine, "=COLUMNS(A1:B3)"), 2.0)
        @Assert(number(doc, engine, "=INDEX(TRANSPOSE(A1:A3),1,2)"), 2.0)
        @Assert(number(doc, engine, "=INDEX(TRANSPOSE(A1:B1),2,1)"), 10.0)
    }

    @TestCase
    public func textExtended(): Unit {
        let (doc, engine) = setup()
        @Assert(text(doc, engine, "=SUBSTITUTE(\"a-b-c\",\"-\",\"+\")"), "a+b+c")
        @Assert(text(doc, engine, "=SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)"), "a-b+c")
        @Assert(text(doc, engine, "=REPLACE(\"abcdef\",2,3,\"X\")"), "aXef")
        @Assert(number(doc, engine, "=FIND(\"b\",\"abc\")"), 2.0)
        @Assert(number(doc, engine, "=SEARCH(\"B\",\"abc\")"), 2.0)
        match (calc(doc, engine, "=FIND(\"B\",\"abc\")")) {
            case Error(e) => @Assert(e, CalcError.Value)
            case _ => @Assert(false, true)
        }
        @Assert(text(doc, engine, "=REPT(\"ab\",3)"), "ababab")
        @Assert(text(doc, engine, "=TEXTJOIN(\"-\",TRUE,\"a\",\"\",\"b\")"), "a-b")
        @Assert(truth(doc, engine, "=EXACT(\"a\",\"A\")"), false)
        @Assert(text(doc, engine, "=PROPER(\"hello world\")"), "Hello World")
        @Assert(text(doc, engine, "=CLEAN(\"a\"&UNICHAR(1)&\"b\")"), "ab")
        @Assert(text(doc, engine, "=CHAR(65)"), "A")
        @Assert(number(doc, engine, "=CODE(\"A\")"), 65.0)
        @Assert(text(doc, engine, "=UNICHAR(20013)"), "中")
        @Assert(number(doc, engine, "=UNICODE(\"中\")"), 20013.0)
        @Assert(text(doc, engine, "=T(\"x\")"), "x")
        @Assert(text(doc, engine, "=T(1)"), "")
    }

    @TestCase
    public func mathExtended(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=SUMPRODUCT(A1:A3,B1:B3)"), 140.0)
        @Assert(number(doc, engine, "=CEILING(2.1,1)"), 3.0)
        @Assert(number(doc, engine, "=FLOOR(2.9,1)"), 2.0)
        @Assert(number(doc, engine, "=MROUND(10,3)"), 9.0)
        @Assert(near(number(doc, engine, "=LOG(8,2)"), 3.0), true)
        @Assert(near(number(doc, engine, "=LOG10(100)"), 2.0), true)
        @Assert(near(number(doc, engine, "=LN(EXP(1))"), 1.0), true)
        @Assert(near(number(doc, engine, "=EXP(0)"), 1.0), true)
        @Assert(near(number(doc, engine, "=PI()"), 3.141592653589793), true)
        @Assert(near(number(doc, engine, "=SIN(0)"), 0.0), true)
        @Assert(near(number(doc, engine, "=COS(0)"), 1.0), true)
        @Assert(near(number(doc, engine, "=TAN(0)"), 0.0), true)
        @Assert(near(number(doc, engine, "=DEGREES(PI())"), 180.0), true)
        @Assert(near(number(doc, engine, "=RADIANS(180)"), 3.141592653589793), true)
        @Assert(number(doc, engine, "=GCD(12,18)"), 6.0)
        @Assert(number(doc, engine, "=LCM(4,6)"), 12.0)
        @Assert(number(doc, engine, "=FACT(5)"), 120.0)
        @Assert(number(doc, engine, "=RANDBETWEEN(1,1)"), 1.0)
        let random = number(doc, engine, "=RAND()")
        @Assert(random >= 0.0 && random < 1.0, true)
    }

    @TestCase
    public func dateExtended(): Unit {
        let (doc, engine) = setup()
        @Assert(number(doc, engine, "=DATEVALUE(\"2024-02-29\")"), number(doc, engine, "=DATE(2024,2,29)"))
        @Assert(number(doc, engine, "=TIMEVALUE(\"12:00:00\")"), 0.5)
        @Assert(number(doc, engine, "=EDATE(DATE(2024,1,31),1)"), number(doc, engine, "=DATE(2024,2,29)"))
        @Assert(number(doc, engine, "=EOMONTH(DATE(2024,1,15),0)"), number(doc, engine, "=DATE(2024,1,31)"))
        @Assert(number(doc, engine, "=WEEKDAY(DATE(2024,1,1))"), 2.0)
        @Assert(number(doc, engine, "=WEEKDAY(DATE(2024,1,1),2)"), 1.0)
        @Assert(number(doc, engine, "=WEEKNUM(DATE(2024,1,1))"), 1.0)
        @Assert(number(doc, engine, "=DATEDIF(DATE(2024,1,1),DATE(2025,3,15),\"Y\")"), 1.0)
        @Assert(number(doc, engine, "=DATEDIF(DATE(2024,1,1),DATE(2025,3,15),\"M\")"), 14.0)
        @Assert(number(doc, engine, "=DATEDIF(DATE(2024,1,1),DATE(2024,1,31),\"D\")"), 30.0)
        @Assert(number(doc, engine, "=DAYS(DATE(2024,1,31),DATE(2024,1,1))"), 30.0)
        @Assert(number(doc, engine, "=DAYS360(DATE(2024,1,1),DATE(2024,12,31))"), 359.0)
        @Assert(number(doc, engine, "=NETWORKDAYS(DATE(2024,1,1),DATE(2024,1,7))"), 5.0)
        @Assert(number(doc, engine, "=WORKDAY(DATE(2024,1,1),5)"), number(doc, engine, "=DATE(2024,1,8)"))
    }

    @TestCase
    public func financialAndInfo(): Unit {
        let (doc, engine) = setup()
        @Assert(near(number(doc, engine, "=PMT(0.1,2,100)"), -57.61904761904762), true)
        @Assert(near(number(doc, engine, "=IPMT(0.1,1,2,100)"), -10.0), true)
        @Assert(near(number(doc, engine, "=PPMT(0.1,1,2,100)"), -47.61904761904762), true)
        @Assert(near(number(doc, engine, "=PV(0.1,2,-57.61904761904762)"), 100.0), true)
        @Assert(near(number(doc, engine, "=FV(0.1,2,-57.61904761904762,100)"), 0.0), true)
        @Assert(near(number(doc, engine, "=NPER(0.1,-57.61904761904762,100)"), 2.0), true)
        @Assert(number(doc, engine, "=SLN(100,10,3)"), 30.0)
        @Assert(near(number(doc, engine, "=NPV(0.1,100)"), 90.9090909090909), true)
        @Assert(truth(doc, engine, "=ISERR(1/0)"), true)
        @Assert(truth(doc, engine, "=ISERR(#N/A)"), false)
        match (calc(doc, engine, "=NA()")) {
            case Error(e) => @Assert(e, CalcError.NotAvailable)
            case _ => @Assert(false, true)
        }
        @Assert(number(doc, engine, "=TYPE(1)"), 1.0)
        @Assert(number(doc, engine, "=TYPE(\"a\")"), 2.0)
        @Assert(number(doc, engine, "=TYPE(TRUE)"), 4.0)
        @Assert(number(doc, engine, "=TYPE(1/0)"), 16.0)
        @Assert(number(doc, engine, "=ERROR.TYPE(1/0)"), 2.0)
        @Assert(number(doc, engine, "=ERROR.TYPE(#N/A)"), 7.0)
    }

    @TestCase
    public func registryCoversExtendedList(): Unit {
        var missing = 0
        for (name in EXTENDED_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(EXTENDED_FUNCTION_NAMES.size), 81)
        @Assert(Int64(CORE_FUNCTION_NAMES.size) + Int64(EXTENDED_FUNCTION_NAMES.size), 143)
    }
}
