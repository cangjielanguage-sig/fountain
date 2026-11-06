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

internal let CSS_KERN_MAX_PAIRS: Int64 = 65536
internal let CSS_GPOS_MAX_PAIRS: Int64 = 65536
internal let CSS_GSUB_MAX_INPUT: Int64 = 4
internal let CSS_GSUB_MAX_DEPTH: Int64 = 8

/** FeatureList 中某个特性的 lookup 引用及其链深度（从 1 计）。 */
private class SvgLayoutLookupRef {
    let index: Int64
    let depth: Int64

    init(index: Int64, depth: Int64) {
        this.index = index
        this.depth = depth
    }
}

private func cssLayoutTag(reader: SvgTtfTableReader, offset: Int64): String {
    String.fromUtf8(
        [
            UInt8(reader.u8(offset)),
            UInt8(reader.u8(offset + 1)),
            UInt8(reader.u8(offset + 2)),
            UInt8(reader.u8(offset + 3))
        ]
    )
}

private func cssLayoutCollectLangSys(
    reader: SvgTtfTableReader,
    offset: Int64,
    featureIndices: ArrayList<Int64>
): Unit {
    let count = reader.u16(offset + 4)
    for (index in 0..count) {
        let featureIndex = reader.u16(offset + 6 + index * 2)
        if (!containsCssFeatureIndex(featureIndices, featureIndex)) {
            featureIndices.add(featureIndex)
        }
    }
}

private func containsCssFeatureIndex(indices: ArrayList<Int64>, index: Int64): Bool {
    for (value in indices) {
        if (value == index) {
            return true
        }
    }
    false
}

/** 按 ScriptList 的默认与命名 LangSys 收集启用的 FeatureList 下标。 */
private func cssLayoutFeatureIndices(
    reader: SvgTtfTableReader,
    scriptListOffset: Int64
): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    let scriptCount = reader.u16(scriptListOffset)
    for (scriptIndex in 0..scriptCount) {
        let record = scriptListOffset + 2 + scriptIndex * 6
        let scriptOffset = scriptListOffset + reader.u16(record + 4)
        let defaultOffset = reader.u16(scriptOffset)
        if (defaultOffset != 0) {
            cssLayoutCollectLangSys(reader, scriptOffset + defaultOffset, result)
        }
        let languageCount = reader.u16(scriptOffset + 2)
        for (languageIndex in 0..languageCount) {
            let languageRecord = scriptOffset + 4 + languageIndex * 6
            let languageOffset = scriptOffset + reader.u16(languageRecord + 4)
            cssLayoutCollectLangSys(reader, languageOffset, result)
        }
    }
    result
}

/**
 * 解析 ScriptList → FeatureList，收集指定特性引用的 lookup 与链深度。
 *
 * `enforceDepth` 为真时，特性引用的第 9 个及之后的 lookup 被丢弃并告警。
 */
private func cssLayoutLookupRefs(
    reader: SvgTtfTableReader,
    featureTag: String,
    label: String,
    warnings: ArrayList<String>,
    enforceDepth: Bool
): ?Array<SvgLayoutLookupRef> {
    let scriptListOffset = reader.u16(4)
    let featureListOffset = reader.u16(6)
    let lookupListOffset = reader.u16(8)
    if (scriptListOffset == 0 || featureListOffset == 0 || lookupListOffset == 0 ||
        scriptListOffset >= reader.length || featureListOffset >= reader.length ||
        lookupListOffset >= reader.length) {
        warnings.add("${label} 缺少 ScriptList / FeatureList / LookupList，已忽略")
        return None
    }
    let featureIndices = cssLayoutFeatureIndices(reader, scriptListOffset)
    let featureCount = reader.u16(featureListOffset)
    let refs = ArrayList<SvgLayoutLookupRef>()
    for (featureIndex in featureIndices) {
        if (featureIndex >= featureCount) {
            warnings.add("${label} 的 featureIndex 越界，已忽略")
            continue
        }
        let record = featureListOffset + 2 + featureIndex * 6
        if (cssLayoutTag(reader, record) != featureTag) {
            continue
        }
        let featureOffset = featureListOffset + reader.u16(record + 4)
        let lookupCount = reader.u16(featureOffset + 2)
        for (position in 0..lookupCount) {
            let depth = position + 1
            if (enforceDepth && depth > CSS_GSUB_MAX_DEPTH) {
                warnings.add("${label} lookup 深度超过 ${CSS_GSUB_MAX_DEPTH}，已停止后续替换")
                continue
            }
            refs.add(SvgLayoutLookupRef(reader.u16(featureOffset + 4 + position * 2), depth))
        }
    }
    if (refs.size == 0) {
        warnings.add("${label} 缺少 ${featureTag} 特性，已忽略")
        return None
    }
    Some(refs.toArray())
}

