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

// `SvgPaint` 内的静态成员 `None` 会遮蔽 `Option` 的 `None`，这里用文件级常量绕开。
private let SVG_NO_COLOR: ?SvgColor = None
private let SVG_NO_STRING: ?String = None
private let SVG_NO_PAINT: ?SvgPaint = None


/** 画笔形态。 */
public enum SvgPaintKind <: Equatable<SvgPaintKind> & ToString {
    | None
    | CurrentColor
    | Color
    | Reference
    /** `use` 实例内解析为被引用元素的 `fill`。 */
    | ContextFill
    /** `use` 实例内解析为被引用元素的 `stroke`。 */
    | ContextStroke

    public operator func ==(that: SvgPaintKind): Bool {
        match ((this, that)) {
            case (None, None) => true
            case (CurrentColor, CurrentColor) => true
            case (Color, Color) => true
            case (Reference, Reference) => true
            case (ContextFill, ContextFill) => true
            case (ContextStroke, ContextStroke) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case None => "None"
            case CurrentColor => "CurrentColor"
            case Color => "Color"
            case Reference => "Reference"
            case ContextFill => "ContextFill"
            case ContextStroke => "ContextStroke"
        }
    }
}

/**
 * 画笔：`none` / `currentColor` / 颜色 / 同文档片段引用（可带回退）。
 *
 * `parse` 只接受 `url(#id)`；任何外部 URL 抛 `Security`，且不发起任何 I/O。
 */
public struct SvgPaint <: Equatable<SvgPaint> & ToString {
    public let kind: SvgPaintKind
    public let color: ?SvgColor
    public let reference: ?String
    public let fallback: ?SvgPaint

    private static func make(
        kind: SvgPaintKind,
        color!: ?SvgColor = SVG_NO_COLOR,
        reference!: ?String = SVG_NO_STRING,
        fallback!: ?SvgPaint = SVG_NO_PAINT
    ): SvgPaint {
        SvgPaint(kind, color, reference, fallback)
    }

    public static let None = make(SvgPaintKind.None)
    public static let CurrentColor = make(SvgPaintKind.CurrentColor)

    private init(kind: SvgPaintKind, color: ?SvgColor, reference: ?String, fallback: ?SvgPaint) {
        this.kind = kind
        this.color = color
        this.reference = reference
        this.fallback = fallback
    }

    public static func of(color: SvgColor): SvgPaint {
        make(SvgPaintKind.Color, color: Some(color))
    }

    public static func referencing(id: String, fallback!: ?SvgPaint = SVG_NO_PAINT): SvgPaint {
        let trimmed = id.trimAscii()
        if (trimmed.size == 0 || trimmed == "#") {
            throw invalidValue("画笔引用的 id 不能为空")
        }
        let normalized = if (trimmed[0] == b'#') {
            trimmed
        } else {
            "#" + trimmed
        }
        make(SvgPaintKind.Reference, reference: Some(normalized), fallback: fallback)
    }

    public static func parse(text: String): SvgPaint {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            throw invalidValue("画笔不能为空")
        }
        let lower = trimmed.toAsciiLower()
        if (lower == "none") {
            return SvgPaint.None
        }
        if (lower == "currentcolor") {
            return SvgPaint.CurrentColor
        }
        if (lower == "context-fill") {
            return SvgPaint.make(SvgPaintKind.ContextFill)
        }
        if (lower == "context-stroke") {
            return SvgPaint.make(SvgPaintKind.ContextStroke)
        }
        if (lower.size >= 4 && lower[0..4] == "url(") {
            return parseReference(trimmed)
        }
        SvgPaint.of(SvgColor.parse(trimmed))
    }

    public func toString(): String {
        match (this.kind) {
            case None => "none"
            case CurrentColor => "currentColor"
            case Color => match (this.color) {
                case Some(color) => color.toString()
                case None => "none"
            }
            case ContextFill => "context-fill"
            case ContextStroke => "context-stroke"
            case Reference =>
                let base = "url(${this.reference ?? ""})"
                match (this.fallback) {
                    case Some(paint) => base + " " + paint.toString()
                    case None => base
                }
        }
    }

    public operator func ==(that: SvgPaint): Bool {
        if (this.kind != that.kind) {
            return false
        }
        match (this.kind) {
            case None | CurrentColor | ContextFill | ContextStroke => true
            case Color => this.color == that.color
            case Reference => this.reference == that.reference && this.fallback == that.fallback
        }
    }

    private static func parseReference(text: String): SvgPaint {
        let close = indexOfSvgByte(text, b')')
        if (close < 0) {
            throw invalidValue("url() 缺少右括号「${text}」")
        }
        let inner = text[4..close].trimAscii()
        var id = inner
        if (id.size >= 2) {
            let first = id[0]
            let last = id[id.size - 1]
            if ((first == b'"' && last == b'"') || (first == b'\'' && last == b'\'')) {
                id = id[1..id.size - 1].trimAscii()
            }
        }
        if (id.size == 0 || id == "#") {
            throw invalidValue("url() 内的引用为空")
        }
        if (id[0] != b'#') {
            throw SvgException("不允许外部画笔引用「${id}」", kind: SvgErrorKind.Security)
        }
        let rest = text[close + 1..].trimAscii()
        if (rest.size == 0) {
            return referencing(id)
        }
        if (rest.size >= 4 && rest.toAsciiLower()[0..4] == "url(") {
            throw invalidValue("画笔引用不允许嵌套 url()")
        }
        referencing(id, fallback: Some(parse(rest)))
    }
}
