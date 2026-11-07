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

/** 上下文替换支持的特性标签，按应用顺序排列。 */
private let GSUB_CONTEXT_FEATURES: Array<String> = ["liga", "clig", "dlig", "hlig", "calt"]

/** 整形结果：字形序列、每个字形对应的原始字符下标、被连字消费的字符下标。 */
internal class SvgGsubShapeResult {
    let glyphs: Array<Int64>
    let origins: Array<Int64>
    let removed: Array<Int64>

    init(glyphs: Array<Int64>, origins: Array<Int64>, removed: Array<Int64>) {
        this.glyphs = glyphs
        this.origins = origins
        this.removed = removed
    }
}

/** 一条上下文替换记录：在输入序列的 `sequenceIndex` 位置执行 `lookupIndex`。 */
private class SvgGsubRecord {
    let sequenceIndex: Int64
    let lookupIndex: Int64

    init(sequenceIndex: Int64, lookupIndex: Int64) {
        this.sequenceIndex = sequenceIndex
        this.lookupIndex = lookupIndex
    }
}

/**
 * Type 5 / 6 format 3 子表：首字形 coverage + 回溯 / 输入 / 前瞻 coverage 序列。
 *
 * `inputs[0]` 对应首字形，`inputs[1..]` 对应后续输入字形；回溯按由近及远排列。
 */
private class SvgGsubContextSubtable {
    let chained: Bool
    let inputs: Array<Array<Int64>>
    let backtrack: Array<Array<Int64>>
    let lookahead: Array<Array<Int64>>
    let records: Array<SvgGsubRecord>

    init(
        chained: Bool,
        inputs: Array<Array<Int64>>,
        backtrack: Array<Array<Int64>>,
        lookahead: Array<Array<Int64>>,
        records: Array<SvgGsubRecord>
    ) {
        this.chained = chained
        this.inputs = inputs
        this.backtrack = backtrack
        this.lookahead = lookahead
        this.records = records
    }

    func coversInput(state: SvgGsubApplyState, position: Int64): Bool {
        if (position < 0 || position + this.inputs.size > state.glyphs.size) {
            return false
        }
        for (index in 0..this.inputs.size) {
            if (!arrayContainsSvgGlyph(this.inputs[index], state.glyphs[position + index])) {
                return false
            }
        }
        if (position < this.backtrack.size) {
            return false
        }
        for (index in 0..this.backtrack.size) {
            if (!arrayContainsSvgGlyph(this.backtrack[index], state.glyphs[position - 1 - index])) {
                return false
            }
        }
        let lookaheadStart = position + this.inputs.size
        if (lookaheadStart + this.lookahead.size > state.glyphs.size) {
            return false
        }
        for (index in 0..this.lookahead.size) {
            if (!arrayContainsSvgGlyph(this.lookahead[index], state.glyphs[lookaheadStart + index])) {
                return false
            }
        }
        true
    }
}

/** 单个 GSUB lookup 的解析结果；只保留 Type 1 / 4 / 5 / 6 的数据。 */
private class SvgGsubLookup {
    let lookupType: Int64
    let singles = ArrayList<HashMap<Int64, Int64>>()
    let ligatures = ArrayList<HashMap<Int64, ArrayList<SvgLigatureRule>>>()
    let contexts = ArrayList<SvgGsubContextSubtable>()

    init(lookupType: Int64) {
        this.lookupType = lookupType
    }
}

/** 整形过程中的可变状态。 */
private class SvgGsubApplyState {
    let glyphs = ArrayList<Int64>()
    let origins = ArrayList<Int64>()
    let removed = ArrayList<Int64>()
    let warnings: ArrayList<String>
    var depthWarned = false

    init(warnings: ArrayList<String>) {
        this.warnings = warnings
    }

    func replace(position: Int64, glyph: Int64): Unit {
        if (position >= 0 && position < this.glyphs.size) {
            this.glyphs[position] = glyph
        }
    }

    /** 把 `position` 起的 `count` 个字形折叠为一个连字字形。 */
    func collapse(position: Int64, count: Int64, glyph: Int64): Unit {
        if (count < 2 || position + count > this.glyphs.size) {
            return
        }
        this.glyphs[position] = glyph
        for (offset in 1..count) {
            this.removed.add(this.origins[position + 1])
            this.glyphs.remove(at: position + 1)
            this.origins.remove(at: position + 1)
        }
    }
}

