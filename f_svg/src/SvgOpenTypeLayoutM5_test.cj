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

/** GPOS PairPos format 1 子表。 */
internal func m5GposPairSubtable1(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(12).u16(4).u16(0).u16(1).u16(18)
    w.u16(1).u16(1).u16(first)
    w.u16(1).u16(second).i16(xAdvance)
    w.toArray()
}

/** GPOS PairPos format 2 子表（每个类一个字形）。 */
internal func m5GposPairSubtable2(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(2).u16(18).u16(4).u16(0).u16(24).u16(32).u16(1).u16(1)
    w.i16(xAdvance)
    w.u16(1).u16(1).u16(first)
    w.u16(1).u16(first).u16(1).u16(0)
    w.u16(1).u16(second).u16(1).u16(0)
    w.toArray()
}

/** GSUB LigatureSubst format 1 子表：`first + rest -> ligGlyph`。 */
internal func m5GsubSubtable(first: Int64, ligatures: Array<(Int64, Array<Int64>)>): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(8).u16(1).u16(14)
    w.u16(1).u16(1).u16(first)
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

/**
 * 构造带真实 ScriptList / FeatureList / LookupList 的 GPOS / GSUB 表。
 *
 * `subtables[i]` 对应第 i 个 lookup（从 1 计深度），`None` 表示该 lookup 不含子表。
 */
internal func m5LayoutTable(
    featureTag: String,
    lookupType: Int64,
    subtables: Array<?Array<Byte>>
): Array<Byte> {
    let lookupCount = subtables.size
    let featureListSize = 12 + 2 * lookupCount
    let featureListOffset = 30
    let lookupListOffset = featureListOffset + featureListSize
    let lookupListSize = 2 + 2 * lookupCount

    let lookupOffsets = ArrayList<Int64>()
    let lookupBodies = ArrayList<Array<Byte>>()
    var lookupCursor = lookupListOffset + lookupListSize
    for (subtable in subtables) {
        lookupOffsets.add(lookupCursor - lookupListOffset)
        let w = M4ByteWriter()
        match (subtable) {
            case Some(bytes) =>
                w.u16(lookupType).u16(0).u16(1).u16(8)
                for (byte in bytes) {
                    w.data.add(byte)
                }
            case None =>
                w.u16(lookupType).u16(0).u16(0)
        }
        let body = w.toArray()
        lookupBodies.add(body)
        lookupCursor += Int64(body.size)
    }

    let w = M4ByteWriter()
    w.u16(1).u16(0)
    w.u16(10).u16(featureListOffset).u16(lookupListOffset)
    // ScriptList：DFLT + 默认 LangSys 引用 feature 0。
    w.u16(1)
    w.tag("DFLT").u16(8)
    w.u16(4).u16(0)
    w.u16(0).u16(0xFFFF).u16(1).u16(0)
    // FeatureList。
    w.u16(1)
    w.tag(featureTag).u16(8)
    w.u16(0).u16(lookupCount)
    for (index in 0..lookupCount) {
        w.u16(index)
    }
    // LookupList。
    w.u16(lookupCount)
    for (offset in lookupOffsets) {
        w.u16(offset)
    }
    for (body in lookupBodies) {
        for (byte in body) {
            w.data.add(byte)
        }
    }
    w.toArray()
}

/** GPOS：单个 lookup 内两个 PairPos format 2 子表，覆盖不同左字形。 */
internal func m5GposFormat2Combined(
    firstA: Int64,
    secondA: Int64,
    xAdvanceA: Int64,
    firstB: Int64,
    secondB: Int64,
    xAdvanceB: Int64
): Array<Byte> {
    let subtableA = m5GposPairSubtable2(firstA, secondA, xAdvanceA)
    let subtableB = m5GposPairSubtable2(firstB, secondB, xAdvanceB)
    let featureListOffset = 30
    let featureListSize = 14
    let lookupListOffset = featureListOffset + featureListSize
    let lookupListSize = 4
    let lookupOffset = lookupListOffset + lookupListSize
    let subtableAOffset = 10
    let subtableBOffset = subtableAOffset + Int64(subtableA.size)

    let w = M4ByteWriter()
    w.u16(1).u16(0)
    w.u16(10).u16(featureListOffset).u16(lookupListOffset)
    // ScriptList。
    w.u16(1)
    w.tag("DFLT").u16(8)
    w.u16(4).u16(0)
    w.u16(0).u16(0xFFFF).u16(1).u16(0)
    // FeatureList：kern → lookup 0。
    w.u16(1)
    w.tag("kern").u16(8)
    w.u16(0).u16(1).u16(0)
    // LookupList：一个 lookup。
    w.u16(1).u16(lookupOffset - lookupListOffset)
    // Lookup：Type 2，两个子表。
    w.u16(2).u16(0).u16(2).u16(subtableAOffset).u16(subtableBOffset)
    for (byte in subtableA) {
        w.data.add(byte)
    }
    for (byte in subtableB) {
        w.data.add(byte)
    }
    w.toArray()
}

