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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

internal func m5CodePoints(text: String): Array<Int64> {
    let result = ArrayList<Int64>()
    for (rune in text.runes()) {
        result.add(Int64(UInt32(rune)))
    }
    result.toArray()
}

@Test
public class SvgBidiM5_test {
    /** 八类代表字符。 */
    @TestCase
    public func classMapping(): Unit {
        @Assert(svgBidiClass(0x41) == SvgBidiClass.L)
        @Assert(svgBidiClass(0x5D0) == SvgBidiClass.R)
        @Assert(svgBidiClass(0x627) == SvgBidiClass.AL)
        @Assert(svgBidiClass(0x31) == SvgBidiClass.EN)
        @Assert(svgBidiClass(0x661) == SvgBidiClass.AN)
        @Assert(svgBidiClass(0x20) == SvgBidiClass.WS)
        @Assert(svgBidiClass(0x2E) == SvgBidiClass.ON)
        @Assert(svgBidiClass(0x0A) == SvgBidiClass.B)
        @Assert(svgBidiClass(0x4E00) == SvgBidiClass.L)
    }

    /** 段落层级与数字的 LTR 保持。 */
    @TestCase
    public func levels(): Unit {
        let ltr = svgBidiLevels(m5CodePoints("abc"), false)
        @Assert(ltr == [0, 0, 0])
        let rtl = svgBidiLevels(m5CodePoints("אב"), true)
        @Assert(rtl == [1, 1])
        let digits = svgBidiLevels(m5CodePoints("אב12"), true)
        @Assert(digits == [1, 1, 2, 2])
        let ltrDigits = svgBidiLevels(m5CodePoints("ab12"), false)
        @Assert(ltrDigits == [0, 0, 0, 0])
    }

    /** 纯 RTL 反转与数字保持。 */
    @TestCase
    public func visualOrder(): Unit {
        let pure = svgBidiVisualOrder(svgBidiLevels(m5CodePoints("אבג"), true))
        @Assert(pure == [2, 1, 0])
        let mixed = svgBidiVisualOrder(svgBidiLevels(m5CodePoints("אב12"), true))
        @Assert(mixed == [2, 3, 1, 0])
        let ltr = svgBidiVisualOrder(svgBidiLevels(m5CodePoints("abc"), false))
        @Assert(ltr == [0, 1, 2])
    }

    /** `bidi-override` 把所有字符强制到基础层级。 */
    @TestCase
    public func override(): Unit {
        let rtl = svgBidiOverrideLevels(m5CodePoints("abc"), true)
        @Assert(rtl == [1, 1, 1])
        @Assert(svgBidiVisualOrder(rtl) == [2, 1, 0])
        let ltr = svgBidiOverrideLevels(m5CodePoints("אב"), false)
        @Assert(ltr == [0, 0])
        @Assert(svgBidiVisualOrder(ltr) == [0, 1])
    }

    /** 中性字符按两侧强类型解析。 */
    @TestCase
    public func neutrals(): Unit {
        let levels = svgBidiLevels(m5CodePoints("א-ב"), true)
        @Assert(levels[1] == 1)
        let spaced = svgBidiLevels(m5CodePoints("א ב"), true)
        @Assert(spaced[1] == 1)
    }

    /** 单层括号镜像。 */
    @TestCase
    public func mirroring(): Unit {
        @Assert(svgMirrorBidiCodePoint(0x28) == 0x29)
        @Assert(svgMirrorBidiCodePoint(0x29) == 0x28)
        @Assert(svgMirrorBidiCodePoint(0x5B) == 0x5D)
        @Assert(svgMirrorBidiCodePoint(0x41) == 0x41)
    }

    /** 重复计算结果稳定。 */
    @TestCase
    public func deterministic(): Unit {
        let cps = m5CodePoints("אב12(x)")
        let first = svgBidiVisualOrder(svgBidiLevels(cps, true))
        let second = svgBidiVisualOrder(svgBidiLevels(cps, true))
        @Assert(first == second)
    }
}