private func arrayContainsSvgGlyph(values: Array<Int64>, glyph: Int64): Bool {
    for (value in values) {
        if (value == glyph) {
            return true
        }
    }
    false
}

private func gsubFeatureIndices(reader: SvgTtfTableReader, scriptListOffset: Int64): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    let scriptCount = reader.u16(scriptListOffset)
    for (scriptIndex in 0..scriptCount) {
        let record = scriptListOffset + 2 + scriptIndex * 6
        let scriptOffset = scriptListOffset + reader.u16(record + 4)
        let defaultOffset = reader.u16(scriptOffset)
        if (defaultOffset != 0) {
            gsubCollectLangSys(reader, scriptOffset + defaultOffset, result)
        }
        let languageCount = reader.u16(scriptOffset + 2)
        for (languageIndex in 0..languageCount) {
            let languageRecord = scriptOffset + 4 + languageIndex * 6
            let languageOffset = scriptOffset + reader.u16(languageRecord + 4)
            gsubCollectLangSys(reader, languageOffset, result)
        }
    }
    result
}

private func gsubCollectLangSys(
    reader: SvgTtfTableReader,
    offset: Int64,
    indices: ArrayList<Int64>
): Unit {
    let count = reader.u16(offset + 4)
    for (index in 0..count) {
        let featureIndex = reader.u16(offset + 6 + index * 2)
        var seen = false
        for (value in indices) {
            if (value == featureIndex) {
                seen = true
                break
            }
        }
        if (!seen) {
            indices.add(featureIndex)
        }
    }
}

private func gsubTag(reader: SvgTtfTableReader, offset: Int64): String {
    String.fromUtf8(
        [
            UInt8(reader.u8(offset)),
            UInt8(reader.u8(offset + 1)),
            UInt8(reader.u8(offset + 2)),
            UInt8(reader.u8(offset + 3))
        ]
    )
}

/** 解析 coverage（format 1 / 2）；越界由 reader 抛 Syntax 异常，外层统一 warning。 */
private func gsubCoverage(reader: SvgTtfTableReader, offset: Int64): Array<Int64> {
    let result = ArrayList<Int64>()
    let format = reader.u16(offset)
    if (format == 1) {
        let count = reader.u16(offset + 2)
        for (index in 0..count) {
            result.add(reader.u16(offset + 4 + index * 2))
        }
    } else if (format == 2) {
        let count = reader.u16(offset + 2)
        for (index in 0..count) {
            let base = offset + 4 + index * 6
            let start = reader.u16(base)
            let end = reader.u16(base + 2)
            var glyph = start
            while (glyph <= end) {
                result.add(glyph)
                glyph++
            }
        }
    }
    result.toArray()
}

private func gsubReadCoverages(
    reader: SvgTtfTableReader,
    base: Int64,
    offsets: Array<Int64>
): Array<Array<Int64>> {
    let result = ArrayList<Array<Int64>>()
    for (offset in offsets) {
        result.add(gsubCoverage(reader, base + offset))
    }
    result.toArray()
}

/** 解析 Type 5 / 6 format 3；其他 format 返回 `None` 并由调用方 warning。 */
private func gsubParseContextSubtable(
    reader: SvgTtfTableReader,
    offset: Int64,
    chained: Bool,
    warnings: ArrayList<String>
): ?SvgGsubContextSubtable {
    let format = reader.u16(offset)
    if (format != 3) {
        warnings.add("GSUB 上下文子表 format ${format} 不受支持，已忽略")
        return Option<SvgGsubContextSubtable>.None
    }
    var cursor = offset + 2
    let backtrackOffsets = ArrayList<Int64>()
    let inputOffsets = ArrayList<Int64>()
    let lookaheadOffsets = ArrayList<Int64>()
    if (chained) {
        let backtrackCount = reader.u16(cursor)
        cursor += 2
        for (index in 0..backtrackCount) {
            backtrackOffsets.add(reader.u16(cursor + index * 2))
        }
        cursor += backtrackCount * 2
    }
    let inputCount = reader.u16(cursor)
    cursor += 2
    var substCount: Int64 = -1
    if (!chained) {
        // Context 格式 3：glyphCount 后紧跟 substCount，再是覆盖偏移。
        substCount = reader.u16(cursor)
        cursor += 2
    }
    if (inputCount == 0) {
        warnings.add("GSUB 上下文输入序列为空，已忽略")
        return Option<SvgGsubContextSubtable>.None
    }
    for (index in 0..inputCount) {
        inputOffsets.add(reader.u16(cursor + index * 2))
    }
    cursor += inputCount * 2
    if (chained) {
        let lookaheadCount = reader.u16(cursor)
        cursor += 2
        for (index in 0..lookaheadCount) {
            lookaheadOffsets.add(reader.u16(cursor + index * 2))
        }
        cursor += lookaheadCount * 2
    }
    let recordCount = if (chained) {
        let value = reader.u16(cursor)
        cursor += 2
        value
    } else {
        substCount
    }
    let records = ArrayList<SvgGsubRecord>()
    for (index in 0..recordCount) {
        let base = cursor + index * 4
        records.add(SvgGsubRecord(reader.u16(base), reader.u16(base + 2)))
    }
    let inputs = gsubReadCoverages(reader, offset, inputOffsets.toArray())
    let backtrack = gsubReadCoverages(reader, offset, backtrackOffsets.toArray())
    let lookahead = gsubReadCoverages(reader, offset, lookaheadOffsets.toArray())
    Some(SvgGsubContextSubtable(chained, inputs, backtrack, lookahead, records.toArray()))
}

