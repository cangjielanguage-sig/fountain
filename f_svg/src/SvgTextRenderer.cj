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
import fountain::f_base.*

/** 布局后的一个字。 */
public class SvgTextGlyph {
    public let codePoint: Int64
    public let x: Float64
    public let y: Float64
    public let advance: Float64
    public let fontSize: Float64
    public let path: ?SvgPathData
    /** 字形旋转角（度），由 textPath 切线与 rotate 列表叠加。 */
    public let angle: Float64
    /** 字形 ascent，用于装饰线定位。 */
    public let ascent: Float64
    /** 字形 descent，用于 `text-underline-position: under`。 */
    public let descent: Float64
    /** 该字形生效的装饰线（祖先传播后的结果）。 */
    public let decoration: SvgTextDecoration
    /** 装饰线完整规格（线型 / 颜色 / 厚度 / 下划线位置）。 */
    internal let decorationSpec: SvgDecorationStyle

    internal init(
        codePoint: Int64,
        x: Float64,
        y: Float64,
        advance: Float64,
        fontSize: Float64,
        path: ?SvgPathData,
        angle!: Float64 = 0.0,
        ascent!: Float64 = 0.0,
        descent!: Float64 = 0.0,
        decoration!: SvgTextDecoration = SvgTextDecoration.none,
        decorationSpec!: ?SvgDecorationStyle = None
    ) {
        this.codePoint = codePoint
        this.x = x
        this.y = y
        this.advance = advance
        this.fontSize = fontSize
        this.path = path
        this.angle = angle
        this.ascent = ascent
        this.descent = descent
        this.decoration = decoration
        this.decorationSpec = decorationSpec ?? SvgDecorationStyle(lines: decoration)
    }
}

/** 单个字形的装饰线及其包围盒（用于渐变按字形起点取样）。 */
internal class SvgDecorationRun {
    let path: SvgPathData
    let bounds: SvgBounds
    /** 显式 `text-decoration-color`；`None` 沿用文本填充。 */
    let color: ?SvgColor
    let thickness: Float64

    init(path: SvgPathData, bounds: SvgBounds, color!: ?SvgColor = None, thickness!: Float64 = 0.0) {
        this.path = path
        this.bounds = bounds
        this.color = color
        this.thickness = thickness
    }
}

/** 单次渲染内复用的布局结果及其产生的 warning。 */
internal class SvgCachedTextLayout {
    let layout: SvgTextLayout
    let warnings: Array<String>

    init(layout: SvgTextLayout, warnings: Array<String>) {
        this.layout = layout
        this.warnings = warnings
    }
}

/**
 * 单次渲染的文本布局缓存。
 *
 * 键包含元素身份、计算样式树版本与根元素身份；缓存随渲染树构建器创建，
 * 由 `SvgDisplayList` 持有并在光栅化阶段复用，不跨渲染。
 */
internal class SvgTextLayoutCache {
    private let entries = HashMap<String, SvgCachedTextLayout>()

    func get(key: String): ?SvgCachedTextLayout {
        this.entries.get(key)
    }

    func put(key: String, entry: SvgCachedTextLayout): Unit {
        this.entries[key] = entry
    }
}

/** 文本布局结果。 */
public class SvgTextLayout {
    public let glyphs: Array<SvgTextGlyph>
    public let advance: Float64
    public let bounds: ?SvgBounds
    /** 任一非空白字符缺少字形；占位框仍会生成，供渲染降级使用。 */
    internal let missingGlyph: Bool

    internal init(glyphs: Array<SvgTextGlyph>, advance: Float64, bounds: ?SvgBounds, missingGlyph: Bool) {
        this.glyphs = glyphs
        this.advance = advance
        this.bounds = bounds
        this.missingGlyph = missingGlyph
    }
}

private class SvgTextState {
    let fontSize: Float64
    let family: String
    let weight: String
    let style: String
    let letterSpacing: Float64
    let wordSpacing: Float64
    let dominant: SvgDominantBaseline
    let alignment: SvgAlignmentBaseline
    let shift: SvgBaselineShift
    let decoration: SvgTextDecoration
    let decorationSpec: SvgDecorationStyle
    let stretch: Float64
    let direction: SvgDirection
    let unicodeBidi: SvgUnicodeBidi

    init(
        fontSize: Float64,
        family: String,
        weight: String,
        style: String,
        letterSpacing: Float64,
        wordSpacing: Float64,
        dominant!: SvgDominantBaseline = SvgDominantBaseline.Auto,
        alignment!: SvgAlignmentBaseline = SvgAlignmentBaseline.Auto,
        shift!: SvgBaselineShift = SvgBaselineShift.Baseline,
        decoration!: SvgTextDecoration = SvgTextDecoration.none,
        decorationSpec!: ?SvgDecorationStyle = None,
        stretch!: Float64 = 100.0,
        direction!: SvgDirection = SvgDirection.Ltr,
        unicodeBidi!: SvgUnicodeBidi = SvgUnicodeBidi.Normal
    ) {
        this.fontSize = fontSize
        this.family = family
        this.weight = weight
        this.style = style
        this.letterSpacing = letterSpacing
        this.wordSpacing = wordSpacing
        this.dominant = dominant
        this.alignment = alignment
        this.shift = shift
        this.decoration = decoration
        this.decorationSpec = decorationSpec ?? SvgDecorationStyle(lines: decoration)
        this.stretch = stretch
        this.direction = direction
        this.unicodeBidi = unicodeBidi
    }
}

private class SvgTextChar {
    let codePoint: Int64
    let fontSize: Float64
    let family: String
    let weight: String
    let style: String
    let letterSpacing: Float64
    let wordSpacing: Float64
    let dominant: SvgDominantBaseline
    let alignment: SvgAlignmentBaseline
    let shift: SvgBaselineShift
    let parentDominant: SvgDominantBaseline
    let isRoot: Bool
    let decoration: SvgTextDecoration
    let decorationSpec: SvgDecorationStyle
    let stretch: Float64
    /** 实际命中的字体 stretch；用于判断是否需要合成缩放。 */
    var matchedStretch: Float64 = 100.0
    let direction: SvgDirection
    let unicodeBidi: SvgUnicodeBidi
    var xOverride: ?Float64 = None
    var yBase: Float64 = 0.0
    var dx: Float64 = 0.0
    var dy: Float64 = 0.0
    var xExplicit: Bool = false
    var yExplicit: Bool = false
    /** 逻辑字符绑定的 rotate 列表项。 */
    var rotation: Float64 = 0.0
    /** 被 GSUB 连字消费；不参与定位与输出。 */
    var consumed: Bool = false
    /** 整形后的字形 id（TTF）；未整形时为 cmap 映射值。 */
    var glyphId: Int64 = 0

    init(
        codePoint: Int64,
        state: SvgTextState,
        parentDominant!: SvgDominantBaseline = SvgDominantBaseline.Auto,
        isRoot!: Bool = false
    ) {
        this.codePoint = codePoint
        this.fontSize = state.fontSize
        this.family = state.family
        this.weight = state.weight
        this.style = state.style
        this.letterSpacing = state.letterSpacing
        this.wordSpacing = state.wordSpacing
        this.dominant = state.dominant
        this.alignment = state.alignment
        this.shift = state.shift
        this.parentDominant = parentDominant
        this.isRoot = isRoot
        this.decoration = state.decoration
        this.decorationSpec = state.decorationSpec
        this.stretch = state.stretch
        this.direction = state.direction
        this.unicodeBidi = state.unicodeBidi
    }

