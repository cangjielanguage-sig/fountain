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

/** 线段端点样式。 */
public enum SvgLineCap <: Equatable<SvgLineCap> & ToString {
    | Butt
    | Round
    | Square

    public operator func ==(that: SvgLineCap): Bool {
        match ((this, that)) {
            case (Butt, Butt) => true
            case (Round, Round) => true
            case (Square, Square) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Butt => "Butt"
            case Round => "Round"
            case Square => "Square"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Butt => "butt"
            case Round => "round"
            case Square => "square"
        }
    }

    internal static func fromName(name: String): ?SvgLineCap {
        match (name) {
            case "butt" => Some(Butt)
            case "round" => Some(Round)
            case "square" => Some(Square)
            case _ => None
        }
    }
}

/** 线段连接样式。 */
public enum SvgLineJoin <: Equatable<SvgLineJoin> & ToString {
    | Miter
    | Round
    | Bevel
    | MiterClip
    | Arcs

    public operator func ==(that: SvgLineJoin): Bool {
        match ((this, that)) {
            case (Miter, Miter) => true
            case (Round, Round) => true
            case (Bevel, Bevel) => true
            case (MiterClip, MiterClip) => true
            case (Arcs, Arcs) => true
            case _ => false
        }
    }

    /** 与 `attrName()` 一致的规范字符串。 */
    public func toString(): String {
        this.attrName()
    }

    public func attrName(): String {
        match (this) {
            case Miter => "miter"
            case Round => "round"
            case Bevel => "bevel"
            case MiterClip => "miter-clip"
            case Arcs => "arcs"
        }
    }

    internal static func fromName(name: String): ?SvgLineJoin {
        match (name) {
            case "miter" => Some(Miter)
            case "round" => Some(Round)
            case "bevel" => Some(Bevel)
            case "miter-clip" => Some(MiterClip)
            case "arcs" => Some(Arcs)
            case _ => None
        }
    }
}

/** 填充规则。 */
public enum SvgFillRule <: Equatable<SvgFillRule> & ToString {
    | Nonzero
    | Evenodd

    public operator func ==(that: SvgFillRule): Bool {
        match ((this, that)) {
            case (Nonzero, Nonzero) => true
            case (Evenodd, Evenodd) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Nonzero => "Nonzero"
            case Evenodd => "Evenodd"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Nonzero => "nonzero"
            case Evenodd => "evenodd"
        }
    }

    internal static func fromName(name: String): ?SvgFillRule {
        match (name) {
            case "nonzero" => Some(Nonzero)
            case "evenodd" => Some(Evenodd)
            case _ => None
        }
    }
}

/** 形状基类：提供全部公共绘制属性。 */
public abstract class SvgShape <: SvgElement {
    private let fillCache = SvgValueCache<SvgPaint>()
    private let fillOpacityCache = SvgValueCache<Float64>()
    private let strokeCache = SvgValueCache<SvgPaint>()
    private let strokeWidthCache = SvgValueCache<SvgLength>()
    private let strokeOpacityCache = SvgValueCache<Float64>()
    private let strokeLineCapCache = SvgValueCache<SvgLineCap>()
    private let strokeLineJoinCache = SvgValueCache<SvgLineJoin>()
    private let strokeMiterLimitCache = SvgValueCache<Float64>()
    private let strokeDashArrayCache = SvgValueCache<Array<SvgLength>>()
    private let strokeDashOffsetCache = SvgValueCache<SvgLength>()
    private let opacityCache = SvgValueCache<Float64>()
    private let colorCache = SvgValueCache<SvgColor>()
    private let fillRuleCache = SvgValueCache<SvgFillRule>()

    protected init(tag: String) {
        super(tag)
    }

    public mut prop fill: ?SvgPaint {
        get() {
            this.fillCache.get(this.attributesVersion, {=> readPaint(this, "fill")})
        }
        set(value) {
            writePaint(this, "fill", value)
        }
    }

    public mut prop fillOpacity: ?Float64 {
        get() {
            this.fillOpacityCache.get(this.attributesVersion, {=> readFloat(this, "fill-opacity")})
        }
        set(value) {
            writeFloat(this, "fill-opacity", value)
        }
    }

