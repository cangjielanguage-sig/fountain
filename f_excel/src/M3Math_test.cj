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
public class M3Math_test {
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
    public func trigAndRounding(): Unit {
        let values: Array<(String, Float64)> = [
            ("=ACOS(1)", 0.0),
            ("=ASIN(1)", 1.5707963267948966),
            ("=ATAN(1)", 0.7853981633974483),
            ("=ATAN2(1,1)", 0.7853981633974483),
            ("=ACOSH(1)", 0.0),
            ("=ASINH(0)", 0.0),
            ("=ATANH(0)", 0.0),
            ("=COSH(0)", 1.0),
            ("=SINH(0)", 0.0),
            ("=TANH(0)", 0.0),
            ("=SEC(0)", 1.0),
            ("=SECH(0)", 1.0),
            ("=COT(PI()/4)", 1.0),
            ("=COTH(1)", 1.3130352854993315),
            ("=EVEN(1.5)", 2.0),
            ("=EVEN(-1.5)", -2.0),
            ("=ODD(2)", 3.0),
            ("=ODD(-2)", -3.0),
            ("=QUOTIENT(7,2)", 3.0),
            ("=QUOTIENT(-7,2)", -3.0)
        ]
        for (item in values) {
            @Assert(close(calc(item[0]), item[1]), true)
        }
        @Assert(close(calc("=CSC(PI()/2)"), 1.0), true)
    }

    @TestCase
    public func combinatoricsAndSums(): Unit {
        let values: Array<(String, Float64)> = [
            ("=COMBIN(5,2)", 10.0),
            ("=COMBINA(4,3)", 20.0),
            ("=PERMUT(5,2)", 20.0),
            ("=PERMUTATIONA(3,2)", 9.0),
            ("=MULTINOMIAL(2,3,4)", 1260.0),
            ("=FACTDOUBLE(6)", 48.0),
            ("=SQRTPI(4)", 3.5449077018110318),
            ("=SUMSQ(1,2,3)", 14.0),
            ("=SUMX2MY2({1,2,3},{1,2,3})", 0.0),
            ("=SUMX2PY2({1,2},{3,4})", 30.0),
            ("=SUMXMY2({1,2},{3,4})", 8.0),
            ("=SERIESSUM(2,0,1,{1,1,1})", 7.0),
            ("=CEILING.MATH(2.1)", 3.0),
            ("=FLOOR.MATH(2.9)", 2.0),
            ("=CEILING.PRECISE(-2.1,1)", -2.0),
            ("=FLOOR.PRECISE(-2.1)", -3.0),
            ("=ISO.CEILING(2.1)", 3.0)
        ]
        for (item in values) {
            @Assert(close(calc(item[0]), item[1]), true)
        }
    }

    @TestCase
    public func baseAndBits(): Unit {
        @Assert(calc("=BASE(255,16)").toString(), "FF")
        @Assert(calc("=BASE(5,2,8)").toString(), "00000101")
        @Assert(close(calc("=DECIMAL(\"FF\",16)"), 255.0), true)
        @Assert(close(calc("=BITAND(12,10)"), 8.0), true)
        @Assert(close(calc("=BITOR(12,10)"), 14.0), true)
        @Assert(close(calc("=BITXOR(12,10)"), 6.0), true)
        @Assert(close(calc("=BITLSHIFT(3,2)"), 12.0), true)
        @Assert(close(calc("=BITRSHIFT(12,2)"), 3.0), true)
        @Assert(calc("=ROMAN(1994)").toString(), "MCMXCIV")
        @Assert(close(calc("=ARABIC(\"MCMXCIV\")"), 1994.0), true)
    }

    @TestCase
    public func engineeringConversions(): Unit {
        @Assert(calc("=DEC2BIN(10)").toString(), "1010")
        @Assert(close(calc("=BIN2DEC(\"1010\")"), 10.0), true)
        @Assert(calc("=DEC2HEX(255)").toString(), "FF")
        @Assert(close(calc("=HEX2DEC(\"FF\")"), 255.0), true)
        @Assert(calc("=DEC2OCT(8)").toString(), "10")
        @Assert(close(calc("=OCT2DEC(\"10\")"), 8.0), true)
        @Assert(calc("=BIN2HEX(\"1010\")").toString(), "A")
        @Assert(calc("=HEX2BIN(\"A\")").toString(), "1010")
        @Assert(calc("=HEX2OCT(\"FF\")").toString(), "377")
        @Assert(calc("=OCT2BIN(\"10\")").toString(), "1000")
        @Assert(calc("=OCT2HEX(\"10\")").toString(), "8")
        @Assert(close(calc("=DELTA(1,1)"), 1.0), true)
        @Assert(close(calc("=DELTA(1,2)"), 0.0), true)
        @Assert(close(calc("=GESTEP(2,1)"), 1.0), true)
        @Assert(close(calc("=GESTEP(0,1)"), 0.0), true)
        @Assert(close(calc("=ERF(0)"), 0.0), true)
        @Assert(close(calc("=ERFC(0)"), 1.0), true)
    }

    @TestCase
    public func randomArrayStaysInRange(): Unit {
        let value = calc("=SUM(RANDARRAY(3,3,5,5,TRUE))")
        @Assert(close(value, 45.0), true)
    }

    @TestCase
    public func registryCoversMathEngList(): Unit {
        var missing = 0
        for (name in MATH_ENG_FUNCTION_NAMES) {
            if (lookupFunction(name).isNone()) {
                missing++
            }
        }
        @Assert(missing, 0)
        @Assert(Int64(MATH_ENG_FUNCTION_NAMES.size), 62)
    }
}