/** 解析 Type 1（format 1 / 2）为 覆盖字形 → 替代字形。 */
private func gsubParseSingleSubtable(
    reader: SvgTtfTableReader,
    offset: Int64,
    warnings: ArrayList<String>
): ?HashMap<Int64, Int64> {
    let format = reader.u16(offset)
    let coverage = gsubCoverage(reader, offset + reader.u16(offset + 2))
    let map = HashMap<Int64, Int64>()
    if (format == 1) {
        let delta = reader.i16(offset + 4)
        for (glyph in coverage) {
            map[glyph] = glyph + delta
        }
        return Some(map)
    }
    if (format == 2) {
        let count = reader.u16(offset + 4)
        if (count > coverage.size) {
            warnings.add("GSUB SingleSubst 覆盖表越界，已忽略子表")
            return Option<HashMap<Int64, Int64>>.None
        }
        for (index in 0..count) {
            map[coverage[index]] = reader.u16(offset + 6 + index * 2)
        }
        return Some(map)
    }
    warnings.add("GSUB SingleSubst format ${format} 不受支持，已忽略")
    Option<HashMap<Int64, Int64>>.None
}

/** 解析 Type 4 format 1 为 首字形 → 连字规则列表。 */
private func gsubParseLigatureSubtable(
    reader: SvgTtfTableReader,
    offset: Int64,
    warnings: ArrayList<String>
): ?HashMap<Int64, ArrayList<SvgLigatureRule>> {
    if (reader.u16(offset) != 1) {
        warnings.add("GSUB LigatureSubst format 不受支持")
        return Option<HashMap<Int64, ArrayList<SvgLigatureRule>>>.None
    }
    let coverage = gsubCoverage(reader, offset + reader.u16(offset + 2))
    let setCount = reader.u16(offset + 4)
    if (setCount > coverage.size) {
        warnings.add("GSUB ligSetCount 越界，已忽略子表")
        return Option<HashMap<Int64, ArrayList<SvgLigatureRule>>>.None
    }
    let result = HashMap<Int64, ArrayList<SvgLigatureRule>>()
    for (index in 0..setCount) {
        let setOffset = offset + reader.u16(offset + 6 + index * 2)
        let ligatureCount = reader.u16(setOffset)
        for (ligIndex in 0..ligatureCount) {
            let ligatureOffset = setOffset + reader.u16(setOffset + 2 + ligIndex * 2)
            let ligGlyph = reader.u16(ligatureOffset)
            let componentCount = reader.u16(ligatureOffset + 2)
            if (componentCount < 2 || componentCount > CSS_GSUB_MAX_INPUT) {
                continue
            }
            let rest = ArrayList<Int64>()
            for (component in 1..componentCount) {
                rest.add(reader.u16(ligatureOffset + 4 + (component - 1) * 2))
            }
            let rule = SvgLigatureRule(rest.toArray(), ligGlyph)
            let first = coverage[index]
            match (result.get(first)) {
                case Some(list) => list.add(rule)
                case None =>
                    let created = ArrayList<SvgLigatureRule>()
                    created.add(rule)
                    result[first] = created
            }
        }
    }
    Some(result)
}