    /** 复制一份并替换码点（用于双向镜像）。 */
    func copyWithCodePoint(codePoint: Int64): SvgTextChar {
        let state = SvgTextState(
            this.fontSize,
            this.family,
            this.weight,
            this.style,
            this.letterSpacing,
            this.wordSpacing,
            dominant: this.dominant,
            alignment: this.alignment,
            shift: this.shift,
            decoration: this.decoration,
            decorationSpec: this.decorationSpec,
            stretch: this.stretch,
            direction: this.direction,
            unicodeBidi: this.unicodeBidi
        )
        let copy = SvgTextChar(
            codePoint,
            state,
            parentDominant: this.parentDominant,
            isRoot: this.isRoot
        )
        copy.xOverride = this.xOverride
        copy.yBase = this.yBase
        copy.dx = this.dx
        copy.dy = this.dy
        copy.xExplicit = this.xExplicit
        copy.yExplicit = this.yExplicit
        copy.rotation = this.rotation
        copy.consumed = this.consumed
        copy.glyphId = this.glyphId
        copy.matchedStretch = this.matchedStretch
        copy
    }
}

private class SvgGlyphEntry {
    let path: ?SvgPathData
    let missing: Bool

    init(path: ?SvgPathData, missing: Bool) {
        this.path = path
        this.missing = missing
    }
}

/**
 * 文本布局与字形路径输出。
 *
 * 按字符 advance 累加，支持 x/y 列表、dx/dy、letter/word-spacing、text-anchor、
 * textLength + lengthAdjust、tspan 字号覆盖；字形路径按字体 + 字号 + 字符缓存。
 */
public class SvgTextRenderer {
    public let warnings = ArrayList<String>()
    private let registry: SvgFontRegistry
    private let glyphCache = HashMap<String, SvgGlyphEntry>()
    private let layoutCache: ?SvgTextLayoutCache

    public init(registry!: SvgFontRegistry = SvgFontRegistry.defaultRegistry()) {
        this.registry = registry
        this.layoutCache = None
    }

    internal init(registry!: SvgFontRegistry, layoutCache!: ?SvgTextLayoutCache) {
        this.registry = registry
        this.layoutCache = layoutCache
    }

    public func layout(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): SvgTextLayout {
        match ((this.layoutCache, styles)) {
            case (Some(cache), Some(styleTree)) =>
                let rootIdentity = match (root) {
                    case Some(value) => value.identity
                    case None => 0
                }
                let key = "${text.identity}|${styleTree.version}|${rootIdentity}"
                match (cache.get(key)) {
                    case Some(entry) =>
                        for (warning in entry.warnings) {
                            this.warnings.add(warning)
                        }
                        return entry.layout
                    case None =>
                        let start = this.warnings.size
                        let value = this.layoutUncached(
                            text,
                            style: style,
                            root: root,
                            styles: styles
                        )
                        let produced = ArrayList<String>()
                        for (index in start..this.warnings.size) {
                            produced.add(this.warnings[index])
                        }
                        cache.put(key, SvgCachedTextLayout(value, produced.toArray()))
                        return value
                }
            case _ => return this.layoutUncached(text, style: style, root: root, styles: styles)
        }
    }

