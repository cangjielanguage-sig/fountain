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
public class M3StatText_test {
    private static func calc(formula: String): CalcValue {
        let doc = ExcelDocument()
        let engine = CalcEngine(doc)
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Formula(formula, None))
        engine.evaluate("Sheet1", "A1")
    }

    private static func close(value: CalcValue, expected: Float64): Bool {
        match (value) {
            case Number(v) => abs(v - expected) < 1e-9
            case _ => false
        }
    }

    @TestCase
    public func dispersionAndMoments(): Unit {
        let values: Array<(String, Float64)> = [
            ("=AVEDEV(1,2,3)", 0.6666666666666666),
            ("=DEVSQ(1,2,3)", 2.0),
            ("=GEOMEAN(1,4)", 2.0),
            ("=HARMEAN(1,2,4)", 1.7142857142857142),
            ("=KURT(1,2,3,4,5)", -1.2),
            ("=SKEW(1,2,3,4,5)", 0.0),
            ("=SKEW.P(1,2,3,4,5)", 0.0),
            ("=TRIMMEAN({1,2,3,4,100},0.4)", 3.0),
            ("=PERCENTRANK({1,2,3,4},3)", 0.6666666666666666),
            ("=PERCENTRANK.EXC({1,2,3,4},3)", 0.6),
            ("=QUARTILE.INC({1,2,3,4},1)", 1.75),
            ("=QUARTILE.EXC({1,2,3,4},1)", 1.25),
            ("=STDEVA({1,2,\"x\"})", 1.0),
            ("=STDEVPA({1,2,\"x\"})", 0.816496580927726),
            ("=VARA({1,2,\"x\"})", 1.0),
            ("=VARPA({1,2,\"x\"})", 0.6666666666666666)
        ]
        for (item in values) {
            @Assert(close(calc(item[0]), item[1]), true)
        }
    }

    @TestCase
    public func regressionAndRank(): Unit {
        let values: Array<(String, Float64)> = [
            ("=COVARIANCE.P({1,2,3},{2,4,6})", 1.3333333333333333),
            ("=COVARIANCE.S({1,2,3},{2,4,6})", 2.0),
            ("=FISHER(0)", 0.0),
            ("=FISHERINV(0)", 0.0),
            ("=STANDARDIZE(5,3,2)", 1.0),
            ("=RSQ({1,2,3},{2,4,6})", 1.0),
            ("=PEARSON({1,2,3},{2,4,6})", 1.0),
            ("=AVERAGEA(1,2,\"x\")", 1.0),
            ("=MAXA(1,\"x\")", 1.0),
            ("=MINA(1,\"x\")", 0.0),
            ("=MODE.SNGL(1,1,2)", 1.0),
            ("=SUM(MODE.MULT(1,1,2,2))", 3.0),
            ("=RANK.EQ(2,{1,2,3})", 2.0),
            ("=RANK.AVG(2,{1,2,2,3})", 2.5)
        ]
        for (item in values) {
            @Assert(close(calc(item[0]), item[1]), true)
        }
    }

    @TestCase
    public func infoAndText(): Unit {
        @Assert(calc("=ISEVEN(4)").toString(), "TRUE")
        @Assert(calc("=ISODD(3)").toString(), "TRUE")
        @Assert(calc("=N(TRUE)").toString(), "1")
        @Assert(close(calc("=SHEET()"), 1.0), true)
        @Assert(close(calc("=SHEETS()"), 1.0), true)
        @Assert(calc("=TEXTBEFORE(\"a-b-c\",\"-\")").toString(), "a")
        @Assert(calc("=TEXTAFTER(\"a-b-c\",\"-\")").toString(), "b-c")
        @Assert(calc("=INDEX(TEXTSPLIT(\"a,b,c\",\",\"),2,1)").toString(), "b")
        @Assert(close(calc("=NUMBERVALUE(\"1.234,56\",\",\",\".\")"), 1234.56), true)
        @Assert(calc("=DOLLAR(1234.5)").toString(), "$1,234.50")
        @Assert(calc("=FIXED(1234.5,1)").toString(), "1,234.5")
        @Assert(calc("=FIXED(1234.5,1,TRUE)").toString(), "1234.5")
        @Assert(calc("=WIDECHAR(\"abc\")").toString(), "abc")
        @Assert(calc("=ASC(\"abc\")").toString(), "abc")
        @Assert(close(calc("=LENB(\"abc\")"), 3.0), true)
        @Assert(calc("=LEFTB(\"abc\",2)").toString(), "ab")
        @Assert(calc("=RIGHTB(\"abc\",2)").toString(), "bc")
        @Assert(calc("=MIDB(\"abc\",2,1)").toString(), "b")
        @Assert(calc("=VALUETOTEXT(1)").toString(), "1")
        @Assert(calc("=ARRAYTOTEXT({1,2})").toString(), "1, 2")
    }

    @TestCase
    public func isRefSeesReference(): Unit {
        let doc = ExcelDocument()
        let engine = CalcEngine(doc)
        doc.sheet("Sheet1").getOrThrow().setCell("A1", CellValue.Number(1.0))
        doc.sheet("Sheet1").getOrThrow().setCell("B1", CellValue.Formula("ISREF(A1)", None))
        doc.sheet("Sheet1").getOrThrow().setCell("B2", CellValue.Formula("ISREF(1)", None))
        @Assert(engine.evaluate("Sheet1", "B1").toString(), "TRUE")
        @Assert(engine.evaluate("Sheet1", "B2").toString(), "FALSE")
    }

    @TestCase
    public func registryCoversStatTextList(): Unit {
        var missing = 0
        for (name in STAT_TEXT_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(STAT_TEXT_FUNCTION_NAMES.size), 51)
    }
}