/** GPOS PairPos format 1（`kern` 特性）。 */
internal func m5GposFormat1(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    m5LayoutTable("kern", 2, [Some(m5GposPairSubtable1(first, second, xAdvance))])
}

/** GPOS PairPos format 1，可指定特性标签。 */
internal func m5GposFormat1Tagged(
    tag: String,
    first: Int64,
    second: Int64,
    xAdvance: Int64
): Array<Byte> {
    m5LayoutTable(tag, 2, [Some(m5GposPairSubtable1(first, second, xAdvance))])
}

/** GPOS PairPos format 2（`kern` 特性）。 */
internal func m5GposFormat2(first: Int64, second: Int64, xAdvance: Int64): Array<Byte> {
    m5LayoutTable("kern", 2, [Some(m5GposPairSubtable2(first, second, xAdvance))])
}

/** GPOS format 2 的 class 数超限（矩阵不写出，解析器应在读取前拒绝）。 */
internal func m5GposOverLimit(): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(2).u16(18).u16(4).u16(0).u16(24).u16(32).u16(300).u16(300)
    w.u16(1).u16(1).u16(1)
    w.u16(1).u16(1).u16(0)
    w.u16(1).u16(1).u16(0)
    m5LayoutTable("kern", 2, [Some(w.toArray())])
}

/** GSUB LigatureSubst format 1（`liga` 特性）。 */
internal func m5Gsub(first: Int64, ligatures: Array<(Int64, Array<Int64>)>): Array<Byte> {
    m5LayoutTable("liga", 4, [Some(m5GsubSubtable(first, ligatures))])
}

/** GSUB LigatureSubst，可指定特性标签。 */
internal func m5GsubTagged(
    tag: String,
    first: Int64,
    ligatures: Array<(Int64, Array<Int64>)>
): Array<Byte> {
    m5LayoutTable(tag, 4, [Some(m5GsubSubtable(first, ligatures))])
}

/**
 * GSUB 扩展 lookup 链：`wrappers` 层 Type 7 依次指向下一个 lookup，末端为 Type 4。
 *
 * feature 只引用第 0 个 lookup；末端 Type 4 的链深度为 `wrappers + 1`。
 */