    private func layoutUncached(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): SvgTextLayout {
        let rootDecoration = resolveSvgDecorationStyle(text, style, styles)
        let rootState = SvgTextState(
            style.fontSize().value,
            style.fontFamily(),
            style.fontWeight(),
            style.fontStyle(),
            style.letterSpacing().value,
            style.wordSpacing().value,
            dominant: style.dominantBaseline(),
            alignment: SvgAlignmentBaseline.Auto,
            shift: style.baselineShift(),
            decoration: rootDecoration.lines,
            decorationSpec: rootDecoration,
            stretch: style.fontStretch().percentage(),
            direction: style.direction(),
            unicodeBidi: style.unicodeBidi()
        )
        var chars = ArrayList<SvgTextChar>()
        collectSvgTextChars(
            text,
            rootState,
            chars,
            this.warnings,
            parentDominant: style.dominantBaseline(),
            rootLevel: true,
            styles: styles
        )
        applyRootTextAttributes(text, chars)

        let textPathElement = findTextPathElement(text)
        let rotationSource = match (textPathElement) {
            case Some(pathElement) =>
                if (pathElement.attr("rotate").isSome()) {
                    pathElement
                } else {
                    text
                }
            case None => text
        }
        let location = "元素「${svgElementPath(root, rotationSource)}」"
        let rotations = resolveTextRotations(
            rotationSource,
            chars.size,
            this.warnings,
            location: location
        )
        for (index in 0..chars.size) {
            chars[index].rotation = rotations[index]
        }

        var count = chars.size
        var advances = ArrayList<Float64>()
        var paths = ArrayList<?SvgPathData>()
        var baselineOffsets = ArrayList<Float64>()
        var ascentValues = ArrayList<Float64>()
        var resolvedFonts = ArrayList<Option<SvgFont>>()
        var missingGlyph = false
        for (index in 0..count) {
            let char = chars[index]
            let resolved = this.registry.resolveDetailed(
                char.family,
                char.weight,
                char.style,
                stretch: char.stretch
            )
            let font = resolved.font
            chars[index].matchedStretch = resolved.stretch
            resolvedFonts.add(font)
            match (font) {
                case Some(value) =>
                    advances.add(value.advance(char.codePoint, char.fontSize))
                    let entry = this.glyphEntry(value, char)
                    if (entry.missing) {
                        missingGlyph = true
                    }
                    paths.add(entry.path)
                    let ascent = charFontAscent(value, char)
                    ascentValues.add(ascent)
                    baselineOffsets.add(
                        baselineOffsetFor(char, ascent, charFontDescent(value, char))
                    )
                    match (value) {
                        case truetype: SvgTrueTypeFont =>
                            chars[index].glyphId = truetype.glyphIndexOrZero(char.codePoint)
                        case _ => ()
                    }
                case None =>
                    missingGlyph = true
                    this.warnings.add("未找到字体「${char.family}」，使用占位字形")
                    advances.add(char.fontSize * 0.5)
                    paths.add(placeholderGlyph(char.fontSize, char.fontSize * 0.5))
                    ascentValues.add(char.fontSize * 0.8)
                    baselineOffsets.add(
                        baselineOffsetFor(char, char.fontSize * 0.8, char.fontSize * 0.2)
                    )
            }
        }

        // 先 GSUB 连字，再 kern / GPOS 字距；optimizeSpeed 关闭两者。
        if (style.textRendering() != SvgTextRendering.OptimizeSpeed) {
            applyFontLigatures(chars, resolvedFonts, advances, paths)
            applyFontContextShaping(
                chars,
                resolvedFonts,
                advances,
                paths,
                style,
                this.warnings
            )
        }
        let shapedChars = ArrayList<SvgTextChar>()
        let shapedAdvances = ArrayList<Float64>()
        let shapedPaths = ArrayList<?SvgPathData>()
        let shapedBaselines = ArrayList<Float64>()
        let shapedAscents = ArrayList<Float64>()
        let shapedFonts = ArrayList<Option<SvgFont>>()
        for (index in 0..count) {
            if (chars[index].consumed) {
                continue
            }
            shapedChars.add(chars[index])
            shapedAdvances.add(advances[index])
            shapedPaths.add(paths[index])
            shapedBaselines.add(baselineOffsets[index])
            shapedAscents.add(ascentValues[index])
            shapedFonts.add(resolvedFonts[index])
        }
        chars = shapedChars
        advances = shapedAdvances
        paths = shapedPaths
        baselineOffsets = shapedBaselines
        ascentValues = shapedAscents
        resolvedFonts = shapedFonts
        count = chars.size

        if (style.textRendering() != SvgTextRendering.OptimizeSpeed) {
            applyFontKerning(chars, resolvedFonts, advances, style)
        }
        applyFontStretchSynthesis(chars, advances, paths)
        applySmallCaps(chars, resolvedFonts, advances, paths, style, this.warnings)
        applyFontSizeAdjust(chars, resolvedFonts, advances, paths, style, this.warnings)

        if (shouldReorderBidi(style, chars)) {
            let arrangement = bidiArrangement(chars, style)
            chars = permuteBidiChars(chars, arrangement)
            advances = permuteBidiValues(advances, arrangement.order)
            paths = permuteBidiOptionalPaths(paths, arrangement.order)
            baselineOffsets = permuteBidiValues(baselineOffsets, arrangement.order)
            ascentValues = permuteBidiValues(ascentValues, arrangement.order)
            resolvedFonts = permuteBidiFonts(resolvedFonts, arrangement.order)
            // 镜像后的字符需要按新码点重新取字形路径与推进量。
            for (visual in 0..count) {
                let logical = arrangement.order[visual]
                if (arrangement.levels[logical] % 2 == 0) {
                    continue
                }
                let char = chars[visual]
                match (resolvedFonts[visual]) {
                    case Some(font) =>
                        advances[visual] = font.advance(char.codePoint, char.fontSize)
                        let entry = this.glyphEntry(font, char)
                        paths[visual] = entry.path
                        if (entry.missing) {
                            missingGlyph = true
                        }
                        match (font) {
                            case truetype: SvgTrueTypeFont =>
                                chars[visual].glyphId = truetype.glyphIndexOrZero(char.codePoint)
                            case _ => ()
                        }
                    case None => ()
                }
            }
        }

        let target = match (text.textLength) {
            case Some(value) => value.value
            case None => 0.0
        }
        let adjust = text.lengthAdjust ?? SvgLengthAdjust.Spacing
        var scaleX = 1.0
        var extra = 0.0
        var natural = 0.0
        for (index in 0..count) {
            natural += advances[index]
            if (index < count - 1) {
                natural += chars[index].letterSpacing
                if (chars[index].codePoint == 32) {
                    natural += chars[index].wordSpacing
                }
            }
        }
        if (target > 0.0 && natural > 0.0) {
            if (adjust == SvgLengthAdjust.SpacingAndGlyphs) {
                scaleX = target / natural
            } else if (count > 1) {
                extra = (target - natural) / Float64(count - 1)
            }
        }

        let positions = ArrayList<Float64>()
        var pen = 0.0
        for (index in 0..count) {
            let char = chars[index]
            match (char.xOverride) {
                case Some(value) => pen = value
                case None => pen += char.dx
            }
            positions.add(pen)
            pen += advances[index] * scaleX
            if (index < count - 1) {
                pen += char.letterSpacing + extra
                if (char.codePoint == 32) {
                    pen += char.wordSpacing
                }
            }
        }
        let total = pen
        let anchorOffset = match (style.textAnchor()) {
            case SvgTextAnchor.Start => 0.0
            case SvgTextAnchor.Middle => -total / 2.0
            case SvgTextAnchor.End => -total
        }

        var placements: ?Array<SvgTextPlacement> = None
        let writingMode = style.writingMode()
        let vertical = writingMode.isVertical() && textPathElement.isNone()
        if (writingMode.isVertical() && textPathElement.isSome()) {
            this.warnings.add("${location} writing-mode 与 textPath 同时出现，已忽略 writing-mode")
        }
        let columnPositions = ArrayList<Float64>()
        let verticalPositions = ArrayList<Float64>()
        var verticalTotal = 0.0
        var verticalAnchor = 0.0
        if (vertical) {
            let logicalColumns = ArrayList<Float64>()
            for (index in 0..count) {
                let column = chars[index].xOverride ?? 0.0
                if (!containsTextColumn(logicalColumns, column)) {
                    logicalColumns.add(column)
                }
            }
            let sortedColumns = ArrayList<Float64>()
            let remaining = ArrayList<Float64>()
            for (column in logicalColumns) {
                remaining.add(column)
            }
            while (remaining.size > 0) {
                var minimum = 0
                for (position in 1..remaining.size) {
                    if (remaining[position] < remaining[minimum]) {
                        minimum = position
                    }
                }
                sortedColumns.add(remaining[minimum])
                remaining.remove(at: minimum)
            }
            let columnPens = Array<Float64>(sortedColumns.size, repeat: 0.0)
            let rtlColumns = style.direction() == SvgDirection.Rtl
            for (index in 0..count) {
                let key = chars[index].xOverride ?? 0.0
                let columnRank = textColumnIndex(sortedColumns, key)
                let visualIndex = if (rtlColumns) {
                    sortedColumns.size - 1 - columnRank
                } else {
                    columnRank
                }
                columnPositions.add(sortedColumns[visualIndex])
                verticalPositions.add(columnPens[visualIndex])
                columnPens[visualIndex] += advances[index] * scaleX
                if (index < count - 1) {
                    columnPens[visualIndex] += chars[index].letterSpacing + extra
                    if (chars[index].codePoint == 32) {
                        columnPens[visualIndex] += chars[index].wordSpacing
                    }
                }
            }
            for (value in columnPens) {
                if (value > verticalTotal) {
                    verticalTotal = value
                }
            }
            verticalAnchor = match (style.textAnchor()) {
                case SvgTextAnchor.Start => 0.0
                case SvgTextAnchor.Middle => -verticalTotal / 2.0
                case SvgTextAnchor.End => -verticalTotal
            }
        }
        var glyphScaleX = scaleX
        var pathScaleX = scaleX
        match (textPathElement) {
            case Some(pathElement) =>
                match (resolveTextPathData(pathElement, root)) {
                    case Some(pathData) =>
                        let pathLengthRatio = SvgPathLength.ratio(
                            pathElement,
                            pathData.totalLength(),
                            this.warnings
                        )
                        let advanceArray = Array<Float64>(count, repeat: 0.0)
                        for (index in 0..count) {
                            advanceArray[index] = advances[index] * scaleX * pathLengthRatio
                        }
                        let pathLayout = SvgTextPathLayout()
                        let sideValue = SvgTextPathSide.fromNameOrWarn(
                            pathElement.attr("side"),
                            this.warnings,
                            "${location} textPath side"
                        )
                        let methodValue = SvgTextPathMethod.fromNameOrWarn(
                            pathElement.attr("method"),
                            this.warnings,
                            "${location} textPath method"
                        )
                        let spacingValue = SvgTextPathSpacing.fromNameOrWarn(
                            pathElement.attr("spacing"),
                            this.warnings,
                            "${location} textPath spacing"
                        )
                        let sideOffsets = Array<Float64>(count, repeat: 0.0)
                        if (pathElement.attr("side").isSome()) {
                            for (index in 0..count) {
                                sideOffsets[index] = 0.5 * chars[index].fontSize
                            }
                        }
                        let dxOffsets = Array<Float64>(count, repeat: 0.0)
                        for (index in 0..count) {
                            dxOffsets[index] = chars[index].dx
                        }
                        let letterSpacings = Array<Float64>(count, repeat: 0.0)
                        for (index in 0..count) {
                            letterSpacings[index] = chars[index].letterSpacing
                        }
                        let placed = pathLayout.place(
                            advanceArray,
                            pathData,
                            pathElement.startOffset ?? SvgLength(0.0),
                            style.textAnchor(),
                            side: sideValue,
                            method: methodValue,
                            spacing: spacingValue,
                            sideOffsets: sideOffsets,
                            dxOffsets: dxOffsets,
                            letterSpacings: letterSpacings,
                            pathLengthRatio: pathLengthRatio
                        )
                        glyphScaleX = scaleX * pathLayout.stretchScale
                        pathScaleX = glyphScaleX
                        for (warning in pathLayout.warnings) {
                            this.warnings.add("${location} textPath：${warning}")
                        }
                        if (placed.size == 0 && count > 0) {
                            if (pathLayout.pathEmpty) {
                                this.warnings.add("${location} textPath 的路径为空，降级为普通文本")
                            } else {
                                // 路径有效但所有字形都被截断：保持空排版，不再退化为水平文本。
                                placements = Some(placed)
                            }
                        } else {
                            placements = Some(placed)
                        }
                    case None =>
                        this.warnings.add("${location} textPath 的路径缺失或为空，降级为普通文本")
                }
            case None => ()
        }

        let glyphs = ArrayList<SvgTextGlyph>()
        var bounds = SvgBounds.empty()
        var hasBounds = false
        for (index in 0..count) {
            let char = chars[index]
            var path = paths[index]
            if (pathScaleX != 1.0) {
                path = match (path) {
                    case Some(value) => Some(scalePathX(value, pathScaleX))
                    case None => None
                }
            }
            var x = positions[index] + anchorOffset
            var y = char.yBase + char.dy + baselineOffsets[index]
            var angle = char.rotation
            match (placements) {
                case Some(placed) =>
                    if (index >= placed.size) {
                        continue
                    }
                    x = placed[index].originX
                    y = placed[index].originY + baselineOffsets[index]
                    angle = placed[index].angle + char.rotation
                case None => ()
            }
            if (vertical) {
                x = columnPositions[index]
                y = char.yBase + char.dy + verticalPositions[index] + verticalAnchor +
                    baselineOffsets[index]
                angle = char.rotation + 90.0
            }
            glyphs.add(
                SvgTextGlyph(
                    char.codePoint,
                    x,
                    y,
                    advances[index] * glyphScaleX,
                    char.fontSize,
                    path,
                    angle: angle,
                    ascent: ascentValues[index],
                    descent: match (resolvedFonts[index]) {
                        case Some(font) => charFontDescent(font, char)
                        case None => char.fontSize * 0.2
                    },
                    decoration: char.decoration,
                    decorationSpec: char.decorationSpec
                )
            )
            match (path) {
                case Some(value) =>
                    match (pathDataBounds(value)) {
                        case Some(glyphBox) =>
                            bounds = bounds.union(
                                SvgBounds(glyphBox.x + x, glyphBox.y + y, glyphBox.width, glyphBox.height)
                            )
                            hasBounds = true
                        case None => ()
                    }
                case None => ()
            }
        }
        let resultBounds: ?SvgBounds = if (hasBounds) { Some(bounds) } else { None }
        SvgTextLayout(glyphs.toArray(), total, resultBounds, missingGlyph)
    }

