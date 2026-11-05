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

/** `preserveAspectRatio` 的九种对齐方式。 */
public enum SvgAspectAlign <: Equatable<SvgAspectAlign> & ToString {
    | NoAlign
    | XMinYMin
    | XMidYMin
    | XMaxYMin
    | XMinYMid
    | XMidYMid
    | XMaxYMid
    | XMinYMax
    | XMidYMax
    | XMaxYMax

    public operator func ==(that: SvgAspectAlign): Bool {
        match ((this, that)) {
            case (NoAlign, NoAlign) => true
            case (XMinYMin, XMinYMin) => true
            case (XMidYMin, XMidYMin) => true
            case (XMaxYMin, XMaxYMin) => true
            case (XMinYMid, XMinYMid) => true
            case (XMidYMid, XMidYMid) => true
            case (XMaxYMid, XMaxYMid) => true
            case (XMinYMax, XMinYMax) => true
            case (XMidYMax, XMidYMax) => true
            case (XMaxYMax, XMaxYMax) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case NoAlign => "none"
            case XMinYMin => "xMinYMin"
            case XMidYMin => "xMidYMin"
            case XMaxYMin => "xMaxYMin"
            case XMinYMid => "xMinYMid"
            case XMidYMid => "xMidYMid"
            case XMaxYMid => "xMaxYMid"
            case XMinYMax => "xMinYMax"
            case XMidYMax => "xMidYMax"
            case XMaxYMax => "xMaxYMax"
        }
    }

    internal func isXMin(): Bool {
        match (this) {
            case XMinYMin | XMinYMid | XMinYMax => true
            case _ => false
        }
    }

    internal func isYMin(): Bool {
        match (this) {
            case XMinYMin | XMidYMin | XMaxYMin => true
            case _ => false
        }
    }

    internal func isXMax(): Bool {
        match (this) {
            case XMaxYMin | XMaxYMid | XMaxYMax => true
            case _ => false
        }
    }

    internal func isYMax(): Bool {
        match (this) {
            case XMinYMax | XMidYMax | XMaxYMax => true
            case _ => false
        }
    }
}

/** `preserveAspectRatio`：对齐方式 + `meet` / `slice`。 */
public struct SvgPreserveAspectRatio <: Equatable<SvgPreserveAspectRatio> & ToString {
    public let align: SvgAspectAlign
    public let slice: Bool

    public init(align: SvgAspectAlign, slice!: Bool = false) {
        this.align = align
        this.slice = slice
    }

    public static let Default = SvgPreserveAspectRatio(SvgAspectAlign.XMidYMid)

    public static func parse(text: String): SvgPreserveAspectRatio {
        let tokens = splitSvgSpaces(text.trimAscii())
        if (tokens.size == 0 || tokens.size > 2) {
            throw invalidValue("preserveAspectRatio 需要 1 或 2 个标记")
        }
        let align = alignFromName(tokens[0])
        var slice = false
        if (tokens.size == 2) {
            match (tokens[1]) {
                case "meet" => slice = false
                case "slice" => slice = true
                case _ => throw invalidValue("未知的 meetOrSlice「${tokens[1]}」")
            }
        }
        SvgPreserveAspectRatio(align, slice: slice)
    }

    /**
     * 按 SVG 1.1 算法计算视口变换：
     * `translate(tx,ty) × scale(sx,sy) × translate(-minX,-minY)`。
     */
    public func toMatrix(viewBox: SvgViewBox, width: Float64, height: Float64): SvgMatrix {
        if (viewBox.width <= 0.0 || viewBox.height <= 0.0 || width <= 0.0 || height <= 0.0) {
            throw invalidValue("退化视口无法计算 preserveAspectRatio")
        }
        let rawScaleX = width / viewBox.width
        let rawScaleY = height / viewBox.height
        var scaleX = rawScaleX
        var scaleY = rawScaleY
        var translateX = 0.0
        var translateY = 0.0
        if (this.align != SvgAspectAlign.NoAlign) {
            let uniform = if (this.slice) {
                if (rawScaleX > rawScaleY) {
                    rawScaleX
                } else {
                    rawScaleY
                }
            } else {
                if (rawScaleX < rawScaleY) {
                    rawScaleX
                } else {
                    rawScaleY
                }
            }
            scaleX = uniform
            scaleY = uniform
            let remainingX = width - viewBox.width * uniform
            let remainingY = height - viewBox.height * uniform
            if (this.align.isXMax()) {
                translateX = remainingX
            } else if (!this.align.isXMin()) {
                translateX = remainingX / 2.0
            }
            if (this.align.isYMax()) {
                translateY = remainingY
            } else if (!this.align.isYMin()) {
                translateY = remainingY / 2.0
            }
        }
        let translated = SvgMatrix.translate(translateX, translateY)
        let scaled = translated.multiply(SvgMatrix.scale(scaleX, scaleY))
        scaled.multiply(SvgMatrix.translate(-viewBox.minX, -viewBox.minY))
    }

    public func toString(): String {
        if (this.align == SvgAspectAlign.NoAlign) {
            "none"
        } else if (this.slice) {
            this.align.toString() + " slice"
        } else {
            this.align.toString() + " meet"
        }
    }

    public operator func ==(that: SvgPreserveAspectRatio): Bool {
        this.align == that.align && this.slice == that.slice
    }

    private static func alignFromName(name: String): SvgAspectAlign {
        match (name) {
            case "none" => SvgAspectAlign.NoAlign
            case "xMinYMin" => SvgAspectAlign.XMinYMin
            case "xMidYMin" => SvgAspectAlign.XMidYMin
            case "xMaxYMin" => SvgAspectAlign.XMaxYMin
            case "xMinYMid" => SvgAspectAlign.XMinYMid
            case "xMidYMid" => SvgAspectAlign.XMidYMid
            case "xMaxYMid" => SvgAspectAlign.XMaxYMid
            case "xMinYMax" => SvgAspectAlign.XMinYMax
            case "xMidYMax" => SvgAspectAlign.XMidYMax
            case "xMaxYMax" => SvgAspectAlign.XMaxYMax
            case _ => throw invalidValue("未知的对齐方式「${name}」")
        }
    }
}
