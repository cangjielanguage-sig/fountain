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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgLength_test {
    /** 全部单位都能解析。 */
    @TestCase
    public func allUnits(): Unit {
        let cases: Array<(String, Float64, SvgLengthUnit)> = [
            ("10", 10.0, SvgLengthUnit.Number),
            ("50%", 50.0, SvgLengthUnit.Percent),
            ("1.5em", 1.5, SvgLengthUnit.Em),
            ("2ex", 2.0, SvgLengthUnit.Ex),
            ("10px", 10.0, SvgLengthUnit.Px),
            ("12pt", 12.0, SvgLengthUnit.Pt),
            ("1pc", 1.0, SvgLengthUnit.Pc),
            ("2.54cm", 2.54, SvgLengthUnit.Cm),
            ("25.4mm", 25.4, SvgLengthUnit.Mm),
            ("1in", 1.0, SvgLengthUnit.In)
        ]
        for ((text, value, unit) in cases) {
            let length = SvgLength.parse(text)
            @Assert(length.value == value)
            @Assert(length.unit == unit)
        }
    }

    /** 单位大小写不敏感。 */
    @TestCase
    public func unitCaseInsensitive(): Unit {
        @Assert(SvgLength.parse("10PX").unit == SvgLengthUnit.Px)
        @Assert(SvgLength.parse("1.5EM").unit == SvgLengthUnit.Em)
        @Assert(SvgLength.parse("2.54CM").unit == SvgLengthUnit.Cm)
        @Assert(SvgLength.parse("1IN").unit == SvgLengthUnit.In)
        @Assert(SvgLength.parse("12Pt").unit == SvgLengthUnit.Pt)
    }

    /** 前后空白被忽略，负数与小数为合法输入。 */
    @TestCase
    public func whitespaceAndSigns(): Unit {
        @Assert(SvgLength.parse("  10px  ") == SvgLength(10.0, unit: SvgLengthUnit.Px))
        @Assert(SvgLength.parse("\t-2.5em\n") == SvgLength(-2.5, unit: SvgLengthUnit.Em))
        @Assert(SvgLength.parse("+.5") == SvgLength(0.5))
        @Assert(SvgLength.parse("1.") == SvgLength(1.0))
        @Assert(SvgLength.parse("-0") == SvgLength(0.0))
    }

    /** 非法输入抛 InvalidValue，tryParse 返回 None。 */
    @TestCase
    public func invalidInputs(): Unit {
        let bad = ["", "   ", "10foo", "px", "10pxx", "--1", "1e", "NaN", "Inf", "-Inf", "10 20"]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgLength.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
            @Assert(SvgLength.tryParse(current).isNone())
        }
    }

    /** 超长数字溢出为 Inf，按 InvalidValue 拒绝。 */
    @TestCase
    public func overflowRejected(): Unit {
        var text = "1"
        for (_ in 0..400) {
            text += "0"
        }
        let overflow = text
        let error = expectSvgException({=> SvgLength.parse(overflow)})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
    }

    /** toString 输出规范形式。 */
    @TestCase
    public func canonicalToString(): Unit {
        @Assert(SvgLength.parse("10.000").toString() == "10")
        @Assert(SvgLength.parse("1.500em").toString() == "1.5em")
        @Assert(SvgLength.parse("50%").toString() == "50%")
        @Assert(SvgLength.parse("10PX").toString() == "10px")
        @Assert(SvgLength.parse("-0.0").toString() == "0")
    }

    /** parse(toString(x)) == x。 */
    @TestCase
    public func roundTrip(): Unit {
        let samples = ["0", "1", "-1.25", "50%", "1.5em", "2ex", "3px", "4pt", "5pc", "6cm", "7mm", "8in"]
        for (text in samples) {
            let length = SvgLength.parse(text)
            @Assert(SvgLength.parse(length.toString()) == length)
        }
    }

    /** 绝对单位判定：百分比与相对字体单位不是绝对单位。 */
    @TestCase
    public func absoluteUnits(): Unit {
        @Assert(SvgLength(1.0).isAbsolute())
        @Assert(SvgLength(1.0, unit: SvgLengthUnit.Px).isAbsolute())
        @Assert(SvgLength(1.0, unit: SvgLengthUnit.Cm).isAbsolute())
        @Assert(!SvgLength(1.0, unit: SvgLengthUnit.Percent).isAbsolute())
        @Assert(!SvgLength(1.0, unit: SvgLengthUnit.Em).isAbsolute())
        @Assert(!SvgLength(1.0, unit: SvgLengthUnit.Ex).isAbsolute())
    }

    /** 单位枚举的 toString 都是稳定的小写名。 */
    @TestCase
    public func unitNames(): Unit {
        @Assert(SvgLengthUnit.Number.toString() == "Number")
        @Assert(SvgLengthUnit.Percent.toString() == "Percent")
        @Assert(SvgLengthUnit.Em.toString() == "Em")
        @Assert(SvgLengthUnit.Ex.toString() == "Ex")
        @Assert(SvgLengthUnit.Px.toString() == "Px")
        @Assert(SvgLengthUnit.Pt.toString() == "Pt")
        @Assert(SvgLengthUnit.Pc.toString() == "Pc")
        @Assert(SvgLengthUnit.Cm.toString() == "Cm")
        @Assert(SvgLengthUnit.Mm.toString() == "Mm")
        @Assert(SvgLengthUnit.In.toString() == "In")
    }
}