    /** 布局结果中是否存在装饰线；复用缓存，不额外排版。 */
    internal func hasDecoration(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): Bool {
        let layout = this.layout(text, style: style, root: root, styles: styles)
        for (glyph in layout.glyphs) {
            if (!glyph.decoration.isNone()) {
                return true
            }
        }
        false
    }

    /** 装饰线路径；与字形使用同一旋转矩阵，按字形逐个生成。 */
    public func decorationOutline(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): ?SvgPathData {
        let runs = this.decorationRuns(text, style: style, root: root, styles: styles)
        if (runs.size == 0) {
            return None
        }
        let commands = ArrayList<SvgPathCommand>()
        for (run in runs) {
            for (command in run.path.commands) {
                commands.add(command)
            }
        }
        Some(SvgPathData(commands.toArray()))
    }

    /**
     * 按字形切分装饰线。每段携带该字形的包围盒，`objectBoundingBox` 渐变
     * 按字形包围盒建立，而不是复用整段文本的包围盒。
     */
    internal func decorationRuns(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): ArrayList<SvgDecorationRun> {
        let layout = this.layout(text, style: style, root: root, styles: styles)
        let runs = ArrayList<SvgDecorationRun>()
        for (glyph in layout.glyphs) {
            if (glyph.decoration.isNone()) {
                continue
            }
            let commands = ArrayList<SvgPathCommand>()
            let matrix = SvgMatrix.translate(glyph.x, glyph.y)
                .multiply(SvgMatrix.rotate(glyph.angle))
            let spec = glyph.decorationSpec
            let thickness = svgDecorationThicknessPx(spec.thickness, glyph.fontSize)
            let underlineOffset = svgDecorationUnderlineOffset(spec.underlinePosition, glyph, thickness)
            if (glyph.decoration.underline) {
                appendSvgDecorationSegments(
                    commands,
                    matrix,
                    glyph.advance,
                    underlineOffset,
                    thickness,
                    spec.style
                )
            }
            if (glyph.decoration.overline) {
                appendSvgDecorationSegments(
                    commands,
                    matrix,
                    glyph.advance,
                    SvgTextDecorationGeometry.overlineOffset(glyph.ascent),
                    thickness,
                    spec.style
                )
            }
            if (glyph.decoration.lineThrough) {
                appendSvgDecorationSegments(
                    commands,
                    matrix,
                    glyph.advance,
                    SvgTextDecorationGeometry.lineThroughOffset(glyph.ascent),
                    thickness,
                    spec.style
                )
            }
            if (commands.size == 0) {
                continue
            }
            let path = SvgPathData(commands.toArray())
            let bounds = pathDataBounds(path) ?? SvgBounds(glyph.x, glyph.y, glyph.advance, thickness)
            runs.add(SvgDecorationRun(path, bounds, color: spec.color, thickness: thickness))
        }
        runs
    }

    /** 合并所有字形路径，供光栅器与形状共用填充 / 描边 / 渐变管线。 */
    public func outline(
        text: SvgTextElement,
        style!: SvgComputedStyle,
        root!: ?SvgElement = None,
        styles!: ?SvgComputedStyleTree = None
    ): ?SvgPathData {
        let layout = this.layout(text, style: style, root: root, styles: styles)
        let commands = ArrayList<SvgPathCommand>()
        for (glyph in layout.glyphs) {
            match (glyph.path) {
                case Some(path) =>
                    let matrix = SvgMatrix.translate(glyph.x, glyph.y)
                        .multiply(SvgMatrix.rotate(glyph.angle))
                    for (command in path.commands) {
                        commands.add(transformTextCommand(command, matrix))
                    }
                case None => ()
            }
        }
        if (commands.size == 0) {
            None
        } else {
            Some(SvgPathData(commands.toArray()))
        }
    }

    private func glyphEntry(font: SvgFont, char: SvgTextChar): SvgGlyphEntry {
        let key = "${char.family}|${char.weight}|${char.style}|${formatSvgNumber(char.fontSize)}|${char.codePoint}"
        match (this.glyphCache.get(key)) {
            case Some(entry) => return entry
            case None => ()
        }
        let path = font.glyphPath(char.codePoint, char.fontSize)
        if (path.isNone() && char.codePoint != 32) {
            this.warnings.add("字体「${char.family}」缺少字形 ${char.codePoint}，使用占位方框")
            let placeholder = placeholderGlyph(char.fontSize, font.advance(char.codePoint, char.fontSize))
            let entry = SvgGlyphEntry(placeholder, true)
            this.glyphCache[key] = entry
            return entry
        }
        let entry = SvgGlyphEntry(path, false)
        this.glyphCache[key] = entry
        entry
    }
}

/** `text-decoration-thickness` → 用户单位厚度；`auto` 用字体度量。 */
private func svgDecorationThicknessPx(thickness: ?SvgLength, fontSize: Float64): Float64 {
    let value = match (thickness) {
        case Some(length) =>
            match (length.unit) {
                case Percent => length.value / 100.0 * fontSize
                case Em => length.value * fontSize
                case Ex => length.value * fontSize / 2.0
                case In => length.value * 96.0
                case Cm => length.value * 96.0 / 2.54
                case Mm => length.value * 96.0 / 25.4
                case Pt => length.value * 96.0 / 72.0
                case Pc => length.value * 96.0 / 6.0
                case _ => length.value
            }
        case None => SvgTextDecorationGeometry.thickness(fontSize)
    }
    if (isFiniteSvgNumber(value) && value > 0.0) {
        value
    } else {
        SvgTextDecorationGeometry.thickness(fontSize)
    }
}

/** 下划线位置：`auto` 基线下 0.10em；`under` 再下移 descent；`above` 基线上方。 */
private func svgDecorationUnderlineOffset(
    position: SvgTextUnderlinePosition,
    glyph: SvgTextGlyph,
    thickness: Float64
): Float64 {
    let auto = SvgTextDecorationGeometry.underlineOffset(glyph.fontSize)
    match (position) {
        case Auto => auto
        case Under => auto + (if (glyph.descent > 0.0) { glyph.descent } else { 0.0 })
        case Above => -thickness
    }
}

