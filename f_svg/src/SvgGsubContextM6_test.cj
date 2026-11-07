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

/** Coverage format 1：显式字形列表。 */
private func m6GsubCoverage(glyphs: Array<Int64>): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(glyphs.size)
    for (glyph in glyphs) {
        w.u16(glyph)
    }
    w.toArray()
}

/** GSUB Type 1 format 1：覆盖单字形，按 delta 替换。 */
internal func m6GsubSingleSubtable(glyph: Int64, delta: Int64): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(1).u16(6).i16(delta)
    w.u16(1).u16(1).u16(glyph)
    w.toArray()
}

/** GSUB Type 5 format 3：`inputs[0]` 覆盖首字形，其余为后续输入字形。 */
internal func m6GsubContextSubtable(
    inputs: Array<Array<Int64>>,
    records: Array<(Int64, Int64)>
): Array<Byte> {
    let w = M4ByteWriter()
    w.u16(3).u16(inputs.size).u16(records.size)
    var offset = 6 + 2 * inputs.size + 4 * records.size
    let coverages = ArrayList<Array<Byte>>()
    for (coverage in inputs) {
        w.u16(offset)
        let bytes = m6GsubCoverage(coverage)
        coverages.add(bytes)
        offset += Int64(bytes.size)
    }
    for ((sequence, lookup) in records) {
        w.u16(sequence).u16(lookup)
    }
    for (bytes in coverages) {
        for (byte in bytes) {
            w.data.add(byte)
        }
    }
    w.toArray()
}

/** GSUB Type 6 format 3：回溯 / 输入 / 前瞻三段 coverage 加替换记录。 */
internal func m6GsubChainContextSubtable(
    backtrack: Array<Array<Int64>>,
    inputs: Array<Array<Int64>>,
    lookahead: Array<Array<Int64>>,
    records: Array<(Int64, Int64)>
): Array<Byte> {
    let w = M4ByteWriter()
    let header = 2 + 2 + 2 * backtrack.size + 2 + 2 * inputs.size + 2 + 2 * lookahead.size +
        2 + 4 * records.size
    w.u16(3)
    w.u16(backtrack.size)
    var offset = header
    let coverages = ArrayList<Array<Byte>>()
    for (coverage in backtrack) {
        w.u16(offset)
        let bytes = m6GsubCoverage(coverage)
        coverages.add(bytes)
        offset += Int64(bytes.size)
    }
    w.u16(inputs.size)
    for (coverage in inputs) {
        w.u16(offset)
        let bytes = m6GsubCoverage(coverage)
        coverages.add(bytes)
        offset += Int64(bytes.size)
    }
    w.u16(lookahead.size)
    for (coverage in lookahead) {
        w.u16(offset)
        let bytes = m6GsubCoverage(coverage)
        coverages.add(bytes)
        offset += Int64(bytes.size)
    }
    w.u16(records.size)
    for ((sequence, lookup) in records) {
        w.u16(sequence).u16(lookup)
    }
    for (bytes in coverages) {
        for (byte in bytes) {
            w.data.add(byte)
        }
    }
    w.toArray()
}