private func cssPairKey(left: Int64, right: Int64): Int64 {
    left * 65536 + right
}

/** `kern` 表 format 0 的字距对。 */
internal class SvgKernPairs {
    private let values = HashMap<Int64, Int64>()
    let horizontalOnly: Bool

    private init(horizontalOnly: Bool) {
        this.horizontalOnly = horizontalOnly
    }

    func adjust(left: Int64, right: Int64): Int64 {
        this.values.get(cssPairKey(left, right)) ?? 0
    }

    /** 解析水平 `kern` format 0；无水平子表或超限返回 `None`。 */
    static func parse(reader: SvgTtfTableReader, warnings: ArrayList<String>): ?SvgKernPairs {
        try {
            let version = reader.u16(0)
            if (version != 0) {
                warnings.add("kern 表版本 ${version} 不受支持，已忽略")
                return None
            }
            let subtableCount = reader.u16(2)
            let result = SvgKernPairs(true)
            var offset = 4
            var parsedAny = false
            var totalPairs: Int64 = 0
            for (_ in 0..subtableCount) {
                if (offset + 6 > reader.length) {
                    warnings.add("kern 子表截断，已忽略")
                    return None
                }
                let length = reader.u16(offset + 2)
                let coverage = reader.u16(offset + 4)
                let format = coverage >> 8
                let horizontal = (coverage & 0x0001) != 0
                if (length < 6) {
                    warnings.add("kern 子表长度非法，已忽略")
                    return None
                }
                if (format == 0 && horizontal) {
                    let pairCount = reader.u16(offset + 6)
                    totalPairs += pairCount
                    if (totalPairs > CSS_KERN_MAX_PAIRS) {
                        warnings.add("kern 表条目超过 ${CSS_KERN_MAX_PAIRS}，已忽略整表")
                        return None
                    }
                    let pairsBase = offset + 14
                    for (index in 0..pairCount) {
                        let base = pairsBase + index * 6
                        if (base + 6 > offset + length) {
                            warnings.add("kern 字距对截断，已忽略")
                            return None
                        }
                        let left = reader.u16(base)
                        let right = reader.u16(base + 2)
                        let value = reader.i16(base + 4)
                        result.values[cssPairKey(left, right)] = value
                    }
                    parsedAny = true
                }
                offset += length
            }
            if (!parsedAny) {
                warnings.add("kern 表没有可用的水平字距子表，已忽略")
                return None
            }
            Some(result)
        } catch (_: SvgException) {
            warnings.add("kern 表截断，已忽略")
            None
        }
    }
}

/** GPOS Pair Adjustment（format 1 / 2）的 x advance 调整。 */
internal class SvgGposPairs {
    let pairs = HashMap<Int64, Int64>()
    let class1 = HashMap<Int64, Int64>()
    let class2 = HashMap<Int64, Int64>()
    var classMatrix: Array<Int64> = Array<Int64>()
    var class2Count: Int64 = 0
    let covered = HashMap<Int64, Bool>()

    private init() {}

    func adjust(left: Int64, right: Int64): Int64 {
        match (this.pairs.get(cssPairKey(left, right))) {
            case Some(value) => return value
            case None => ()
        }
        if (this.classMatrix.size == 0) {
            return 0
        }
        // PairPos format 2 只对 Coverage 覆盖的左字形生效。
        if (this.covered.get(left).isNone()) {
            return 0
        }
        let firstClass = this.class1.get(left) ?? 0
        let secondClass = this.class2.get(right) ?? 0
        let index = firstClass * this.class2Count + secondClass
        if (index < 0 || index >= this.classMatrix.size) {
            return 0
        }
        this.classMatrix[index]
    }