/** 子元素是否显式声明任一装饰属性（简写视为全部）。 */
private func svgDecorationStyleDeclared(style: SvgComputedStyle): Bool {
    if (style.sourceOf("text-decoration") != CssStyleSource.Default) {
        return true
    }
    for (name in [
        "text-decoration-line", "text-decoration-style", "text-decoration-color",
        "text-decoration-thickness", "text-underline-position"
    ]) {
        if (style.sourceOf(name) != CssStyleSource.Default) {
            return true
        }
    }
    false
}

/** 无样式树时，从 tspan 属性解析装饰规格；缺省沿用父状态。 */
private func svgDecorationSpecFromAttributes(
    span: SvgTextElement,
    parent: SvgDecorationStyle
): SvgDecorationStyle {
    var lines = parent.lines
    var decoStyle = parent.style
    var color = parent.color
    var thickness = parent.thickness
    var underlinePosition = parent.underlinePosition
    let shorthand = span.attr("text-decoration")
    match (span.attr("text-decoration-line")) {
        case Some(text) =>
            lines = parseSvgDecorationLines(text) ?? SvgTextDecoration.none
        case None =>
            match (shorthand) {
                case Some(text) =>
                    lines = parseSvgDecorationLines(text) ?? SvgTextDecoration.none
                case None => ()
            }
    }
    match (span.attr("text-decoration-style")) {
        case Some(text) => decoStyle = SvgTextDecorationStyle.fromName(text) ?? decoStyle
        case None => ()
    }
    match (span.attr("text-decoration-color")) {
        case Some(text) =>
            match (SvgColor.tryParse(text)) {
                case Some(value) => color = Some(value)
                case None => ()
            }
        case None => ()
    }
    match (span.attr("text-decoration-thickness")) {
        case Some(text) =>
            match (SvgLength.tryParse(text)) {
                case Some(value) => thickness = Some(value)
                case None => ()
            }
        case None => ()
    }
    match (span.attr("text-underline-position")) {
        case Some(text) =>
            underlinePosition = SvgTextUnderlinePosition.fromName(text) ?? underlinePosition
        case None => ()
    }
    SvgDecorationStyle(
        lines: lines,
        style: decoStyle,
        color: color,
        thickness: thickness,
        underlinePosition: underlinePosition
    )
}

private func charFontAscent(font: SvgFont, char: SvgTextChar): Float64 {
    if (font is SvgHersheyFont) {
        return char.fontSize * 0.8
    }
    font.ascent(char.fontSize)
}

private func charFontDescent(font: SvgFont, char: SvgTextChar): Float64 {
    if (font is SvgHersheyFont) {
        return char.fontSize * 0.2
    }
    font.descent(char.fontSize)
}

private func baselineOffsetFor(
    char: SvgTextChar,
    ascent: Float64,
    descent: Float64
): Float64 {
    let dominantOffset = SvgTextBaseline.offset(
        char.dominant,
        ascent,
        descent,
        char.fontSize
    )
    var alignmentOffset = 0.0
    if (!char.isRoot) {
        match (char.alignment) {
            case Auto | Baseline => ()
            case _ =>
                alignmentOffset = SvgTextBaseline.offset(
                    char.alignment,
                    ascent,
                    descent,
                    char.fontSize
                ) - SvgTextBaseline.offset(
                    char.parentDominant,
                    ascent,
                    descent,
                    char.fontSize
                )
        }
    }
    dominantOffset + alignmentOffset + SvgTextBaseline.shift(char.shift, char.fontSize)
}

private func collectSvgTextChars(
    element: SvgTextElement,
    state: SvgTextState,
    out: ArrayList<SvgTextChar>,
    warnings: ArrayList<String>,
    parentDominant!: SvgDominantBaseline = SvgDominantBaseline.Auto,
    rootLevel!: Bool = false,
    styles!: ?SvgComputedStyleTree = None
): Unit {
    for (node in element.children) {
        match (node) {
            case TextNode(text) =>
                for (rune in text.runes()) {
                    out.add(
                        SvgTextChar(
                            Int64(UInt32(rune)),
                            state,
                            parentDominant: parentDominant,
                            isRoot: rootLevel
                        )
                    )
                }
            case ElementNode(child) =>
                match (child) {
                    case span: SvgTextElement =>
                        let spanStyle: ?SvgComputedStyle = match (styles) {
                            case Some(tree) => tree.get(span)
                            case None => None
                        }
                        let nextDominant = match (spanStyle) {
                            case Some(value) => value.dominantBaseline()
                            case None =>
                                match (span.attr("dominant-baseline")) {
                                    case Some(text) =>
                                        SvgDominantBaseline.fromName(text) ?? state.dominant
                                    case None => state.dominant
                                }
                        }
                        let nextAlignment = match (spanStyle) {
                            case Some(value) => value.alignmentBaseline()
                            case None =>
                                match (span.attr("alignment-baseline")) {
                                    case Some(text) =>
                                        SvgAlignmentBaseline.fromName(text) ?? state.alignment
                                    case None => state.alignment
                                }
                        }
                        let nextShift = match (spanStyle) {
                            case Some(value) => value.baselineShift()
                            case None =>
                                match (span.attr("baseline-shift")) {
                                    case Some(text) =>
                                        SvgBaselineShift.fromName(text) ?? state.shift
                                    case None => state.shift
                                }
                        }
                        let nextDecorationSpec = match (spanStyle) {
                            case Some(value) =>
                                if (svgDecorationStyleDeclared(value)) {
                                    resolveSvgDecorationStyle(span, value, styles)
                                } else {
                                    state.decorationSpec
                                }
                            case None =>
                                match (span.attr("text-decoration-line")) {
                                    case Some(_) => svgDecorationSpecFromAttributes(span, state.decorationSpec)
                                    case None =>
                                        match (span.attr("text-decoration")) {
                                            case Some(_) =>
                                                svgDecorationSpecFromAttributes(span, state.decorationSpec)
                                            case None =>
                                                match (span.attr("text-decoration-style")) {
                                                    case Some(_) =>
                                                        svgDecorationSpecFromAttributes(
                                                            span,
                                                            state.decorationSpec
                                                        )
                                                    case None =>
                                                        match (span.attr("text-decoration-color")) {
                                                            case Some(_) =>
                                                                svgDecorationSpecFromAttributes(
                                                                    span,
                                                                    state.decorationSpec
                                                                )
                                                            case None =>
                                                                match (span.attr(
                                                                    "text-decoration-thickness"
                                                                )) {
                                                                    case Some(_) =>
                                                                        svgDecorationSpecFromAttributes(
                                                                            span,
                                                                            state.decorationSpec
                                                                        )
                                                                    case None =>
                                                                        state.decorationSpec
                                                                }
                                                        }
                                                }
                                        }
                                }
                        }
                        let nextDecoration = nextDecorationSpec.lines
                        let nextDirection = match (spanStyle) {
                            case Some(value) => value.direction()
                            case None =>
                                match (span.attr("direction")) {
                                    case Some(text) => SvgDirection.fromName(text) ?? state.direction
                                    case None => state.direction
                                }
                        }
                        let nextBidi = match (spanStyle) {
                            case Some(value) => value.unicodeBidi()
                            case None =>
                                match (span.attr("unicode-bidi")) {
                                    case Some(text) =>
                                        SvgUnicodeBidi.fromName(text) ?? SvgUnicodeBidi.Normal
                                    case None => SvgUnicodeBidi.Normal
                                }
                        }
                        let next = SvgTextState(
                            span.fontSize?.value ?? state.fontSize,
                            span.fontFamily ?? state.family,
                            span.fontWeight ?? state.weight,
                            span.fontStyle ?? state.style,
                            span.letterSpacing?.value ?? state.letterSpacing,
                            span.wordSpacing?.value ?? state.wordSpacing,
                            dominant: nextDominant,
                            alignment: nextAlignment,
                            shift: nextShift,
                            decoration: nextDecoration,
                            decorationSpec: nextDecorationSpec,
                            stretch: match (spanStyle) {
                                case Some(value) => value.fontStretch().percentage()
                                case None => state.stretch
                            },
                            direction: nextDirection,
                            unicodeBidi: nextBidi
                        )
                        let start = out.size
                        collectSvgTextChars(
                            span,
                            next,
                            out,
                            warnings,
                            parentDominant: state.dominant,
                            rootLevel: false,
                            styles: styles
                        )
                        if (out.size > start) {
                            let first = out[start]
                            match (span.dx) {
                                case Some(values) => if (values.size > 0) {
                                    first.dx += values[0].value
                                }
                                case None => ()
                            }
                            match (span.dy) {
                                case Some(values) => if (values.size > 0) {
                                    first.dy += values[0].value
                                }
                                case None => ()
                            }
                            match (span.x) {
                                case Some(values) => if (values.size > 0) {
                                    for (index in start..out.size) {
                                        let char = out[index]
                                        if (char.xExplicit) {
                                            continue
                                        }
                                        let offset = index - start
                                        let valueIndex = if (offset < values.size) {
                                            offset
                                        } else {
                                            values.size - 1
                                        }
                                        char.xOverride = Some(values[valueIndex].value)
                                        char.xExplicit = true
                                    }
                                }
                                case None => ()
                            }
                            match (span.y) {
                                case Some(values) => if (values.size > 0) {
                                    for (index in start..out.size) {
                                        let char = out[index]
                                        if (char.yExplicit) {
                                            continue
                                        }
                                        let offset = index - start
                                        let valueIndex = if (offset < values.size) {
                                            offset
                                        } else {
                                            values.size - 1
                                        }
                                        char.yBase = values[valueIndex].value
                                        char.yExplicit = true
                                    }
                                }
                                case None => ()
                            }
                        }
                    case _ => ()
                }
            case _ => ()
        }
    }
}