/** 组装含多个不同类型 lookup 的 GSUB 表；`featureIndices` 缺省引用全部 lookup。 */
internal func m6GsubTable(
    featureTag: String,
    lookups: Array<(Int64, Array<Array<Byte>>)>,
    featureIndices!: ?Array<Int64> = None
): Array<Byte> {
    let lookupCount = lookups.size
    let refs = match (featureIndices) {
        case Some(value) => value
        case None =>
            let all = ArrayList<Int64>()
            for (index in 0..lookupCount) {
                all.add(index)
            }
            all.toArray()
    }
    let featureListOffset = 30
    let featureListSize = 12 + 2 * refs.size
    let lookupListOffset = featureListOffset + featureListSize
    let lookupListSize = 2 + 2 * lookupCount

    let lookupOffsets = ArrayList<Int64>()
    let lookupBodies = ArrayList<Array<Byte>>()
    var cursor = lookupListOffset + lookupListSize
    for ((lookupType, subtables) in lookups) {
        lookupOffsets.add(cursor - lookupListOffset)
        let w = M4ByteWriter()
        w.u16(lookupType).u16(0).u16(subtables.size)
        var subOffset = 6 + 2 * subtables.size
        for (subtable in subtables) {
            w.u16(subOffset)
            subOffset += Int64(subtable.size)
        }
        for (subtable in subtables) {
            for (byte in subtable) {
                w.data.add(byte)
            }
        }
        let body = w.toArray()
        lookupBodies.add(body)
        cursor += Int64(body.size)
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
    w.u16(0).u16(refs.size)
    for (index in refs) {
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

private func m6ParseContextTable(bytes: Array<Byte>, warnings: ArrayList<String>): ?SvgGsubContextTable {
    SvgGsubContextTable.parse(m5Table(bytes, "GSUB"), warnings)
}

private func m6AllFeatures(): SvgFontFeatures {
    SvgFontFeatures.parse("\"calt\" 1")
}

@Test
public class SvgGsubContextM6_test {
    /** Type 5 format 3：`a` 后接 `b` 时把 `a` 替换为 `a.alt`。 */
    @TestCase
    public func singleLayerContext(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (1, [m6GsubSingleSubtable(1, 1)]),
                (5, [m6GsubContextSubtable([[1], [2]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1, 2], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs.size == 2)
        @Assert(shaped.glyphs[0] == 2)
        @Assert(shaped.glyphs[1] == 2)
    }

    /** Type 5 的后续输入字形不匹配时保持原字形。 */
    @TestCase
    public func contextInputMismatch(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (1, [m6GsubSingleSubtable(1, 1)]),
                (5, [m6GsubContextSubtable([[1], [2]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1, 3], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs[0] == 1)
        @Assert(shaped.glyphs[1] == 3)
    }

    /** Type 6 format 3：回溯与前瞻同时匹配才替换。 */
    @TestCase
    public func chainContextBacktrackAndLookahead(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (1, [m6GsubSingleSubtable(2, 2)]),
                (6, [m6GsubChainContextSubtable([[1]], [[2]], [[3]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let matched = table.shapeGlyphs([1, 2, 3], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(matched.glyphs[1] == 4)
        let noBacktrack = table.shapeGlyphs([9, 2, 3], SvgFontFeatures.parse("\"liga\" 1"), ArrayList<String>())
        @Assert(noBacktrack.glyphs[1] == 2)
        let noLookahead = table.shapeGlyphs([1, 2, 9], SvgFontFeatures.parse("\"liga\" 1"), ArrayList<String>())
        @Assert(noLookahead.glyphs[1] == 2)
    }

    /** 覆盖表越界：忽略子表并 warning，不抛出。 */
    @TestCase
    public func coverageOutOfRange(): Unit {
        // glyphCount 声称 3 个输入，但只写了一个覆盖偏移与一条记录，尾部覆盖缺失。
        let w = M4ByteWriter()
        w.u16(3).u16(3).u16(1)
        w.u16(16).u16(18).u16(20)
        w.u16(0).u16(0)
        let bytes = m6GsubTable("liga", [(5, [w.toArray()])])
        let warnings = ArrayList<String>()
        let parsed = m6ParseContextTable(bytes, warnings)
        @Assert(parsed.isNone() || warnings.size > 0)
        match (parsed) {
            case Some(table) =>
                table.shapeGlyphs([1, 2, 3], SvgFontFeatures.parse("\"liga\" 1"), warnings)
            case None => ()
        }
        @Assert(warnings.size > 0)
    }

    /** 上下文替换引用 Type 4：匹配后生成连字字形。 */
    @TestCase
    public func nestedLigatureLookup(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (4, [m5GsubSubtable(1, [(5, [2])])]),
                (5, [m6GsubContextSubtable([[1], [2]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1, 2], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs.size == 1)
        @Assert(shaped.glyphs[0] == 5)
        @Assert(shaped.removed.size == 1)
    }

    /** 嵌套两层上下文：上下文 A 引用上下文 B，B 再引用单字形替换。 */
    @TestCase
    public func nestedContextTwoLayers(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (5, [m6GsubContextSubtable([[1]], [(0, 1)])]),
                (5, [m6GsubContextSubtable([[1]], [(0, 2)])]),
                (1, [m6GsubSingleSubtable(1, 8)])
            ],
            featureIndices: [0]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs[0] == 9)
        @Assert(warnings.size == 0)
    }

    /** 上下文记录引用 Type 2（多字形替换）时忽略，不插入也不崩溃。 */
    @TestCase
    public func unsupportedNestedLookupIsIgnored(): Unit {
        let bytes = m6GsubTable(
            "liga",
            [
                (5, [m6GsubContextSubtable([[1], [2]], [(0, 1)])]),
                (2, Array<Array<Byte>>())
            ],
            featureIndices: [0]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1, 2], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs.size == 2)
        @Assert(shaped.glyphs[0] == 1)
        @Assert(shaped.glyphs[1] == 2)
    }

    /** 第 8 层生效，第 9 层停止并 warning。 */
    @TestCase
    public func nestedDepthStopsAtNine(): Unit {
        let lookups = ArrayList<(Int64, Array<Array<Byte>>)>()
        for (index in 0..6) {
            lookups.add((5, [m6GsubContextSubtable([[1]], [(0, index + 1)])]))
        }
        // 深度 7 的上下文引用深度 8（生效）与深度 9（停止）两条链。
        // 第 8 层先把 1 替换为 5，深度 8 的上下文需接受替换后的字形才能继续到第 9 层。
        lookups.add((5, [m6GsubContextSubtable([[1]], [(0, 9), (0, 7)])]))
        lookups.add((5, [m6GsubContextSubtable([[5]], [(0, 8)])]))
        lookups.add((1, [m6GsubSingleSubtable(5, -4)]))
        lookups.add((1, [m6GsubSingleSubtable(1, 4)]))
        let bytes = m6GsubTable("liga", lookups.toArray(), featureIndices: [0])
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let shaped = table.shapeGlyphs([1], SvgFontFeatures.parse("\"liga\" 1"), warnings)
        @Assert(shaped.glyphs[0] == 5)
        var sawDepth = false
        for (warning in warnings) {
            if (warning.contains("深度")) {
                sawDepth = true
            }
        }
        @Assert(sawDepth)
    }

    /** 不支持的 format 只 warning，不影响其他子表。 */
    @TestCase
    public func unsupportedFormatIsSkipped(): Unit {
        let w = M4ByteWriter()
        w.u16(2).u16(8).u16(1).u16(1).u16(1).u16(1).u16(0)
        let bytes = m6GsubTable("liga", [(5, [w.toArray()])])
        let warnings = ArrayList<String>()
        let parsed = m6ParseContextTable(bytes, warnings)
        @Assert(parsed.isNone())
        var sawFormat = false
        for (warning in warnings) {
            if (warning.contains("format")) {
                sawFormat = true
            }
        }
        @Assert(sawFormat)
    }

    /** 特性分组：`calt` 关闭时上下文替换不生效，打开后生效。 */
    @TestCase
    public func featureGroupingGatesContext(): Unit {
        let bytes = m6GsubTable(
            "calt",
            [
                (1, [m6GsubSingleSubtable(1, 1)]),
                (5, [m6GsubContextSubtable([[1], [2]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let warnings = ArrayList<String>()
        let table = m6ParseContextTable(bytes, warnings) ?? throw invalidValue("应解析成功")
        let off = table.shapeGlyphs([1, 2], SvgFontFeatures.parse("\"calt\" 0"), warnings)
        @Assert(off.glyphs[0] == 1)
        let on = table.shapeGlyphs([1, 2], m6AllFeatures(), warnings)
        @Assert(on.glyphs[0] == 2)
    }

    /** 渲染接线：上下文替换改变字形 advance。 */
    @TestCase
    public func rendererUsesContextSubstitution(): Unit {
        let gsub = m6GsubTable(
            "liga",
            [
                (1, [m6GsubSingleSubtable(3, 2)]),
                (5, [m6GsubContextSubtable([[3], [4]], [(0, 0)])])
            ],
            featureIndices: [1]
        )
        let font = SvgTrueTypeFont.parse(
            m5BuildLayoutTtf([500, 500, 500, 500, 500, 900], gsub: gsub)
        )
        let registry = SvgFontRegistry()
        registry.register("Ctx", font)
        let layout = m5LayoutOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><text font-family=\"Ctx\" font-size=\"10\">fi</text></svg>",
            registry
        )
        // 首字形 `f` 替换为 advance 900 的字形，`i` 保持 500。
        @Assert(layout.advance > 10.0)
    }
}
