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

    internal init(
        codePoint: Int64,
        x: Float64,
        y: Float64,
        advance: Float64,
        fontSize: Float64,
        path: ?SvgPathData
    ) {
        this.codePoint = codePoint
        this.x = x
        this.y = y
        this.advance = advance
        this.fontSize = fontSize
        this.path = path
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

    init(
        fontSize: Float64,
        family: String,
        weight: String,
        style: String,
        letterSpacing: Float64,
        wordSpacing: Float64
    ) {
        this.fontSize = fontSize
        this.family = family
        this.weight = weight
        this.style = style
        this.letterSpacing = letterSpacing
        this.wordSpacing = wordSpacing
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
    var xOverride: ?Float64 = None
    var yBase: Float64 = 0.0
    var dx: Float64 = 0.0
    var dy: Float64 = 0.0

    init(codePoint: Int64, state: SvgTextState) {
        this.codePoint = codePoint
        this.fontSize = state.fontSize
        this.family = state.family
        this.weight = state.weight
        this.style = state.style
        this.letterSpacing = state.letterSpacing
        this.wordSpacing = state.wordSpacing
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

    public init(registry!: SvgFontRegistry = SvgFontRegistry.defaultRegistry()) {
        this.registry = registry
    }

    public func layout(text: SvgTextElement, style!: SvgComputedStyle): SvgTextLayout {
        let rootState = SvgTextState(
            style.fontSize().value,
            style.fontFamily(),
            style.fontWeight(),
            style.fontStyle(),
            style.letterSpacing().value,
            style.wordSpacing().value
        )
        let chars = ArrayList<SvgTextChar>()
        collectSvgTextChars(text, rootState, chars, this.warnings)
        applyRootTextAttributes(text, chars)

        let count = chars.size
        let advances = ArrayList<Float64>()
        let paths = ArrayList<?SvgPathData>()
        var missingGlyph = false
        for (index in 0..count) {
            let char = chars[index]
            let font = this.registry.resolve(char.family, char.weight, char.style)
            match (font) {
                case Some(value) =>
                    advances.add(value.advance(char.codePoint, char.fontSize))
                    let entry = this.glyphEntry(value, char)
                    if (entry.missing) {
                        missingGlyph = true
                    }
                    paths.add(entry.path)
                case None =>
                    this.warnings.add("未找到字体「${char.family}」，使用占位字形")
                    advances.add(char.fontSize * 0.5)
                    paths.add(placeholderGlyph(char.fontSize, char.fontSize * 0.5))
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

        let glyphs = ArrayList<SvgTextGlyph>()
        var bounds = SvgBounds.empty()
        var hasBounds = false
        for (index in 0..count) {
            let char = chars[index]
            var path = paths[index]
            if (scaleX != 1.0) {
                path = match (path) {
                    case Some(value) => Some(scalePathX(value, scaleX))
                    case None => None
                }
            }
            let x = positions[index] + anchorOffset
            let y = char.yBase + char.dy
            glyphs.add(
                SvgTextGlyph(
                    char.codePoint,
                    x,
                    y,
                    advances[index] * scaleX,
                    char.fontSize,
                    path
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

    /** 合并所有字形路径，供光栅器与形状共用填充 / 描边 / 渐变管线。 */
    public func outline(text: SvgTextElement, style!: SvgComputedStyle): ?SvgPathData {
        let layout = this.layout(text, style: style)
        let commands = ArrayList<SvgPathCommand>()
        for (glyph in layout.glyphs) {
            match (glyph.path) {
                case Some(path) =>
                    for (command in path.commands) {
                        commands.add(translateCommand(command, glyph.x, glyph.y))
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

private func collectSvgTextChars(
    element: SvgTextElement,
    state: SvgTextState,
    out: ArrayList<SvgTextChar>,
    warnings: ArrayList<String>
): Unit {
    match (element.rotate) {
        case Some(values) => if (values.size > 0) {
            warnings.add("文本 rotate 列表在 M2 忽略")
        }
        case None => ()
    }
    if (element.tag == "textPath") {
        warnings.add("textPath 在 M2 降级为普通文本")
    }
    for (node in element.children) {
        match (node) {
            case TextNode(text) =>
                for (rune in text.runes()) {
                    out.add(SvgTextChar(Int64(UInt32(rune)), state))
                }
            case ElementNode(child) =>
                match (child) {
                    case span: SvgTextElement =>
                        let next = SvgTextState(
                            span.fontSize?.value ?? state.fontSize,
                            span.fontFamily ?? state.family,
                            span.fontWeight ?? state.weight,
                            span.fontStyle ?? state.style,
                            span.letterSpacing?.value ?? state.letterSpacing,
                            span.wordSpacing?.value ?? state.wordSpacing
                        )
                        let start = out.size
                        collectSvgTextChars(span, next, out, warnings)
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
                                        let offset = index - start
                                        let valueIndex = if (offset < values.size) {
                                            offset
                                        } else {
                                            values.size - 1
                                        }
                                        out[index].xOverride = Some(values[valueIndex].value)
                                    }
                                }
                                case None => ()
                            }
                            match (span.y) {
                                case Some(values) => if (values.size > 0) {
                                    for (index in start..out.size) {
                                        let offset = index - start
                                        let valueIndex = if (offset < values.size) {
                                            offset
                                        } else {
                                            values.size - 1
                                        }
                                        out[index].yBase = values[valueIndex].value
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
                if (index < values.size) {
                    char.xOverride = Some(values[index].value)
                } else if (values.size > 0) {
                    char.xOverride = Some(values[values.size - 1].value)
                }
            case None => ()
        }
        match (yValues) {
            case Some(values) =>
                if (index < values.size) {
                    char.yBase = values[index].value
                } else if (values.size > 0) {
                    char.yBase = values[values.size - 1].value
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

private func translateCommand(command: SvgPathCommand, dx: Float64, dy: Float64): SvgPathCommand {
    match (command.kind) {
        case MoveTo | LineTo =>
            SvgPathCommand(
                command.kind,
                false,
                [command.values[0] + dx, command.values[1] + dy]
            )
        case _ => command
    }
}