internal func m5GsubExtensionChain(
    wrappers: Int64,
    first: Int64,
    ligGlyph: Int64,
    rest: Array<Int64>
): Array<Byte> {
    let lookupCount = wrappers + 1
    let featureListOffset = 30
    let featureListSize = 14
    let lookupListOffset = featureListOffset + featureListSize
    let lookupListSize = 2 + 2 * lookupCount
    let ligatureBody = m5GsubSubtable(first, [(ligGlyph, rest)])
    let type4BodySize = 8 + Int64(ligatureBody.size)
    let type7BodySize = 16

    let offsets = ArrayList<Int64>()
    var cursor = lookupListOffset + lookupListSize
    for (index in 0..lookupCount) {
        offsets.add(cursor - lookupListOffset)
        cursor += if (index < wrappers) { type7BodySize } else { type4BodySize }
    }

    let w = M4ByteWriter()
    w.u16(1).u16(0)
    w.u16(10).u16(featureListOffset).u16(lookupListOffset)
    // ScriptList：DFLT + 默认 LangSys 引用 feature 0。
    w.u16(1)
    w.tag("DFLT").u16(8)
    w.u16(4).u16(0)
    w.u16(0).u16(0xFFFF).u16(1).u16(0)
    // FeatureList：单个 liga 特性只引用 lookup 0。
    w.u16(1)
    w.tag("liga").u16(8)
    w.u16(0).u16(1).u16(0)
    // LookupList。
    w.u16(lookupCount)
    for (offset in offsets) {
        w.u16(offset)
    }
    for (index in 0..lookupCount) {
        if (index < wrappers) {
            w.u16(7).u16(0).u16(1).u16(8)
            w.u16(1).u16(4)
            let subtableAbsolute = lookupListOffset + offsets[index] + 8
            let targetAbsolute = lookupListOffset + offsets[index + 1]
            w.u32(targetAbsolute - subtableAbsolute)
        } else {
            w.u16(4).u16(0).u16(1).u16(8)
            for (byte in ligatureBody) {
                w.data.add(byte)
            }
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

    /** format 2 的 class pair 只对 Coverage 内的左字形生效。 */
    @TestCase
    public func pairFormatTwo(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(m5Table(m5GposFormat2(1, 2, -70), "GPOS"), warnings)
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                @Assert(value.adjust(1, 2) == -70)
                @Assert(value.adjust(9, 2) == 0)
            case None => @Fail("应解析成功")
        }
    }

    /** 多个 format 2 子表各自保留 class 矩阵，互不覆盖。 */
    @TestCase
    public func multipleFormatTwoSubtablesMerge(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(
            m5Table(m5GposFormat2Combined(1, 2, -70, 3, 4, -90), "GPOS"),
            warnings
        )
        @Assert(table.isSome())
        match (table) {
            case Some(value) =>
                @Assert(value.adjust(1, 2) == -70)
                @Assert(value.adjust(3, 4) == -90)
                @Assert(value.adjust(9, 2) == 0)
            case None => @Fail("应解析成功")
        }
    }

    /** 非 `kern` 特性的 PairPos 不参与字距。 */
    @TestCase
    public func otherFeatureIsIgnored(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGposPairs.parse(
            m5Table(m5GposFormat1Tagged("vkrn", 1, 2, -50), "GPOS"),
            warnings
        )
        @Assert(table.isNone())
        var sawKern = false
        for (warning in warnings) {
            if (warning.contains("kern")) {
                sawKern = true
            }
        }
        @Assert(sawKern)
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

    /** 非 `liga` 特性的 Type 4 lookup 不参与替换。 */
    @TestCase
    public func otherFeatureIsIgnored(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGsubLigatures.parse(
            m5Table(m5GsubTagged("dlig", 1, [(10, [2])]), "GSUB"),
            warnings
        )
        @Assert(table.isNone())
        var sawLiga = false
        for (warning in warnings) {
            if (warning.contains("liga")) {
                sawLiga = true
            }
        }
        @Assert(sawLiga)
    }

    /** 单次替换输入上限严格为 4；5 个输入字形在解析期被忽略并告警。 */
    @TestCase
    public func inputLimit(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGsubLigatures.parse(
            m5Table(m5Gsub(1, [(12, [2, 3, 4, 5])]), "GSUB"),
            warnings
        )
        @Assert(table.isNone())
        var sawLimit = false
        for (warning in warnings) {
            if (warning.contains("4")) {
                sawLimit = true
            }
        }
        @Assert(sawLimit)
    }

    /** 二层嵌套 lookup：扩展链中深度 2 的连字仍生效。 */
    @TestCase
    public func nestedLookupDepthTwo(): Unit {
        let warnings = ArrayList<String>()
        let table = SvgGsubLigatures.parse(
            m5Table(m5GsubExtensionChain(1, 1, 10, [2]), "GSUB"),
            warnings
        )
        match (table) {
            case Some(value) =>
                match (value.findLigature([1, 2], 0)) {
                    case Some(found) => @Assert(found[0] == 10 && found[1] == 2)
                    case None => @Fail("深度 2 的连字应命中")
                }
            case None => @Fail("二层嵌套 lookup 应解析成功")
        }
    }

    /** lookup 链深度 8 正常，深度 9 停止替换并告警。 */
    @TestCase
    public func lookupDepthLimit(): Unit {
        let allowedWarnings = ArrayList<String>()
        let allowed = SvgGsubLigatures.parse(
            m5Table(m5GsubExtensionChain(7, 1, 10, [2]), "GSUB"),
            allowedWarnings
        )
        @Assert(allowed.isSome())
        match (allowed) {
            case Some(value) =>
                match (value.findLigature([1, 2], 0)) {
                    case Some(found) => @Assert(found[0] == 10 && found[1] == 2)
                    case None => @Fail("深度 8 应保留替换")
                }
            case None => @Fail("深度 8 应解析成功")
        }

        let limitedWarnings = ArrayList<String>()
        let limited = SvgGsubLigatures.parse(
            m5Table(m5GsubExtensionChain(8, 1, 10, [2]), "GSUB"),
            limitedWarnings
        )
        @Assert(limited.isNone())
        var sawDepth = false
        for (warning in limitedWarnings) {
            if (warning.contains("深度")) {
                sawDepth = true
            }
        }
        @Assert(sawDepth)
    }

    /** 截断表返回 None 并告警。 */
    @TestCase
    public func truncatedGsub(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgGsubLigatures.parse(m5Table([0, 1, 0, 0], "GSUB"), warnings).isNone())
        @Assert(warnings.size >= 1)
    }
}