private func applyRootTextAttributes(text: SvgTextElement, chars: ArrayList<SvgTextChar>): Unit {
    let xValues = text.x
    let yValues = text.y
    let dxValues = text.dx
    let dyValues = text.dy
    for (index in 0..chars.size) {
        let char = chars[index]
        match (xValues) {
            case Some(values) =>
                if (!char.xExplicit) {
                    if (index < values.size) {
                        char.xOverride = Some(values[index].value)
                    } else if (values.size > 0) {
                        char.xOverride = Some(values[values.size - 1].value)
                    }
                }
            case None => ()
        }
        match (yValues) {
            case Some(values) =>
                if (!char.yExplicit) {
                    if (index < values.size) {
                        char.yBase = values[index].value
                    } else if (values.size > 0) {
                        char.yBase = values[values.size - 1].value
                    }
                }
            case None => ()
        }
        match (dxValues) {
            case Some(values) => if (index < values.size) {
                char.dx += values[index].value
            }
            case None => ()
        }
        match (dyValues) {
            case Some(values) => if (index < values.size) {
                char.dy += values[index].value
            }
            case None => ()
        }
    }
}

private func placeholderGlyph(fontSize: Float64, advance: Float64): SvgPathData {
    let width = if (advance > 0.0) { advance * 0.7 } else { fontSize * 0.5 }
    SvgPathData([
        SvgPathCommand(SvgPathCommandKind.MoveTo, false, [0.0, 0.0]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [width, 0.0]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [width, -fontSize * 0.7]),
        SvgPathCommand(SvgPathCommandKind.LineTo, false, [0.0, -fontSize * 0.7]),
        SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
    ])
}

private func scalePathX(path: SvgPathData, factor: Float64): SvgPathData {
    let commands = ArrayList<SvgPathCommand>()
    for (command in path.commands) {
        match (command.kind) {
            case MoveTo | LineTo | SmoothQuadraticBezierTo =>
                commands.add(
                    SvgPathCommand(
                        command.kind,
                        command.relative,
                        [command.values[0] * factor, command.values[1]]
                    )
                )
            case HorizontalLineTo =>
                commands.add(
                    SvgPathCommand(command.kind, command.relative, [command.values[0] * factor])
                )
            case VerticalLineTo | ClosePath => commands.add(command)
            case CurveTo =>
                commands.add(
                    SvgPathCommand(
                        command.kind,
                        command.relative,
                        [
                            command.values[0] * factor, command.values[1],
                            command.values[2] * factor, command.values[3],
                            command.values[4] * factor, command.values[5]
                        ]
                    )
                )
            case SmoothCurveTo | QuadraticBezierTo =>
                commands.add(
                    SvgPathCommand(
                        command.kind,
                        command.relative,
                        [
                            command.values[0] * factor, command.values[1],
                            command.values[2] * factor, command.values[3]
                        ]
                    )
                )
            case ArcTo => commands.add(command)
        }
    }
    SvgPathData(commands.toArray())
}


/** 每个字形的旋转列表；单值作用于全部，短列表复用末值，长列表多余忽略。 */
internal func resolveTextRotations(
    text: SvgTextElement,
    count: Int64,
    warnings: ArrayList<String>,
    location!: String = ""
): Array<Float64> {
    let prefix = if (location.size > 0) { "${location} " } else { "" }
    let result = Array<Float64>(count, repeat: 0.0)
    if (count == 0) {
        return result
    }
    match (text.rotate) {
        case Some(values) =>
            if (values.size == 0) {
                warnings.add("${prefix}文本 rotate 列表为空，已忽略")
                return result
            }
            fillTextRotations(result, values)
        case None =>
            match (text.attr("rotate")) {
                case Some(raw) =>
                    let values = parseLenientRotateList(raw, warnings, prefix)
                    if (values.size == 0) {
                        warnings.add("${prefix}文本 rotate 列表为空，已忽略")
                        return result
                    }
                    fillTextRotations(result, values)
                case None => ()
            }
    }
    result
}

private func fillTextRotations(result: Array<Float64>, values: Array<Float64>): Unit {
    var index: Int64 = 0
    while (index < result.size) {
        let source = if (index < values.size) {
            index
        } else {
            values.size - 1
        }
        result[index] = values[source]
        index++
    }
}

/** `rotate` 逐项解析：非法项记 warning 并按 0 处理，其余项仍生效。 */
private func parseLenientRotateList(
    text: String,
    warnings: ArrayList<String>,
    prefix: String
): Array<Float64> {
    let bytes = text.unsafeBytes()
    let values = ArrayList<Float64>()
    var index = skipSvgSpaces(bytes, 0)
    while (index < bytes.size) {
        if (bytes[index] == b',') {
            index = skipSvgSpaces(bytes, index + 1)
            continue
        }
        match (scanSvgNumber(text, index)) {
            case Some(token) =>
                if (token.value.isNaN() || token.value.isInf()) {
                    warnings.add("${prefix}文本 rotate 含非法值，已按 0 处理")
                    values.add(0.0)
                } else {
                    values.add(token.value)
                }
                index = skipSvgSpaces(bytes, token.end)
            case None =>
                warnings.add("${prefix}文本 rotate 含非法值，已按 0 处理")
                values.add(0.0)
                var next = index
                while (next < bytes.size && bytes[next] != b',' && !isSvgSpace(bytes[next])) {
                    next++
                }
                if (next == index) {
                    next++
                }
                index = skipSvgSpaces(bytes, next)
        }
    }
    values.toArray()
}

/** 找到当前文本子树中的 textPath 元素（自身或直接子元素）。 */
private func findTextPathElement(text: SvgTextElement): ?SvgTextPath {
    match (text) {
        case path: SvgTextPath => return Some(path)
        case _ => ()
    }
    for (node in text.children) {
        match (node) {
            case ElementNode(element) =>
                match (element) {
                    case path: SvgTextPath => return Some(path)
                    case _ => ()
                }
            case _ => ()
        }
    }
    None
}

/** 解析 textPath 的 `path` 属性或 `href="#id"` 指向的 path。 */
private func resolveTextPathData(pathElement: SvgTextPath, root: ?SvgElement): ?SvgPathData {
    match (pathElement.path) {
        case Some(value) => return Some(value)
        case None => ()
    }
    match (readSvgHref(pathElement)) {
        case Some(href) =>
            let id = stripSvgHash(href)
            match (findSvgElementById(root, id)) {
                case Some(element) =>
                    match (element) {
                        case path: SvgPath => path.d
                        case _ => None
                    }
                case None => None
            }
        case None => None
    }
}

