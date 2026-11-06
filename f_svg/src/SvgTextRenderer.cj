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
    /** 该字形生效的装饰线（祖先传播后的结果）。 */
    public let decoration: SvgTextDecoration

    internal init(
        codePoint: Int64,
        x: Float64,
        y: Float64,
        advance: Float64,
        fontSize: Float64,
        path: ?SvgPathData,
        angle!: Float64 = 0.0,
        ascent!: Float64 = 0.0,
        decoration!: SvgTextDecoration = SvgTextDecoration.none
    ) {
        this.codePoint = codePoint
        this.x = x
        this.y = y
        this.advance = advance
        this.fontSize = fontSize
        this.path = path
        this.angle = angle
        this.ascent = ascent
        this.decoration = decoration
    }
}

/** 单个字形的装饰线及其包围盒（用于渐变按字形起点取样）。 */
internal class SvgDecorationRun {
    let path: SvgPathData
    let bounds: SvgBounds

    init(path: SvgPathData, bounds: SvgBounds) {
        this.path = path
        this.bounds = bounds
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
        decoration!: SvgTextDecoration = SvgTextDecoration.none
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
    var xOverride: ?Float64 = None
    var yBase: Float64 = 0.0
    var dx: Float64 = 0.0
    var dy: Float64 = 0.0
    var xExplicit: Bool = false
    var yExplicit: Bool = false

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
            decoration: this.decoration
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
            decoration: effectiveTextDecoration(text, style, styles)
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
        if (shouldReorderBidi(style)) {
            chars = reorderBidiChars(chars, style)
        }

        let count = chars.size
        let advances = ArrayList<Float64>()
        let paths = ArrayList<?SvgPathData>()
        let baselineOffsets = ArrayList<Float64>()
        let ascentValues = ArrayList<Float64>()
        let resolvedFonts = ArrayList<Option<SvgFont>>()
        var missingGlyph = false
        for (index in 0..count) {
            let char = chars[index]
            let font = this.registry.resolve(char.family, char.weight, char.style)
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

        applyFontKerning(chars, resolvedFonts, advances, style)
        applyFontLigatures(chars, resolvedFonts, advances, paths)

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
            count,
            this.warnings,
            location: location
        )
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
            var columnPen = 0.0
            var lastColumn: ?Float64 = None
            for (index in 0..count) {
                let column = chars[index].xOverride ?? 0.0
                match (lastColumn) {
                    case Some(previous) => if (previous != column) {
                        columnPen = 0.0
                    }
                    case None => ()
                }
                lastColumn = Some(column)
                columnPositions.add(column)
                verticalPositions.add(columnPen)
                columnPen += advances[index] * scaleX
                if (index < count - 1) {
                    columnPen += chars[index].letterSpacing + extra
                    if (chars[index].codePoint == 32) {
                        columnPen += chars[index].wordSpacing
                    }
                }
            }
            verticalTotal = columnPen
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
                        let advanceArray = Array<Float64>(count, repeat: 0.0)
                        for (index in 0..count) {
                            advanceArray[index] = advances[index] * scaleX
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
                            letterSpacings: letterSpacings
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
            var angle = rotations[index]
            match (placements) {
                case Some(placed) =>
                    if (index >= placed.size) {
                        continue
                    }
                    x = placed[index].originX
                    y = placed[index].originY + baselineOffsets[index]
                    angle = placed[index].angle + rotations[index]
                case None => ()
            }
            if (vertical) {
                x = columnPositions[index]
                y = char.yBase + char.dy + verticalPositions[index] + verticalAnchor +
                    baselineOffsets[index]
                angle = rotations[index] + 90.0
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
                    decoration: char.decoration
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
            let thickness = SvgTextDecorationGeometry.thickness(glyph.fontSize)
            if (glyph.decoration.underline) {
                appendDecorationRect(
                    commands,
                    matrix,
                    glyph.advance,
                    SvgTextDecorationGeometry.underlineOffset(glyph.fontSize),
                    thickness
                )
            }
            if (glyph.decoration.overline) {
                appendDecorationRect(
                    commands,
                    matrix,
                    glyph.advance,
                    SvgTextDecorationGeometry.overlineOffset(glyph.ascent),
                    thickness
                )
            }
            if (glyph.decoration.lineThrough) {
                appendDecorationRect(
                    commands,
                    matrix,
                    glyph.advance,
                    SvgTextDecorationGeometry.lineThroughOffset(glyph.ascent),
                    thickness
                )
            }
            if (commands.size == 0) {
                continue
            }
            let path = SvgPathData(commands.toArray())
            let bounds = pathDataBounds(path) ?? SvgBounds(glyph.x, glyph.y, glyph.advance, thickness)
            runs.add(SvgDecorationRun(path, bounds))
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

private func appendDecorationRect(
    commands: ArrayList<SvgPathCommand>,
    matrix: SvgMatrix,
    width: Float64,
    offsetY: Float64,
    thickness: Float64
): Unit {
    let p0 = matrix.apply(SvgPoint(0.0, offsetY))
    let p1 = matrix.apply(SvgPoint(width, offsetY))
    let p2 = matrix.apply(SvgPoint(width, offsetY + thickness))
    let p3 = matrix.apply(SvgPoint(0.0, offsetY + thickness))
    commands.add(SvgPathCommand(SvgPathCommandKind.MoveTo, false, [p0.x, p0.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p1.x, p1.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p2.x, p2.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.LineTo, false, [p3.x, p3.y]))
    commands.add(SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>()))
}

/** 装饰线传播：最近声明祖先生效，显式 `none` 关闭。 */
private func effectiveTextDecoration(
    text: SvgTextElement,
    style: SvgComputedStyle,
    styles: ?SvgComputedStyleTree
): SvgTextDecoration {
    if (style.sourceOf("text-decoration") != CssStyleSource.Default) {
        return SvgTextDecoration.tryParse(style.get("text-decoration") ?? "none") ??
            SvgTextDecoration.none
    }
    var current = text.parent
    while (true) {
        match (current) {
            case Some(element) =>
                let declared: ?String = match (styles) {
                    case Some(tree) =>
                        match (tree.get(element)) {
                            case Some(parentStyle) =>
                                if (parentStyle.sourceOf("text-decoration") != CssStyleSource.Default) {
                                    Some(parentStyle.get("text-decoration") ?? "none")
                                } else {
                                    None
                                }
                            case None => None
                        }
                    case None => element.attr("text-decoration")
                }
                match (declared) {
                    case Some(value) =>
                        return SvgTextDecoration.tryParse(value) ?? SvgTextDecoration.none
                    case None => ()
                }
                current = element.parent
            case None => break
        }
    }
    SvgTextDecoration.none
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
                        let nextDecoration = match (spanStyle) {
                            case Some(value) =>
                                if (value.sourceOf("text-decoration") != CssStyleSource.Default) {
                                    value.textDecoration()
                                } else {
                                    state.decoration
                                }
                            case None =>
                                match (span.attr("text-decoration")) {
                                    case Some(text) =>
                                        SvgTextDecoration.tryParse(text) ?? state.decoration
                                    case None => state.decoration
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
                            decoration: nextDecoration
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
            case MoveTo | LineTo =>
                commands.add(
                    SvgPathCommand(
                        command.kind,
                        command.relative,
                        [command.values[0] * factor, command.values[1]]
                    )
                )
            case _ => commands.add(command)
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

/** 竖排时不做行内双向重排（`direction` 只决定列序）。 */
private func shouldReorderBidi(style: SvgComputedStyle): Bool {
    let writingMode = style.writingMode()
    if (writingMode == SvgWritingMode.Tb || writingMode == SvgWritingMode.TbRl) {
        return false
    }
    style.direction() == SvgDirection.Rtl || style.unicodeBidi() != SvgUnicodeBidi.Normal
}

/** 按双向算法重排为视觉顺序，并对偶数层级的 RTL 字符做单层镜像。 */
private func reorderBidiChars(chars: ArrayList<SvgTextChar>, style: SvgComputedStyle): ArrayList<SvgTextChar> {
    let codePoints = ArrayList<Int64>()
    for (char in chars) {
        codePoints.add(char.codePoint)
    }
    let rtl = style.direction() == SvgDirection.Rtl
    let levels = if (style.unicodeBidi() == SvgUnicodeBidi.BidiOverride) {
        svgBidiOverrideLevels(codePoints.toArray(), rtl)
    } else {
        svgBidiLevels(codePoints.toArray(), rtl)
    }
    let order = svgBidiVisualOrder(levels)
    let result = ArrayList<SvgTextChar>()
    for (logical in order) {
        let original = chars[logical]
        let resolved = if (levels[logical] % 2 != 0) {
            svgMirrorBidiCodePoint(original.codePoint)
        } else {
            original.codePoint
        }
        result.add(original.copyWithCodePoint(resolved))
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
                    advances[index] += truetype.kerningAdjust(left.codePoint, right.codePoint, left.fontSize)
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
                if (!truetype.hasLigatures()) {
                    index++
                    continue
                }
                let remaining = ArrayList<Int64>()
                for (position in index..chars.size) {
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
                        for (offset in 1..consumed) {
                            advances[index + offset] = 0.0
                            paths[index + offset] = Option<SvgPathData>.None
                        }
                        index += consumed
                    case None => index++
                }
            case _ => index++
        }
    }
}