    public mut prop stroke: ?SvgPaint {
        get() {
            this.strokeCache.get(this.attributesVersion, {=> readPaint(this, "stroke")})
        }
        set(value) {
            writePaint(this, "stroke", value)
        }
    }

    public mut prop strokeWidth: ?SvgLength {
        get() {
            this.strokeWidthCache.get(this.attributesVersion, {=> readLength(this, "stroke-width")})
        }
        set(value) {
            writeLength(this, "stroke-width", value)
        }
    }

    public mut prop strokeOpacity: ?Float64 {
        get() {
            this.strokeOpacityCache.get(this.attributesVersion, {=> readFloat(this, "stroke-opacity")})
        }
        set(value) {
            writeFloat(this, "stroke-opacity", value)
        }
    }

    public mut prop strokeLineCap: ?SvgLineCap {
        get() {
            this.strokeLineCapCache.get(this.attributesVersion, {=> readLineCap(this, "stroke-linecap")})
        }
        set(value) {
            match (value) {
                case Some(cap) => this.setAttr("stroke-linecap", cap.attrName())
                case None => this.removeAttr("stroke-linecap")
            }
        }
    }

    public mut prop strokeLineJoin: ?SvgLineJoin {
        get() {
            this.strokeLineJoinCache.get(this.attributesVersion, {=> readLineJoin(this, "stroke-linejoin")})
        }
        set(value) {
            match (value) {
                case Some(join) => this.setAttr("stroke-linejoin", join.attrName())
                case None => this.removeAttr("stroke-linejoin")
            }
        }
    }

    public mut prop strokeMiterLimit: ?Float64 {
        get() {
            this.strokeMiterLimitCache.get(this.attributesVersion, {=> readFloat(this, "stroke-miterlimit")})
        }
        set(value) {
            writeFloat(this, "stroke-miterlimit", value)
        }
    }

    public mut prop strokeDashArray: ?Array<SvgLength> {
        get() {
            this.strokeDashArrayCache.get(this.attributesVersion, {=> readLengthList(this, "stroke-dasharray")})
        }
        set(value) {
            match (value) {
                case Some(list) => this.setAttr("stroke-dasharray", formatSvgLengthList(list))
                case None => this.removeAttr("stroke-dasharray")
            }
        }
    }

    public mut prop strokeDashOffset: ?SvgLength {
        get() {
            this.strokeDashOffsetCache.get(this.attributesVersion, {=> readLength(this, "stroke-dashoffset")})
        }
        set(value) {
            writeLength(this, "stroke-dashoffset", value)
        }
    }

    public mut prop opacity: ?Float64 {
        get() {
            this.opacityCache.get(this.attributesVersion, {=> readFloat(this, "opacity")})
        }
        set(value) {
            writeFloat(this, "opacity", value)
        }
    }

    public mut prop color: ?SvgColor {
        get() {
            this.colorCache.get(this.attributesVersion, {=> readColor(this, "color")})
        }
        set(value) {
            match (value) {
                case Some(color) => this.setAttr("color", color.toString())
                case None => this.removeAttr("color")
            }
        }
    }

    public mut prop fillRule: ?SvgFillRule {
        get() {
            this.fillRuleCache.get(this.attributesVersion, {=> readFillRule(this, "fill-rule")})
        }
        set(value) {
            match (value) {
                case Some(rule) => this.setAttr("fill-rule", rule.attrName())
                case None => this.removeAttr("fill-rule")
            }
        }
    }
}

internal func readPaint(element: SvgElement, name: String): ?SvgPaint {
    match (element.attr(name)) {
        case Some(text) => tryParseSvgPaint(text)
        case None => None
    }
}

internal func writePaint(element: SvgElement, name: String, value: ?SvgPaint): Unit {
    match (value) {
        case Some(paint) => element.setAttr(name, paint.toString())
        case None => element.removeAttr(name)
    }
}

internal func readFloat(element: SvgElement, name: String): ?Float64 {
    match (element.attr(name)) {
        case Some(text) => tryParseSvgFloat(text)
        case None => None
    }
}

