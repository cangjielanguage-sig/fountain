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

/** GPOS PairPos format 1。 */
internal func m5GposFormat1(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(0).u16(0).u16(0).u16(10) // header
    w.u16(1).u16(4) // lookup list
    w.u16(2).u16(0).u16(1).u16(8) // lookup
    w.u16(1).u16(12).u16(4).u16(0).u16(1).u16(18) // subtable header
    w.u16(1).u16(1).u16(first) // coverage
    w.u16(1).u16(second).i16(xAdvance) // pair set
    w.toArray()
}

/** GPOS PairPos format 2（每个类一个字形）。 */
internal func m5GposFormat2(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(0).u16(0).u16(0).u16(10)
    w.u16(1).u16(4)
    w.u16(2).u16(0).u16(1).u16(8)
    // 子表：header 16 bytes，class1Record 矩阵紧随其后。
    w.u16(2).u16(18).u16(4).u16(0).u16(24).u16(32).u16(1).u16(1)
    w.i16(xAdvance) // matrix at 16
    w.u16(1).u16(1).u16(first) // coverage at 18
    w.u16(1).u16(first).u16(1).u16(0) // classDef1 at 24
    w.u16(1).u16(second).u16(1).u16(0) // classDef2 at 32
    w.toArray()
}

/** GPOS format 2 的 class 数超限（矩阵不写出，解析器应在读取前拒绝）。 */
internal func m5GposOverLimit(): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(0).u16(0).u16(0).u16(10)
    w.u16(1).u16(4)
    w.u16(2).u16(0).u16(1).u16(8)
    w.u16(2).u16(18).u16(4).u16(0).u16(24).u16(32).u16(300).u16(300)
    w.u16(1).u16(1).u16(1) // coverage at 18
    w.u16(1).u16(1).u16(0) // classDef1 at 24
    w.u16(1).u16(1).u16(0) // classDef2 at 32
    w.toArray()
}

/** GSUB LigatureSubst format 1：`first + rest -> ligGlyph`。 */
internal func m5Gsub(first: Int64, ligatures: Array<(Int64, Array<Int64>)>): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(0).u16(0).u16(0).u16(10)
    w.u16(1).u16(4)
    w.u16(4).u16(0).u16(1).u16(8)
    // subtable header at 22: format, covOff, ligSetCount, ligSetOff
    w.u16(1).u16(8).u16(1).u16(14)
    w.u16(1).u16(1).u16(first) // coverage
    // ligature set
    w.u16(ligatures.size)
    let offsets = ArrayList<Int64>()
    var cursor = 2 + ligatures.size * 2
    for ((_, rest) in ligatures) {
        offsets.add(cursor)
        cursor += 4 + 2 * rest.size
    }
    for (value in offsets) {
        w.u16(value)
    }
    for ((glyph, rest) in ligatures) {
        w.u16(glyph).u16(1 + rest.size)
        for (component in rest) {
            w.u16(component)
        }
    }
    w.toArray()
}

@Test
public class SvgGposM5_test {
    /** format 1 的 xAdvance 调整。 */
    @TestCase
    public func pairFormatOne(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(m5Table(m5GposFormat1(1, 2, -50), "GPOS"), warnings)
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                @Assert(value.adjust(1, 2) == -50)
                @Assert(value.adjust(1, 3) == 0)
                @Assert(value.adjust(5, 2) == 0)
            case None => @Fail("应解析成功")
        }
    }

    /** format 2 的 class pair。 */
    @TestCase
    public func pairFormatTwo(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(m5Table(m5GposFormat2(1, 2, -70), "GPOS"), warnings)
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                @Assert(value.adjust(1, 2) == -70)
                @Assert(value.adjust(9, 2) == -70)
            case None => @Fail("应解析成功")
        }
    }

    /** 超过 65536 个 class pair 时忽略并告警。 */
    @TestCase
    public func pairLimit(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(m5Table(m5GposOverLimit(), "GPOS"), warnings)
        @Assert(table.isNone())
        var sawLimit = false
        for (warning in warnings) {
            if (warning.contains("65536")) {
                sawLimit = true
            }
        }
        @Assert(sawLimit)
    }

    /** 截断表返回 None 并告警。 */
    @TestCase
    public func truncatedGpos(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgGposPairs.parse(m5Table([0, 1, 0, 0], "GPOS"), warnings).isNone())
        @Assert(warnings.size >= 1)
    }
}

@Test
public class SvgGsubM5_test {
    /** 双字形连字。 */
    @TestCase
    public func twoGlyphLigature(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGsubLigatures.parse(
            m5Table(m5Gsub(1, [(10, [2])]), "GSUB"),
            warnings
        )
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                match (value.findLigature([1, 2], 0)) {
                    case Some(found) =>
                        @Assert(found[0] == 10)
                        @Assert(found[1] == 2)
                    case None => @Fail("应命中连字")
                }
                @Assert(value.findLigature([1, 3], 0).isNone())
            case None => @Fail("应解析成功")
        }
    }

    /** 最长匹配优先。 */
    @TestCase
    public func longestMatchWins(): Unit {
        let table = SvgGsubLigatures.parse(
            m5Table(m5Gsub(1, [(10, [2]), (11, [2, 3])]), "GSUB"),
            ArrayList<String>()
        )
        match (table) {
            case Some(value) =>
                match (value.findLigature([1, 2, 3], 0)) {
                    case Some(found) =>
                        @Assert(found[0] == 11)
                        @Assert(found[1] == 3)
                    case None => @Fail("应命中三字形连字")
                }
                match (value.findLigature([1, 2], 0)) {
                    case Some(found) => @Assert(found[0] == 10)
                    case None => @Fail("应回退到双字形连字")
                }
            case None => @Fail("应解析成功")
        }
    }

    /** 超过 4 个输入字形的规则不参与匹配。 */
    @TestCase
    public func inputLimit(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGsubLigatures.parse(
            m5Table(m5Gsub(1, [(12, [2, 3, 4, 5])]), "GSUB"),
            warnings
        )
        @Assert(table.isSome())
        match (table) {
            case Some(value) => @Assert(value.findLigature([1, 2, 3, 4, 5], 0).isNone())
            case None => ()
        }
    }

    /** 截断表返回 None 并告警。 */
    @TestCase
    public func truncatedGsub(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgGsubLigatures.parse(m5Table([0, 1, 0, 0], "GSUB"), warnings).isNone())
        @Assert(warnings.size >= 1)
    }
}