/** 解析一个 lookup；Type 7 沿扩展链解析到实际 lookup。 */
private func gsubParseLookup(
    reader: SvgTtfTableReader,
    lookupOffset: Int64,
    warnings: ArrayList<String>
): ?SvgGsubLookup {
    var offset = lookupOffset
    var depth: Int64 = 1
    var lookupType = reader.u16(offset)
    while (lookupType == 7) {
        if (depth >= CSS_GSUB_MAX_DEPTH) {
            warnings.add("GSUB 扩展 lookup 深度超过 ${CSS_GSUB_MAX_DEPTH}，已忽略")
            return Option<SvgGsubLookup>.None
        }
        let subTableCount = reader.u16(offset + 4)
        if (subTableCount == 0) {
            return Option<SvgGsubLookup>.None
        }
        let subOffset = offset + reader.u16(offset + 6)
        if (reader.u16(subOffset) != 1) {
            warnings.add("GSUB 扩展子表 format 不受支持")
            return Option<SvgGsubLookup>.None
        }
        lookupType = reader.u16(subOffset + 2)
        offset = subOffset + reader.u32(subOffset + 4)
        depth++
    }
    let lookup = SvgGsubLookup(lookupType)
    let subTableCount = reader.u16(offset + 4)
    for (index in 0..subTableCount) {
        let subOffset = offset + reader.u16(offset + 6 + index * 2)
        if (lookupType == 1) {
            match (gsubParseSingleSubtable(reader, subOffset, warnings)) {
                case Some(map) => lookup.singles.add(map)
                case None => ()
            }
        } else if (lookupType == 4) {
            match (gsubParseLigatureSubtable(reader, subOffset, warnings)) {
                case Some(map) => lookup.ligatures.add(map)
                case None => ()
            }
        } else if (lookupType == 5) {
            match (gsubParseContextSubtable(reader, subOffset, false, warnings)) {
                case Some(table) => lookup.contexts.add(table)
                case None => ()
            }
        } else if (lookupType == 6) {
            match (gsubParseContextSubtable(reader, subOffset, true, warnings)) {
                case Some(table) => lookup.contexts.add(table)
                case None => ()
            }
        }
    }
    Some(lookup)
}

/**
 * GSUB 上下文替换表：只处理 Type 5 / 6 的 format 3 子集，
 * 以及它们引用的 Type 1 / 4 替换 lookup。
 */
internal class SvgGsubContextTable {
    private let lookups: Array<SvgGsubLookup>
    private let featureLookups: HashMap<String, Array<Int64>>

    private init(lookups: Array<SvgGsubLookup>, featureLookups: HashMap<String, Array<Int64>>) {
        this.lookups = lookups
        this.featureLookups = featureLookups
    }

    /** 没有可用 Type 5 / 6 子表时返回 `None`，调用方退回 M5 连字路径。 */
    static func parse(
        reader: SvgTtfTableReader,
        warnings: ArrayList<String>
    ): ?SvgGsubContextTable {
        try {
            let scriptListOffset = reader.u16(4)
            let featureListOffset = reader.u16(6)
            let lookupListOffset = reader.u16(8)
            if (scriptListOffset == 0 || featureListOffset == 0 || lookupListOffset == 0 ||
                scriptListOffset >= reader.length || featureListOffset >= reader.length ||
                lookupListOffset >= reader.length) {
                return Option<SvgGsubContextTable>.None
            }
            let featureLookups = HashMap<String, Array<Int64>>()
            let featureIndices = gsubFeatureIndices(reader, scriptListOffset)
            let featureCount = reader.u16(featureListOffset)
            for (featureIndex in featureIndices) {
                if (featureIndex >= featureCount) {
                    continue
                }
                let record = featureListOffset + 2 + featureIndex * 6
                let tag = gsubTag(reader, record)
                if (!GSUB_CONTEXT_FEATURES.contains(tag) || featureLookups.contains(tag)) {
                    continue
                }
                let featureOffset = featureListOffset + reader.u16(record + 4)
                let lookupCount = reader.u16(featureOffset + 2)
                let refs = ArrayList<Int64>()
                for (position in 0..lookupCount) {
                    refs.add(reader.u16(featureOffset + 4 + position * 2))
                }
                featureLookups[tag] = refs.toArray()
            }
            let lookupCount = reader.u16(lookupListOffset)
            let lookups = ArrayList<SvgGsubLookup>()
            var hasContext = false
            for (index in 0..lookupCount) {
                let lookupOffset = lookupListOffset + reader.u16(lookupListOffset + 2 + index * 2)
                match (gsubParseLookup(reader, lookupOffset, warnings)) {
                    case Some(value) =>
                        if (value.contexts.size > 0) {
                            hasContext = true
                        }
                        lookups.add(value)
                    case None => lookups.add(SvgGsubLookup(0))
                }
            }
            if (!hasContext) {
                return Option<SvgGsubContextTable>.None
            }
            Some(SvgGsubContextTable(lookups.toArray(), featureLookups))
        } catch (error: SvgException) {
            warnings.add("GSUB 上下文表截断，已忽略 " + error.message)
            Option<SvgGsubContextTable>.None
        }
    }

