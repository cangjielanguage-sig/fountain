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
public class M3DistDb_test {
    private static func calc(formula: String): CalcValue {
        let doc = ExcelDocument()
        let engine = CalcEngine(doc)
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Formula(formula, None))
        engine.evaluate("Sheet1", "A1")
    }

    private static func close(value: CalcValue, expected: Float64, tolerance!: Float64 = 1e-6): Bool {
        match (value) {
            case Number(v) => abs(v - expected) < tolerance
            case _ => false
        }
    }

    @TestCase
    public func distributions(): Unit {
        @Assert(close(calc("=NORM.S.DIST(0,TRUE)"), 0.5), true)
        @Assert(close(calc("=NORM.DIST(0,0,1,TRUE)"), 0.5), true)
        @Assert(close(calc("=NORM.S.INV(0.5)"), 0.0), true)
        @Assert(close(calc("=NORM.INV(0.5,10,2)"), 10.0), true)
        @Assert(close(calc("=LOGNORM.DIST(1,0,1,TRUE)"), 0.5), true)
        @Assert(close(calc("=LOGNORM.INV(0.5,0,1)"), 1.0), true)
        @Assert(close(calc("=EXPON.DIST(1,1,TRUE)"), 0.6321205588285577), true)
        @Assert(close(calc("=POISSON.DIST(0,2,FALSE)"), 0.1353352832366127), true)
        @Assert(close(calc("=BINOM.DIST(1,2,0.5,FALSE)"), 0.5), true)
        @Assert(close(calc("=BINOM.DIST(1,2,0.5,TRUE)"), 0.75), true)
        @Assert(close(calc("=BINOM.INV(2,0.5,0.75)"), 1.0), true)
        @Assert(close(calc("=NEGBINOM.DIST(1,1,0.5,FALSE)"), 0.25), true)
        @Assert(close(calc("=HYPGEOM.DIST(1,2,3,10,FALSE)"), 0.4666666666666667), true)
        @Assert(close(calc("=WEIBULL.DIST(1,1,1,TRUE)"), 0.6321205588285577), true)
        @Assert(close(calc("=GAMMA(5)"), 24.0), true)
        @Assert(close(calc("=GAMMALN(5)"), 3.1780538303479453), true)
        @Assert(close(calc("=CONFIDENCE.NORM(0.05,1,100)"), 0.19599639845400776), true)
        @Assert(close(calc("=Z.TEST({1,2,3},2)"), 0.5), true)
        @Assert(close(calc("=PERCENTILE.EXC({1,2,3,4},0.5)"), 2.5), true)
        @Assert(close(calc("=PERCENTILE.INC({1,2,3,4},0.5)"), 2.5), true)
        @Assert(close(calc("=SUM(FREQUENCY({1,2,3,4},{2,3}))"), 4.0), true)
        @Assert(close(calc("=INDEX(FREQUENCY({1,2,3,4},{2,3}),1,1)"), 2.0), true)
    }

    @TestCase
    public func databaseFunctions(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Text("Name"))
        sheet.setCell("B1", CellValue.Text("Score"))
        sheet.setCell("A2", CellValue.Text("Alice"))
        sheet.setCell("B2", CellValue.Number(80.0))
        sheet.setCell("A3", CellValue.Text("Bob"))
        sheet.setCell("B3", CellValue.Number(90.0))
        sheet.setCell("A4", CellValue.Text("Alice"))
        sheet.setCell("B4", CellValue.Number(70.0))
        sheet.setCell("E1", CellValue.Text("Name"))
        sheet.setCell("E2", CellValue.Text("Alice"))
        let engine = CalcEngine(doc)
        let formulas: Array<(String, Float64)> = [
            ("=DSUM(A1:B4,\"Score\",E1:E2)", 150.0),
            ("=DCOUNT(A1:B4,\"Score\",E1:E2)", 2.0),
            ("=DCOUNTA(A1:B4,\"Score\",E1:E2)", 2.0),
            ("=DAVERAGE(A1:B4,\"Score\",E1:E2)", 75.0),
            ("=DMAX(A1:B4,\"Score\",E1:E2)", 80.0),
            ("=DMIN(A1:B4,\"Score\",E1:E2)", 70.0),
            ("=DPRODUCT(A1:B4,\"Score\",E1:E2)", 5600.0),
            ("=DSTDEV(A1:B4,\"Score\",E1:E2)", 7.0710678118654755),
            ("=DVAR(A1:B4,\"Score\",E1:E2)", 50.0),
            ("=DSTDEVP(A1:B4,\"Score\",E1:E2)", 5.0),
            ("=DVARP(A1:B4,\"Score\",E1:E2)", 25.0)
        ]
        for (item in formulas) {
            sheet.setCell("G1", CellValue.Formula(item[0], None))
            @Assert(close(engine.evaluate("Sheet1", "G1"), item[1]), true)
        }
        sheet.setCell("G1", CellValue.Formula("=DGET(A1:B4,\"Score\",E1:E2)", None))
        match (engine.evaluate("Sheet1", "G1")) {
            case Error(e) => @Assert(e, CalcError.Num)
            case _ => @Assert(false, true)
        }
    }

    @TestCase
    public func miscFunctions(): Unit {
        @Assert(close(calc("=SUBTOTAL(9,{1,2,3})"), 6.0), true)
        @Assert(close(calc("=AGGREGATE(9,0,{1,2,3})"), 6.0), true)
        @Assert(close(calc("=AGGREGATE(12,0,{1,2,3})"), 2.0), true)
        @Assert(close(calc("=CONVERT(1,\"km\",\"m\")"), 1000.0, tolerance: 1e-9), true)
        @Assert(close(calc("=CONVERT(100,\"c\",\"f\")"), 212.0, tolerance: 1e-9), true)
        @Assert(close(calc("=ERF.PRECISE(0)"), 0.0), true)
        @Assert(close(calc("=ERFC.PRECISE(0)"), 1.0), true)
        @Assert(close(calc("=MDETERM({1,2;3,4})"), -2.0), true)
        @Assert(close(calc("=INDEX(MINVERSE({1,2;3,4}),1,1)"), -2.0, tolerance: 1e-9), true)
        @Assert(close(calc("=SUM(MUNIT(2))"), 2.0), true)
        @Assert(calc("=INFO(\"system\")").toString(), "Linux")
        @Assert(calc("=SEARCHB(\"b\",\"abc\")").toString(), "2")
        @Assert(calc("=REPLACEB(\"abcdef\",2,3,\"X\")").toString(), "aXef")
        @Assert(calc("=PHONETIC(\"abc\")").toString(), "abc")
        @Assert(close(calc("=COUNTUNIQUE({1,1,2})"), 2.0), true)
        @Assert(close(calc("=PROB({1,2,3},{0.2,0.3,0.5},2,3)"), 0.8), true)
        let tbill = calc("=TBILLPRICE(DATE(2024,1,1),DATE(2024,7,1),0.05)")
        @Assert(match (tbill) {
            case Number(v) => v > 97.0 && v < 98.0
            case _ => false
        }, true)
    }

    @TestCase
    public func formulaIntrospection(): Unit {
        let doc = ExcelDocument()
        let sheet = doc.sheet("Sheet1").getOrThrow()
        sheet.setCell("A1", CellValue.Formula("1+1", None))
        sheet.setCell("B1", CellValue.Formula("=ISFORMULA(A1)", None))
        sheet.setCell("B2", CellValue.Formula("=FORMULATEXT(A1)", None))
        sheet.setCell("B3", CellValue.Formula("=CELL(\"row\",A5)", None))
        sheet.setCell("B4", CellValue.Formula("=CELL(\"address\",A5)", None))
        let engine = CalcEngine(doc)
        @Assert(engine.evaluate("Sheet1", "B1").toString(), "TRUE")
        @Assert(engine.evaluate("Sheet1", "B2").toString(), "=1+1")
        @Assert(engine.evaluate("Sheet1", "B3").toString(), "5")
        @Assert(engine.evaluate("Sheet1", "B4").toString(), "$A$5")
    }

    @TestCase
    public func cashflowWithDates(): Unit {
        let xnpv = calc("=XNPV(0.1,{-100,110},{DATE(2023,1,1),DATE(2024,1,1)})")
        @Assert(close(xnpv, 0.0, tolerance: 1e-6), true)
        let xirr = calc("=XIRR({-100,110},{DATE(2023,1,1),DATE(2024,1,1)})")
        @Assert(close(xirr, 0.1, tolerance: 1e-4), true)
    }

    @TestCase
    public func registryCoversDistDbList(): Unit {
        var missing = 0
        for (name in DIST_DB_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(DIST_DB_FUNCTION_NAMES.size), 53)
    }
}