/** 对绝对坐标命令应用仿射矩阵；相对命令与 ClosePath 原样保留。 */
private func transformTextCommand(command: SvgPathCommand, matrix: SvgMatrix): SvgPathCommand {
    if (command.relative) {
        return command
    }
    match (command.kind) {
        case MoveTo | LineTo =>
            let point = matrix.apply(SvgPoint(command.values[0], command.values[1]))
            SvgPathCommand(command.kind, false, [point.x, point.y])
        case CurveTo =>
            let first = matrix.apply(SvgPoint(command.values[0], command.values[1]))
            let second = matrix.apply(SvgPoint(command.values[2], command.values[3]))
            let end = matrix.apply(SvgPoint(command.values[4], command.values[5]))
            SvgPathCommand(
                command.kind,
                false,
                [first.x, first.y, second.x, second.y, end.x, end.y]
            )
        case SmoothCurveTo | QuadraticBezierTo =>
            let control = matrix.apply(SvgPoint(command.values[0], command.values[1]))
            let end = matrix.apply(SvgPoint(command.values[2], command.values[3]))
            SvgPathCommand(command.kind, false, [control.x, control.y, end.x, end.y])
        case SmoothQuadraticBezierTo =>
            let end = matrix.apply(SvgPoint(command.values[0], command.values[1]))
            SvgPathCommand(command.kind, false, [end.x, end.y])
        case ArcTo =>
            let end = matrix.apply(SvgPoint(command.values[5], command.values[6]))
            SvgPathCommand(
                command.kind,
                false,
                [
                    command.values[0], command.values[1], command.values[2],
                    command.values[3], command.values[4], end.x, end.y
                ]
            )
        case HorizontalLineTo | VerticalLineTo | ClosePath => command
    }
}

private func containsTextColumn(columns: ArrayList<Float64>, value: Float64): Bool {
    for (item in columns) {
        if (item == value) {
            return true
        }
    }
    false
}

private func textColumnIndex(columns: ArrayList<Float64>, value: Float64): Int64 {
    for (index in 0..columns.size) {
        if (columns[index] == value) {
            return index
        }
    }
    0
}

private class SvgBidiArrangement {
    let order: Array<Int64>
    let levels: Array<Int64>

    init(order: Array<Int64>, levels: Array<Int64>) {
        this.order = order
        this.levels = levels
    }
}

/** 竖排时不做行内双向重排（`direction` 只决定列序）。 */
private func shouldReorderBidi(style: SvgComputedStyle, chars: ArrayList<SvgTextChar>): Bool {
    let writingMode = style.writingMode()
    if (writingMode == SvgWritingMode.Tb || writingMode == SvgWritingMode.TbRl) {
        return false
    }
    if (style.direction() == SvgDirection.Rtl) {
        return true
    }
    for (char in chars) {
        if (char.direction == SvgDirection.Rtl || char.unicodeBidi != SvgUnicodeBidi.Normal) {
            return true
        }
    }
    false
}

/** 方向对应的嵌入层级：先取比基础层级更高的层级，再调整奇偶。 */
private func bidiEmbeddingLevel(base: Int64, direction: SvgDirection): Int64 {
    let needsOdd = direction == SvgDirection.Rtl
    var level = if ((base % 2 == 1) != needsOdd) {
        base + 1
    } else {
        base
    }
    while ((level % 2 == 1) != needsOdd) {
        level++
    }
    level
}

private func bidiSegmentLevels(
    chars: ArrayList<SvgTextChar>,
    start: Int64,
    end: Int64,
    baseRtl: Bool
): Array<Int64> {
    let codePoints = ArrayList<Int64>()
    for (index in start..end) {
        codePoints.add(chars[index].codePoint)
    }
    let base: Int64 = if (baseRtl) { 1 } else { 0 }
    let paragraphDirection = if (baseRtl) { SvgDirection.Rtl } else { SvgDirection.Ltr }
    let codePointArray = codePoints.toArray()
    let levels = svgBidiLevels(codePointArray, baseRtl)
    let overrideLevels = svgBidiOverrideLevels(codePointArray, baseRtl)
    for (offset in 0..levels.size) {
        let char = chars[start + offset]
        if (char.unicodeBidi == SvgUnicodeBidi.BidiOverride) {
            levels[offset] = overrideLevels[offset]
        } else if (char.unicodeBidi == SvgUnicodeBidi.Embed ||
            char.direction != paragraphDirection) {
            levels[offset] = bidiEmbeddingLevel(base, char.direction)
        }
    }
    levels
}

/** 按 `B` 分段后重排为视觉顺序，返回逻辑下标与对应层级。 */
private func bidiArrangement(
    chars: ArrayList<SvgTextChar>,
    style: SvgComputedStyle
): SvgBidiArrangement {
    let size = chars.size
    let levels = Array<Int64>(size, repeat: 0)
    let order = ArrayList<Int64>()
    if (size == 0) {
        return SvgBidiArrangement(order.toArray(), levels)
    }
    let baseRtl = style.direction() == SvgDirection.Rtl
    var start: Int64 = 0
    var index: Int64 = 0
    while (index <= size) {
        let atBreak = index == size || svgBidiClass(chars[index].codePoint) == SvgBidiClass.B
        if (atBreak) {
            if (index > start) {
                let segmentLevels = bidiSegmentLevels(chars, start, index, baseRtl)
                let segmentOrder = svgBidiVisualOrder(segmentLevels)
                for (visual in segmentOrder) {
                    order.add(start + visual)
                }
                for (offset in 0..segmentLevels.size) {
                    levels[start + offset] = segmentLevels[offset]
                }
            }
            if (index < size) {
                levels[index] = if (baseRtl) { 1 } else { 0 }
                order.add(index)
            }
            start = index + 1
        }
        index++
    }
    SvgBidiArrangement(order.toArray(), levels)
}

private func permuteBidiChars(
    chars: ArrayList<SvgTextChar>,
    arrangement: SvgBidiArrangement
): ArrayList<SvgTextChar> {
    let result = ArrayList<SvgTextChar>()
    for (logical in arrangement.order) {
        let original = chars[logical]
        if (arrangement.levels[logical] % 2 != 0) {
            result.add(original.copyWithCodePoint(svgMirrorBidiCodePoint(original.codePoint)))
        } else {
            result.add(original)
        }
    }
    result
}

private func permuteBidiValues<T>(
    values: ArrayList<T>,
    order: Array<Int64>
): ArrayList<T> {
    let result = ArrayList<T>()
    for (index in order) {
        result.add(values[index])
    }
    result
}

private func permuteBidiOptionalPaths(
    values: ArrayList<?SvgPathData>,
    order: Array<Int64>
): ArrayList<?SvgPathData> {
    let result = ArrayList<?SvgPathData>()
    for (index in order) {
        result.add(values[index])
    }
    result
}

private func permuteBidiFonts(
    values: ArrayList<Option<SvgFont>>,
    order: Array<Int64>
): ArrayList<Option<SvgFont>> {
    let result = ArrayList<Option<SvgFont>>()
    for (index in order) {
        result.add(values[index])
    }
    result
}

/** 同一字体、同一字号的相邻字符应用字距。 */
private func applyFontKerning(
    chars: ArrayList<SvgTextChar>,
    fonts: ArrayList<Option<SvgFont>>,
    advances: ArrayList<Float64>,
    style: SvgComputedStyle
): Unit {
    if (style.fontKerning() == SvgFontKerning.None) {
        return
    }
    if (chars.size < 2) {
        return
    }
    for (index in 0..chars.size - 1) {
        let left = chars[index]
        let right = chars[index + 1]
        if (left.fontSize != right.fontSize || left.family != right.family ||
            left.weight != right.weight || left.style != right.style) {
            continue
        }
        let font = match (fonts[index]) {
            case Some(value) => value
            case None => continue
        }
        match (font) {
            case truetype: SvgTrueTypeFont =>
                if (truetype.hasKerning()) {
                    advances[index] += truetype.kerningAdjustByIds(
                        left.glyphId,
                        right.glyphId,
                        left.fontSize
                    )
                }
            case _ => ()
        }
    }
}