internal func writeFloat(element: SvgElement, name: String, value: ?Float64): Unit {
    match (value) {
        case Some(number) => element.setAttr(name, formatSvgNumber(number))
        case None => element.removeAttr(name)
    }
}

internal func readLength(element: SvgElement, name: String): ?SvgLength {
    match (element.attr(name)) {
        case Some(text) => SvgLength.tryParse(text)
        case None => None
    }
}

internal func writeLength(element: SvgElement, name: String, value: ?SvgLength): Unit {
    match (value) {
        case Some(length) => element.setAttr(name, length.toString())
        case None => element.removeAttr(name)
    }
}

internal func readLengthList(element: SvgElement, name: String): ?Array<SvgLength> {
    match (element.attr(name)) {
        case Some(text) => parseSvgLengthList(text)
        case None => None
    }
}

internal func readLineCap(element: SvgElement, name: String): ?SvgLineCap {
    match (element.attr(name)) {
        case Some(text) => SvgLineCap.fromName(text.trimAscii().toAsciiLower())
        case None => None
    }
}

internal func readLineJoin(element: SvgElement, name: String): ?SvgLineJoin {
    match (element.attr(name)) {
        case Some(text) => SvgLineJoin.fromName(text.trimAscii().toAsciiLower())
        case None => None
    }
}

internal func readFillRule(element: SvgElement, name: String): ?SvgFillRule {
    match (element.attr(name)) {
        case Some(text) => SvgFillRule.fromName(text.trimAscii().toAsciiLower())
        case None => None
    }
}

internal func readColor(element: SvgElement, name: String): ?SvgColor {
    match (element.attr(name)) {
        case Some(text) => SvgColor.tryParse(text)
        case None => None
    }
}

internal func readPointList(element: SvgElement, name: String): ?SvgPointList {
    match (element.attr(name)) {
        case Some(text) => tryParseSvgPointList(text)
        case None => None
    }
}

internal func tryParseSvgPointList(text: String): ?SvgPointList {
    try {
        Some(SvgPointList.parse(text))
    } catch (_: SvgException) {
        None
    }
}

internal func tryParseSvgPaint(text: String): ?SvgPaint {
    try {
        Some(SvgPaint.parse(text))
    } catch (_: SvgException) {
        None
    }
}

internal func tryParseSvgFloat(text: String): ?Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        return None
    }
    match (scanSvgNumber(trimmed, 0)) {
        case Some(token) =>
            if (token.end != trimmed.size || token.value.isNaN() || token.value.isInf()) {
                None
            } else {
                Some(token.value)
            }
        case None => None
    }
}

/** 解析 `none` 或逗号 / 空白分隔的长度列表。 */
internal func parseSvgLengthList(text: String): ?Array<SvgLength> {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        return None
    }
    if (trimmed.toAsciiLower() == "none") {
        return None
    }
    match (splitSvgListTokens(trimmed)) {
        case Some(tokens) =>
            let lengths = ArrayList<SvgLength>()
            for (token in tokens) {
                match (SvgLength.tryParse(token)) {
                    case Some(length) => lengths.add(length)
                    case None => return None
                }
            }
            Some(lengths.toArray())
        case None => None
    }
}

internal func formatSvgLengthList(list: Array<SvgLength>): String {
    let out = StringBuilder()
    for (index in 0..list.size) {
        if (index > 0) {
            out.append(",")
        }
        out.append(list[index].toString())
    }
    out.toString()
}

/** 按逗号或空白切分，拒绝双逗号与空项。 */
internal func splitSvgListTokens(text: String): ?ArrayList<String> {
    let parts = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var i = 0
    while (true) {
        i = skipSvgSpaces(bytes, i)
        if (i >= bytes.size) {
            break
        }
        if (bytes[i] == b',') {
            return None
        }
        let start = i
        while (i < bytes.size && !isSvgSpace(bytes[i]) && bytes[i] != b',') {
            i++
        }
        parts.add(text[start..i])
        if (i < bytes.size && bytes[i] == b',') {
            i = skipSvgSpaces(bytes, i + 1)
            if (i >= bytes.size || bytes[i] == b',') {
                return None
            }
        }
    }
    if (parts.size == 0) {
        None
    } else {
        Some(parts)
    }
}
