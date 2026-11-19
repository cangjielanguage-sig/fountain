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
public class M3DynFin_test {
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
    public func dynamicArrays(): Unit {
        @Assert(close(calc("=INDEX(SORTBY({3;1;2},{3;1;2}),1,1)"), 1.0), true)
        @Assert(close(calc("=INDEX(TAKE({1,2;3,4},1),1,2)"), 2.0), true)
        @Assert(close(calc("=INDEX(DROP({1,2;3,4},1),1,1)"), 3.0), true)
        @Assert(close(calc("=INDEX(CHOOSEROWS({1;2;3},2),1,1)"), 2.0), true)
        @Assert(close(calc("=INDEX(CHOOSECOLS({1,2,3},2),1,1)"), 2.0), true)
        @Assert(close(calc("=SUM(EXPAND({1},2,2,0))"), 1.0), true)
        @Assert(close(calc("=SUM(VSTACK({1},{2}))"), 3.0), true)
        @Assert(close(calc("=SUM(HSTACK({1},{2}))"), 3.0), true)
        @Assert(close(calc("=SUM(TOCOL({1,2}))"), 3.0), true)
        @Assert(close(calc("=SUM(TOROW({1;2}))"), 3.0), true)
        @Assert(close(calc("=INDEX(WRAPROWS({1,2,3,4},2),2,1)"), 3.0), true)
        @Assert(close(calc("=INDEX(WRAPCOLS({1,2,3,4},2),1,2)"), 3.0), true)
    }

    @TestCase
    public func lookupAndDate(): Unit {
        @Assert(calc("=ADDRESS(1,1)").toString(), "$A$1")
        @Assert(calc("=ADDRESS(1,1,4)").toString(), "A1")
        @Assert(close(calc("=AREAS(A1:B2)"), 1.0), true)
        @Assert(calc("=HYPERLINK(\"http://x\",\"y\")").toString(), "y")
        @Assert(close(calc("=XMATCH(2,{1,2,3})"), 2.0), true)
        @Assert(close(calc("=TIME(12,0,0)"), 0.5), true)
        @Assert(close(calc("=ISOWEEKNUM(DATE(2024,1,1))"), 1.0), true)
        @Assert(close(calc("=YEARFRAC(DATE(2024,1,1),DATE(2025,1,1),1)"), 1.0), true)
        @Assert(close(calc("=NETWORKDAYS.INTL(DATE(2024,1,1),DATE(2024,1,7))"), 5.0), true)
        @Assert(close(calc("=WORKDAY.INTL(DATE(2024,1,1),5)"), calcNumber("=DATE(2024,1,8)")), true)
    }

    private static func calcNumber(formula: String): Float64 {
        match (calc(formula)) {
            case Number(v) => v
            case _ => -999999.0
        }
    }

    @TestCase
    public func financial(): Unit {
        @Assert(close(calc("=DB(1000,100,5,1)"), 369.0), true)
        @Assert(close(calc("=DDB(1000,100,5,1)"), 400.0), true)
        @Assert(close(calc("=SYD(1000,100,5,1)"), 300.0), true)
        @Assert(close(calc("=EFFECT(0.1,12)"), 0.10471306744129685), true)
        @Assert(close(calc("=NOMINAL(0.1,12)"), 0.09568968514684545), true)
        @Assert(close(calc("=FVSCHEDULE(100,{0.1,0.2})"), 132.0), true)
        @Assert(close(calc("=PDURATION(0.1,100,200)"), 7.272540897341714), true)
        @Assert(close(calc("=RRI(10,100,200)"), 0.0717734625362931), true)
        @Assert(close(calc("=ISPMT(0.1,1,10,1000)"), -90.0), true)
        @Assert(close(calc("=CUMIPMT(0.1,2,100,1,2,0)"), -15.238095238095237), true)
        @Assert(close(calc("=CUMPRINC(0.1,2,100,1,2,0)"), -100.0), true)
        @Assert(close(calc("=DOLLARDE(1.02,16)"), 1.125), true)
        @Assert(close(calc("=DOLLARFR(1.125,16)"), 1.02), true)
        @Assert(close(calc("=IRR({-100,60,60})"), 0.13066238629180747, tolerance: 1e-6), true)
        @Assert(close(calc("=RATE(2,-57.61904761904762,100)"), 0.1, tolerance: 1e-6), true)
        @Assert(close(calc("=MIRR({-100,60,60},0.1,0.1)"), 0.12249721603218244, tolerance: 1e-6), true)
    }

    @TestCase
    public func registryCoversDynFinList(): Unit {
        var missing = 0
        for (name in DYN_FIN_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(DYN_FIN_FUNCTION_NAMES.size), 37)
    }
}