    /** 按启用的特性依次执行 lookup；返回整形后的字形与来源下标。 */
    func shapeGlyphs(
        glyphs: Array<Int64>,
        features: SvgFontFeatures,
        warnings: ArrayList<String>
    ): SvgGsubShapeResult {
        let state = SvgGsubApplyState(warnings)
        for (index in 0..glyphs.size) {
            state.glyphs.add(glyphs[index])
            state.origins.add(index)
        }
        for (tag in GSUB_CONTEXT_FEATURES) {
            if (!features.enabled(tag)) {
                continue
            }
            let refs = match (this.featureLookups.get(tag)) {
                case Some(value) => value
                case None => continue
            }
            for (lookupIndex in refs) {
                this.applyLookupPass(state, lookupIndex)
            }
        }
        SvgGsubShapeResult(state.glyphs.toArray(), state.origins.toArray(), state.removed.toArray())
    }

    private func applyLookupPass(state: SvgGsubApplyState, lookupIndex: Int64): Unit {
        var position: Int64 = 0
        while (position < state.glyphs.size) {
            this.applyLookupAt(state, lookupIndex, position, 1)
            position++
        }
    }

    /** 在 `position` 执行指定 lookup；深度从特性引用的第 1 层起算。 */
    private func applyLookupAt(
        state: SvgGsubApplyState,
        lookupIndex: Int64,
        position: Int64,
        depth: Int64
    ): Unit {
        if (depth > CSS_GSUB_MAX_DEPTH) {
            if (!state.depthWarned) {
                state.warnings.add("GSUB lookup 深度超过 ${CSS_GSUB_MAX_DEPTH}，已停止后续替换")
                state.depthWarned = true
            }
            return
        }
        if (lookupIndex < 0 || lookupIndex >= this.lookups.size) {
            return
        }
        if (position < 0 || position >= state.glyphs.size) {
            return
        }
        let lookup = this.lookups[lookupIndex]
        let glyph = state.glyphs[position]
        if (lookup.lookupType == 1) {
            for (map in lookup.singles) {
                match (map.get(glyph)) {
                    case Some(value) =>
                        state.replace(position, value)
                        return
                    case None => ()
                }
            }
            return
        }
        if (lookup.lookupType == 4) {
            for (map in lookup.ligatures) {
                let rules = match (map.get(glyph)) {
                    case Some(value) => value
                    case None => continue
                }
                var best: ?SvgLigatureRule = None
                var bestCount: Int64 = 0
                for (rule in rules) {
                    let consumed = 1 + rule.rest.size
                    if (consumed > CSS_GSUB_MAX_INPUT || position + consumed > state.glyphs.size) {
                        continue
                    }
                    var matched = true
                    for (index in 0..rule.rest.size) {
                        if (state.glyphs[position + 1 + index] != rule.rest[index]) {
                            matched = false
                            break
                        }
                    }
                    if (matched && consumed > bestCount) {
                        best = Some(rule)
                        bestCount = consumed
                    }
                }
                match (best) {
                    case Some(rule) =>
                        state.collapse(position, bestCount, rule.glyph)
                        return
                    case None => ()
                }
            }
            return
        }
        if (lookup.lookupType == 5 || lookup.lookupType == 6) {
            for (table in lookup.contexts) {
                if (!arrayContainsSvgGlyph(table.inputs[0], glyph)) {
                    continue
                }
                if (!table.coversInput(state, position)) {
                    continue
                }
                for (record in table.records) {
                    this.applyLookupAt(
                        state,
                        record.lookupIndex,
                        position + record.sequenceIndex,
                        depth + 1
                    )
                }
                return
            }
        }
    }
}