    static func parse(reader: SvgTtfTableReader, warnings: ArrayList<String>): ?SvgGposPairs {
        try {
            let lookupListOffset = reader.u16(8)
            let refs = match (cssLayoutLookupRefs(reader, "kern", "GPOS", warnings, false)) {
                case Some(value) => value
                case None => return Option<SvgGposPairs>.None
            }
            let result = SvgGposPairs()
            let lookupCount = reader.u16(lookupListOffset)
            var parsed = false
            for (reference in refs) {
                if (reference.index >= lookupCount) {
                    warnings.add("GPOS lookupIndex 越界，已忽略")
                    continue
                }
                let lookupOffset = lookupListOffset + reader.u16(lookupListOffset + 2 + reference.index * 2)
                if (lookupOffset + 6 > reader.length) {
                    warnings.add("GPOS lookup 截断，已忽略")
                    continue
                }
                let lookupType = reader.u16(lookupOffset)
                if (lookupType != 2) {
                    continue
                }
                let subTableCount = reader.u16(lookupOffset + 4)
                for (subIndex in 0..subTableCount) {
                    let subOffset = lookupOffset + reader.u16(lookupOffset + 6 + subIndex * 2)
                    if (parseGposPairSubtable(reader, subOffset, result, warnings)) {
                        parsed = true
                    }
                }
            }
            if (!parsed) {
                return Option<SvgGposPairs>.None
            }
            Some(result)
        } catch (_: SvgException) {
            warnings.add("GPOS 表截断，已忽略")
            None
        }
    }
}

private func parseGposPairSubtable(
    reader: SvgTtfTableReader,
    offset: Int64,
    target: SvgGposPairs,
    warnings: ArrayList<String>
): Bool {
    if (offset + 10 > reader.length) {
        warnings.add("GPOS PairPos 子表截断，已忽略")
        return false
    }
    let format = reader.u16(offset)
    let coverageOffset = offset + reader.u16(offset + 2)
    let valueFormat1 = reader.u16(offset + 4)
    let valueFormat2 = reader.u16(offset + 6)
    if ((valueFormat1 & 0x0004) == 0) {
        return false
    }
    let coverage = parseGposCoverage(reader, coverageOffset)
    if (format == 1) {
        let pairSetCount = reader.u16(offset + 8)
        if (pairSetCount > coverage.size) {
            warnings.add("GPOS pairSetCount 越界，已忽略子表")
            return false
        }
        var parsed = false
        for (index in 0..pairSetCount) {
            let pairSetOffset = offset + reader.u16(offset + 10 + index * 2)
            let pairCount = reader.u16(pairSetOffset)
            let recordSize = 2 + valueRecordSize(valueFormat1) + valueRecordSize(valueFormat2)
            for (pairIndex in 0..pairCount) {
                if (pairCount > CSS_GPOS_MAX_PAIRS) {
                    warnings.add("GPOS pair 集超过 ${CSS_GPOS_MAX_PAIRS}，已忽略子表")
                    return parsed
                }
                let base = pairSetOffset + 2 + pairIndex * recordSize
                if (base + recordSize > reader.length) {
                    warnings.add("GPOS pair 记录截断，已忽略子表")
                    return parsed
                }
                let second = reader.u16(base)
                let xAdvance = readGposXAdvance(reader, base + 2, valueFormat1)
                target.pairs[cssPairKey(coverage[index], second)] = xAdvance
                parsed = true
            }
        }
        return parsed
    }
    if (format == 2) {
        let classDef1Offset = offset + reader.u16(offset + 8)
        let classDef2Offset = offset + reader.u16(offset + 10)
        let class1Count = reader.u16(offset + 12)
        let class2Count = reader.u16(offset + 14)
        let classes1 = parseGposClassDef(reader, classDef1Offset)
        let classes2 = parseGposClassDef(reader, classDef2Offset)
        if (class1Count * class2Count > CSS_GPOS_MAX_PAIRS) {
            warnings.add("GPOS class pair 超过 ${CSS_GPOS_MAX_PAIRS}，已忽略子表")
            return false
        }
        let recordSize = valueRecordSize(valueFormat1) + valueRecordSize(valueFormat2)
        let matrixBase = offset + 16
        let matrix = ArrayList<Int64>()
        for (firstClass in 0..class1Count) {
            for (secondClass in 0..class2Count) {
                let base = matrixBase + (firstClass * class2Count + secondClass) * recordSize
                if (base + recordSize > reader.length) {
                    warnings.add("GPOS class 矩阵截断，已忽略子表")
                    return false
                }
                matrix.add(readGposXAdvance(reader, base, valueFormat1))
            }
        }
        for ((glyph, value) in classes1) {
            target.class1[glyph] = value
        }
        for ((glyph, value) in classes2) {
            target.class2[glyph] = value
        }
        for (glyph in coverage) {
            target.covered[glyph] = true
        }
        target.classMatrix = matrix.toArray()
        target.class2Count = class2Count
        return true
    }
    warnings.add("GPOS PairPos format ${format} 不受支持")
    false
}