/** 应用 GSUB `liga`：用连字字形替换簇内字形。 */
private func applyFontLigatures(
    chars: ArrayList<SvgTextChar>,
    fonts: ArrayList<Option<SvgFont>>,
    advances: ArrayList<Float64>,
    paths: ArrayList<?SvgPathData>
): Unit {
    if (chars.size < 2) {
        return
    }
    var index: Int64 = 0
    while (index < chars.size - 1) {
        let font = match (fonts[index]) {
            case Some(value) => value
            case None =>
                index++
                continue
        }
        match (font) {
            case truetype: SvgTrueTypeFont =>
                if (!truetype.hasLigatures() || truetype.hasContextSubstitutions()) {
                    index++
                    continue
                }
                let remaining = ArrayList<Int64>()
                var runEnd = index + 1
                while (runEnd < chars.size) {
                    let candidate = chars[runEnd]
                    if (candidate.fontSize != chars[index].fontSize ||
                        candidate.family != chars[index].family ||
                        candidate.weight != chars[index].weight ||
                        candidate.style != chars[index].style) {
                        break
                    }
                    runEnd++
                }
                for (position in index..runEnd) {
                    remaining.add(chars[position].codePoint)
                }
                match (truetype.ligatureAt(remaining.toArray(), 0)) {
                    case Some(found) =>
                        let glyph = found[0]
                        let consumed = found[1]
                        if (consumed < 2) {
                            index++
                            continue
                        }
                        advances[index] = truetype.advanceById(glyph, chars[index].fontSize)
                        paths[index] = truetype.pathById(glyph, chars[index].fontSize)
                        chars[index].glyphId = glyph
                        for (offset in 1..consumed) {
                            advances[index + offset] = 0.0
                            paths[index + offset] = Option<SvgPathData>.None
                            chars[index + offset].consumed = true
                        }
                        index += consumed
                    case None => index++
                }
            case _ => index++
        }
    }
}

/**
 * M6 上下文整形：在同一个 run 内按启用特性应用 Type 5 / 6 替换。
 *
 * 与 M5 连字路径互斥：带上下文表的字体在 `applyFontLigatures` 中跳过，
 * 由其统一处理特性分组、嵌套 lookup 与连字消费。
 */
private func applyFontContextShaping(
    chars: ArrayList<SvgTextChar>,
    fonts: ArrayList<Option<SvgFont>>,
    advances: ArrayList<Float64>,
    paths: ArrayList<?SvgPathData>,
    style: SvgComputedStyle,
    warnings: ArrayList<String>
): Unit {
    var index: Int64 = 0
    let features = style.fontFeatures()
    while (index < chars.size) {
        let font = match (fonts[index]) {
            case Some(value) => value
            case None =>
                index++
                continue
        }
        match (font) {
            case truetype: SvgTrueTypeFont =>
                if (!truetype.hasContextSubstitutions()) {
                    index++
                    continue
                }
                var runEnd = index + 1
                while (runEnd < chars.size) {
                    let candidate = chars[runEnd]
                    if (candidate.fontSize != chars[index].fontSize ||
                        candidate.family != chars[index].family ||
                        candidate.weight != chars[index].weight ||
                        candidate.style != chars[index].style) {
                        break
                    }
                    runEnd++
                }
                let codePoints = ArrayList<Int64>()
                for (position in index..runEnd) {
                    codePoints.add(chars[position].codePoint)
                }
                let shaped = truetype.shapeGlyphs(codePoints.toArray(), features, warnings)
                for (position in 0..shaped.glyphs.size) {
                    let origin = index + shaped.origins[position]
                    let glyph = shaped.glyphs[position]
                    if (glyph != truetype.glyphIndexOrZero(chars[origin].codePoint)) {
                        advances[origin] = truetype.advanceById(glyph, chars[origin].fontSize)
                        paths[origin] = truetype.pathById(glyph, chars[origin].fontSize)
                        chars[origin].glyphId = glyph
                    }
                }
                for (removed in shaped.removed) {
                    let target = index + removed
                    advances[target] = 0.0
                    paths[target] = Option<SvgPathData>.None
                    chars[target].consumed = true
                }
                index = runEnd
            case _ => index++
        }
    }
}

/** 请求百分比与最终字体均满足条件时做水平合成缩放；精确匹配不再二次缩放。 */
private func applyFontStretchSynthesis(
    chars: ArrayList<SvgTextChar>,
    advances: ArrayList<Float64>,
    paths: ArrayList<?SvgPathData>
): Unit {
    for (index in 0..chars.size) {
        let percent = chars[index].stretch
        if (percent == 100.0 || percent <= 0.0) {
            continue
        }
        if (chars[index].matchedStretch != 100.0) {
            continue
        }
        let factor = percent / 100.0
        match (paths[index]) {
            case Some(path) => paths[index] = Some(scalePathX(path, factor))
            case None => ()
        }
        advances[index] = advances[index] * factor
    }
}

/** 合成 small-caps：小写 ASCII 用大写字形并按 0.8 等比缩放。 */
private func applySmallCaps(
    chars: ArrayList<SvgTextChar>,
    fonts: ArrayList<Option<SvgFont>>,
    advances: ArrayList<Float64>,
    paths: ArrayList<?SvgPathData>,
    style: SvgComputedStyle,
    warnings: ArrayList<String>
): Unit {
    if (style.fontVariantCaps() != "small-caps") {
        return
    }
    for (index in 0..chars.size) {
        let codePoint = chars[index].codePoint
        if (codePoint < 97 || codePoint > 122) {
            continue
        }
        let font = match (fonts[index]) {
            case Some(value) => value
            case None => continue
        }
        let upper = codePoint - 32
        match (font.glyphPath(upper, chars[index].fontSize)) {
            case Some(path) =>
                paths[index] = Some(scalePathUniform(path, 0.8))
                advances[index] = advances[index] * 0.8
            case None =>
                warnings.add("small-caps 缺少大写字形 ${upper}，保留原字形")
        }
    }
}

/** `font-size-adjust`：按 OS/2 x-height 比例修正字形与 advance。 */
private func applyFontSizeAdjust(
    chars: ArrayList<SvgTextChar>,
    fonts: ArrayList<Option<SvgFont>>,
    advances: ArrayList<Float64>,
    paths: ArrayList<?SvgPathData>,
    style: SvgComputedStyle,
    warnings: ArrayList<String>
): Unit {
    let adjust = match (style.fontSizeAdjust()) {
        case Some(value) => value
        case None => return
    }
    for (index in 0..chars.size) {
        let font = match (fonts[index]) {
            case Some(value) => value
            case None => continue
        }
        let ratio = match (font) {
            case truetype: SvgTrueTypeFont => truetype.xHeightRatio()
            case _ => Option<Float64>.None
        }
        let xHeight = match (ratio) {
            case Some(value) => value
            case None =>
                warnings.add("font-size-adjust 缺少 OS/2 x-height，已忽略")
                return
        }
        if (xHeight <= 0.0) {
            return
        }
        let factor = adjust / xHeight
        if (factor == 1.0) {
            continue
        }
        match (paths[index]) {
            case Some(path) => paths[index] = Some(scalePathUniform(path, factor))
            case None => ()
        }
        advances[index] = advances[index] * factor
    }
}

/** 两轴等比缩放路径。 */
private func scalePathUniform(path: SvgPathData, factor: Float64): SvgPathData {
    let commands = ArrayList<SvgPathCommand>()
    let matrix = SvgMatrix.scale(factor, factor)
    for (command in path.commands) {
        commands.add(transformTextCommand(command, matrix))
    }
    SvgPathData(commands.toArray())
}