private func valueRecordSize(format: Int64): Int64 {
    var size: Int64 = 0
    var bit: Int64 = 0
    while (bit < 8) {
        if ((format & (1 << bit)) != 0) {
            size += 2
        }
        bit++
    }
    size
}

private func readGposXAdvance(reader: SvgTtfTableReader, base: Int64, format: Int64): Int64 {
    var offset = base
    var bit: Int64 = 0
    while (bit < 8) {
        if ((format & (1 << bit)) != 0) {
            if (bit == 2) {
                return reader.i16(offset)
            }
            offset += 2
        }
        bit++
    }
    0
}

private func parseGposCoverage(reader: SvgTtfTableReader, offset: Int64): Array<Int64> {
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

private func parseGposClassDef(reader: SvgTtfTableReader, offset: Int64): HashMap<Int64, Int64> {
    let result = HashMap<Int64, Int64>()
    let format = reader.u16(offset)
    if (format == 1) {
        let start = reader.u16(offset + 2)
        let count = reader.u16(offset + 4)
        for (index in 0..count) {
            result[start + index] = reader.u16(offset + 6 + index * 2)
        }
    } else if (format == 2) {
        let count = reader.u16(offset + 2)
        for (index in 0..count) {
            let base = offset + 4 + index * 6
            let start = reader.u16(base)
            let end = reader.u16(base + 2)
            let value = reader.u16(base + 4)
            var glyph = start
            while (glyph <= end) {
                result[glyph] = value
                glyph++
            }
        }
    }
    result
}

/** 一个连字规则：首个字形之后的组件序列与替换字形。 */
internal class SvgLigatureRule {
    let rest: Array<Int64>
    let glyph: Int64

    init(rest: Array<Int64>, glyph: Int64) {
        this.rest = rest
        this.glyph = glyph
    }
}

/** GSUB Lookup Type 4（`liga`，format 1）的连字表。 */
internal class SvgGsubLigatures {
    let rules = HashMap<Int64, ArrayList<SvgLigatureRule>>()

    private init() {}

    /** 在 `start` 处匹配最长连字，返回 `(连字字形, 消费字形数)`。 */
    func findLigature(glyphs: Array<Int64>, start: Int64): ?(Int64, Int64) {
        if (start < 0 || start >= glyphs.size) {
            return None
        }
        let list = match (this.rules.get(glyphs[start])) {
            case Some(value) => value
            case None => return None
        }
        var best: ?(Int64, Int64) = None
        for (rule in list) {
            let consumed = 1 + rule.rest.size
            if (consumed > CSS_GSUB_MAX_INPUT || start + consumed > glyphs.size) {
                continue
            }
            var matched = true
            for (index in 0..rule.rest.size) {
                if (glyphs[start + 1 + index] != rule.rest[index]) {
                    matched = false
                    break
                }
            }
            if (!matched) {
                continue
            }
            match (best) {
                case Some(value) => if (consumed > value[1]) {
                    best = Some((rule.glyph, consumed))
                }
                case None => best = Some((rule.glyph, consumed))
            }
        }
        best
    }

    static func parse(reader: SvgTtfTableReader, warnings: ArrayList<String>): ?SvgGsubLigatures {
        try {
            let lookupListOffset = reader.u16(8)
            let refs = match (cssLayoutLookupRefs(reader, "liga", "GSUB", warnings, true)) {
                case Some(value) => value
                case None => return Option<SvgGsubLigatures>.None
            }
            let result = SvgGsubLigatures()
            let lookupCount = reader.u16(lookupListOffset)
            var parsed = false
            for (reference in refs) {
                if (reference.index >= lookupCount) {
                    warnings.add("GSUB lookupIndex 越界，已忽略")
                    continue
                }
                let lookupOffset = lookupListOffset + reader.u16(lookupListOffset + 2 + reference.index * 2)
                if (lookupOffset + 6 > reader.length) {
                    warnings.add("GSUB lookup 截断，已忽略")
                    continue
                }
                if (reader.u16(lookupOffset) != 4) {
                    continue
                }
                let subTableCount = reader.u16(lookupOffset + 4)
                for (subIndex in 0..subTableCount) {
                    let subOffset = lookupOffset + reader.u16(lookupOffset + 6 + subIndex * 2)
                    if (parseGsubLigatureSubtable(reader, subOffset, result, warnings)) {
                        parsed = true
                    }
                }
            }
            if (!parsed) {
                return Option<SvgGsubLigatures>.None
            }
            Some(result)
        } catch (_: SvgException) {
            warnings.add("GSUB 表截断，已忽略")
            None
        }
    }
}

private func parseGsubLigatureSubtable(
    reader: SvgTtfTableReader,
    offset: Int64,
    target: SvgGsubLigatures,
    warnings: ArrayList<String>
): Bool {
    if (offset + 6 > reader.length) {
        warnings.add("GSUB LigatureSubst 子表截断，已忽略")
        return false
    }
    if (reader.u16(offset) != 1) {
        warnings.add("GSUB LigatureSubst format 不受支持")
        return false
    }
    let coverageOffset = offset + reader.u16(offset + 2)
    let ligSetCount = reader.u16(offset + 4)
    let coverage = parseGposCoverage(reader, coverageOffset)
    if (ligSetCount > coverage.size) {
        warnings.add("GSUB ligSetCount 越界，已忽略子表")
        return false
    }
    var parsed = false
    for (index in 0..ligSetCount) {
        let setOffset = offset + reader.u16(offset + 6 + index * 2)
        let ligatureCount = reader.u16(setOffset)
        for (ligIndex in 0..ligatureCount) {
            let base = setOffset + 2 + ligIndex * 2
            if (base + 2 > reader.length) {
                warnings.add("GSUB 连字集截断，已忽略子表")
                return parsed
            }
            let ligatureOffset = setOffset + reader.u16(base)
            if (ligatureOffset + 4 > reader.length) {
                warnings.add("GSUB 连字记录截断，已忽略子表")
                return parsed
            }
            let ligGlyph = reader.u16(ligatureOffset)
            let componentCount = reader.u16(ligatureOffset + 2)
            if (componentCount < 2) {
                continue
            }
            if (componentCount > CSS_GSUB_MAX_INPUT) {
                warnings.add("GSUB 连字输入超过 ${CSS_GSUB_MAX_INPUT} 个字形，已忽略")
                continue
            }
            let rest = ArrayList<Int64>()
            var valid = true
            for (componentIndex in 1..componentCount) {
                let componentPos = ligatureOffset + 4 + (componentIndex - 1) * 2
                if (componentPos + 2 > reader.length) {
                    valid = false
                    break
                }
                rest.add(reader.u16(componentPos))
            }
            if (!valid) {
                warnings.add("GSUB 连字组件截断，已忽略")
                continue
            }
            let first = coverage[index]
            let entry = SvgLigatureRule(rest.toArray(), ligGlyph)
            match (target.rules.get(first)) {
                case Some(list) => list.add(entry)
                case None =>
                    let created = ArrayList<SvgLigatureRule>()
                    created.add(entry)
                    target.rules[first] = created
            }
            parsed = true
        }
    }
    parsed
}
