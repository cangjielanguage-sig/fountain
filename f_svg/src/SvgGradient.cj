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
import std.math.*
import fountain::f_base.*


/** 渐变坐标单位。 */
public enum SvgCoordinateUnits <: Equatable<SvgCoordinateUnits> & ToString {
    | UserSpaceOnUse
    | ObjectBoundingBox

    public operator func ==(that: SvgCoordinateUnits): Bool {
        match ((this, that)) {
            case (UserSpaceOnUse, UserSpaceOnUse) => true
            case (ObjectBoundingBox, ObjectBoundingBox) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case UserSpaceOnUse => "UserSpaceOnUse"
            case ObjectBoundingBox => "ObjectBoundingBox"
        }
    }

    internal func attrName(): String {
        match (this) {
            case UserSpaceOnUse => "userSpaceOnUse"
            case ObjectBoundingBox => "objectBoundingBox"
        }
    }

    internal static func fromName(name: String): ?SvgCoordinateUnits {
        match (name) {
            case "userSpaceOnUse" => Some(UserSpaceOnUse)
            case "objectBoundingBox" => Some(ObjectBoundingBox)
            case _ => None
        }
    }
}

/** 渐变溢出方式。 */
public enum SvgSpreadMethod <: Equatable<SvgSpreadMethod> & ToString {
    | Pad
    | Reflect
    | Repeat

    public operator func ==(that: SvgSpreadMethod): Bool {
        match ((this, that)) {
            case (Pad, Pad) => true
            case (Reflect, Reflect) => true
            case (Repeat, Repeat) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Pad => "Pad"
            case Reflect => "Reflect"
            case Repeat => "Repeat"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Pad => "pad"
            case Reflect => "reflect"
            case Repeat => "repeat"
        }
    }

    internal static func fromName(name: String): ?SvgSpreadMethod {
        match (name) {
            case "pad" => Some(Pad)
            case "reflect" => Some(Reflect)
            case "repeat" => Some(Repeat)
            case _ => None
        }
    }
}

/** 渐变基类。 */
public abstract class SvgGradient <: SvgElement {
    private let unitsCache = SvgValueCache<SvgCoordinateUnits>()
    private let transformCache = SvgValueCache<SvgTransform>()
    private let spreadCache = SvgValueCache<SvgSpreadMethod>()

    protected init(tag: String) {
        super(tag)
    }

    public mut prop gradientUnits: ?SvgCoordinateUnits {
        get() {
            this.unitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("gradientUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(units) => this.setAttr("gradientUnits", units.attrName())
                case None => this.removeAttr("gradientUnits")
            }
        }
    }

    public mut prop gradientTransform: ?SvgTransform {
        get() {
            this.transformCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("gradientTransform")) {
                        case Some(text) => tryParseSvgTransform(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(transform) => this.setAttr("gradientTransform", transform.toString())
                case None => this.removeAttr("gradientTransform")
            }
        }
    }

    public mut prop spreadMethod: ?SvgSpreadMethod {
        get() {
            this.spreadCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("spreadMethod")) {
                        case Some(text) => SvgSpreadMethod.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(method) => this.setAttr("spreadMethod", method.attrName())
                case None => this.removeAttr("spreadMethod")
            }
        }
    }

    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            writeSvgHref(this, value)
        }
    }
}

internal func tryParseSvgTransform(text: String): ?SvgTransform {
    try {
        Some(SvgTransform.parse(text))
    } catch (_: SvgException) {
        None
    }
}

private class GradientStopData {
    let offset: Float64
    let color: SvgColor

    init(offset: Float64, color: SvgColor) {
        this.offset = offset
        this.color = color
    }
}

/**
 * 渐变采样器。
 *
 * `objectBoundingBox` 先把点归一化到单位盒；`gradientTransform` 的逆矩阵在采样前作用；
 * `href` 通过模板链继承属性与 stops，深度上限 64。
 */
public class SvgGradientSampler {
    public let warnings = ArrayList<String>()
    private let root: ?SvgElement

    public init(root!: ?SvgElement = None) {
        this.root = root
    }

    public func sample(
        gradient: SvgGradient,
        point: SvgPoint,
        boundingBox: SvgBounds,
        currentColor: SvgColor
    ): SvgColor {
        let chain = this.resolveChain(gradient)
        if (chain.size == 0) {
            return SvgColor.Black
        }
        let objectUnits = this.effectiveAttr(chain, "gradientUnits") ?? "objectBoundingBox"
        let isObject = objectUnits == "objectBoundingBox"
        let spread = this.effectiveAttr(chain, "spreadMethod") ?? "pad"
        let stops = this.resolveStops(chain, currentColor)
        if (stops.size == 0) {
            return SvgColor.Black
        }
        var gradientPoint = point
        if (isObject) {
            if (boundingBox.width <= 0.0 || boundingBox.height <= 0.0) {
                gradientPoint = SvgPoint(0.0, 0.0)
            } else {
                gradientPoint = SvgPoint(
                    (point.x - boundingBox.x) / boundingBox.width,
                    (point.y - boundingBox.y) / boundingBox.height
                )
            }
        }
        match (this.effectiveAttr(chain, "gradientTransform")) {
            case Some(text) =>
                match (tryParseSvgTransform(text)) {
                    case Some(transform) =>
                        match (transform.toMatrix().invert()) {
                            case Some(inverse) => gradientPoint = inverse.apply(gradientPoint)
                            case None => this.warnings.add("gradientTransform 不可逆，已忽略")
                        }
                    case None => this.warnings.add("gradientTransform 解析失败，已忽略")
                }
            case None => ()
        }
        let t = if (gradient.tag == "linearGradient") {
            this.linearT(chain, gradientPoint, boundingBox, isObject)
        } else {
            this.radialT(chain, gradientPoint, boundingBox, isObject)
        }
        if (t.isNaN()) {
            return SvgColor(0, 0, 0, alpha: 0.0)
        }
        sampleStops(stops, applyGradientSpread(t, spread))
    }

    private func linearT(
        chain: ArrayList<SvgGradient>,
        point: SvgPoint,
        box: SvgBounds,
        isObject: Bool
    ): Float64 {
        let x1 = this.coordinate(chain, "x1", SvgLengthAxis.Horizontal, if (isObject) { 0.0 } else { box.x }, isObject, box)
        let y1 = this.coordinate(chain, "y1", SvgLengthAxis.Vertical, if (isObject) { 0.0 } else { box.y }, isObject, box)
        let x2 = this.coordinate(
            chain,
            "x2",
            SvgLengthAxis.Horizontal,
            if (isObject) { 1.0 } else { box.x + box.width },
            isObject,
            box
        )
        let y2 = this.coordinate(
            chain,
            "y2",
            SvgLengthAxis.Vertical,
            if (isObject) { 0.0 } else { box.y },
            isObject,
            box
        )
        let dx = x2 - x1
        let dy = y2 - y1
        let denominator = dx * dx + dy * dy
        if (denominator < 1e-12) {
            return 1.0
        }
        ((point.x - x1) * dx + (point.y - y1) * dy) / denominator
    }

    private func radialT(
        chain: ArrayList<SvgGradient>,
        point: SvgPoint,
        box: SvgBounds,
        isObject: Bool
    ): Float64 {
        let centerX = if (isObject) { 0.5 } else { box.x + box.width / 2.0 }
        let centerY = if (isObject) { 0.5 } else { box.y + box.height / 2.0 }
        let radiusDefault = if (isObject) {
            0.5
        } else {
            sqrt(box.width * box.width + box.height * box.height) / 1.4142135623730951
        }
        let cx = this.coordinate(chain, "cx", SvgLengthAxis.Horizontal, centerX, isObject, box)
        let cy = this.coordinate(chain, "cy", SvgLengthAxis.Vertical, centerY, isObject, box)
        let r = this.coordinate(chain, "r", SvgLengthAxis.Diagonal, radiusDefault, isObject, box)
        let fx = this.coordinate(chain, "fx", SvgLengthAxis.Horizontal, cx, isObject, box)
        let fy = this.coordinate(chain, "fy", SvgLengthAxis.Vertical, cy, isObject, box)
        if (this.effectiveAttr(chain, "fr").isSome() || this.effectiveAttr(chain, "FR").isSome()) {
            this.warnings.add("径向渐变的 fr / FR 在 M2 忽略")
        }
        if (r <= 0.0) {
            this.warnings.add("径向渐变半径 r <= 0，不绘制")
            return Float64.NaN
        }
        let dx = point.x - fx
        let dy = point.y - fy
        sqrt(dx * dx + dy * dy) / r
    }

    private func coordinate(
        chain: ArrayList<SvgGradient>,
        name: String,
        axis: SvgLengthAxis,
        fallback: Float64,
        isObject: Bool,
        box: SvgBounds
    ): Float64 {
        match (this.effectiveAttr(chain, name)) {
            case Some(text) =>
                match (SvgLength.tryParse(text)) {
                    case Some(length) =>
                        if (isObject) {
                            if (length.unit == SvgLengthUnit.Percent) {
                                return length.value / 100.0
                            }
                            return length.value
                        }
                        if (length.unit == SvgLengthUnit.Percent) {
                            if (axis == SvgLengthAxis.Horizontal) {
                                return box.x + length.value / 100.0 * box.width
                            }
                            if (axis == SvgLengthAxis.Vertical) {
                                return box.y + length.value / 100.0 * box.height
                            }
                            return length.value / 100.0 *
                                sqrt(box.width * box.width + box.height * box.height) / 1.4142135623730951
                        }
                        length.value
                    case None => fallback
                }
            case None => fallback
        }
    }

    private func effectiveAttr(chain: ArrayList<SvgGradient>, name: String): ?String {
        for (gradient in chain) {
            match (gradient.attr(name)) {
                case Some(value) => return Some(value)
                case None => ()
            }
        }
        None
    }

    private func resolveStops(chain: ArrayList<SvgGradient>, currentColor: SvgColor): Array<GradientStopData> {
        var source: ?SvgElement = None
        for (gradient in chain) {
            if (gradient.childrenOf("stop").size > 0) {
                source = Some(gradient)
                break
            }
        }
        let stops = match (source) {
            case Some(element) => element.childrenOf("stop")
            case None => return Array<GradientStopData>()
        }
        let result = ArrayList<GradientStopData>()
        for (stop in stops) {
            let offset = stop.attr("offset") ?? "0"
            let parsedOffset = tryParseSvgOffset(offset) ?? 0.0
            let color = match (stop.attr("stop-color")) {
                case Some(text) =>
                    if (text.trimAscii().toAsciiLower() == "currentcolor") {
                        currentColor
                    } else {
                        SvgColor.tryParse(text) ?? SvgColor.Black
                    }
                case None => SvgColor.Black
            }
            let rawOpacity = match (stop.attr("stop-opacity")) {
                case Some(value) => tryParseSvgFloat(value) ?? 1.0
                case None => 1.0
            }
            let opacity = clampSvgUnit(rawOpacity)
            result.add(
                GradientStopData(
                    parsedOffset,
                    SvgColor(color.red, color.green, color.blue, alpha: clampSvgUnit(color.alpha * opacity))
                )
            )
        }
        let array = result.toArray()
        if (array.size <= 1) {
            return array
        }
        // 稳定插入排序：相同 offset 保持源顺序，采样时后者覆盖前者。
        var index = 1
        while (index < array.size) {
            let value = array[index]
            var position = index - 1
            while (position >= 0 && array[position].offset > value.offset) {
                array[position + 1] = array[position]
                position--
            }
            array[position + 1] = value
            index++
        }
        array
    }

    private func resolveChain(gradient: SvgGradient): ArrayList<SvgGradient> {
        let chain = ArrayList<SvgGradient>()
        let visited = HashMap<String, Bool>()
        var current = gradient
        var depth = 0
        while (true) {
            let node = current
            match (node.attr("id")) {
                        case Some(id) =>
                            if (visited.get(id).isSome()) {
                                this.warnings.add("渐变 href 出现循环引用「${id}」")
                                break
                            }
                            visited[id] = true
                        case None => ()
                    }
                    chain.add(node)
                    if (depth >= 64) {
                        throw SvgException("渐变 href 深度超过 64", kind: SvgErrorKind.Limit)
                    }
                    match (node.href) {
                        case Some(href) =>
                            let target = stripSvgHash(href)
                            if (target.size == 0) {
                                break
                            }
                            match (findGradientById(this.root, target)) {
                                case Some(next) =>
                                    current = next
                                    depth++
                                case None =>
                                    this.warnings.add("渐变 href 目标「${target}」不存在")
                                    break
                            }
                        case None => break
                    }
        }
        chain
    }
}

internal func stripSvgHash(href: String): String {
    let trimmed = href.trimAscii()
    if (trimmed.size > 0 && trimmed[0] == b'#') {
        trimmed[1..]
    } else {
        trimmed
    }
}

internal func findGradientById(element: ?SvgElement, id: String): ?SvgGradient {
    match (element) {
        case Some(node) =>
            if (node.attr("id") == Some(id)) {
                match (node) {
                    case gradient: SvgGradient => return Some(gradient)
                    case _ => ()
                }
            }
            for (child in node.children) {
                match (child) {
                    case ElementNode(next) =>
                        match (findGradientById(Some(next), id)) {
                            case Some(found) => return Some(found)
                            case None => ()
                        }
                    case _ => ()
                }
            }
            None
        case None => None
    }
}

private func applyGradientSpread(value: Float64, spread: String): Float64 {
    if (spread == "repeat") {
        let repeated = fmod(value, 1.0)
        return if (repeated < 0.0) { repeated + 1.0 } else { repeated }
    }
    if (spread == "reflect") {
        var reflected = fmod(value, 2.0)
        if (reflected < 0.0) {
            reflected += 2.0
        }
        return if (reflected > 1.0) { 2.0 - reflected } else { reflected }
    }
    if (value < 0.0) {
        0.0
    } else if (value > 1.0) {
        1.0
    } else {
        value
    }
}

private func sampleStops(stops: Array<GradientStopData>, t: Float64): SvgColor {
    if (stops.size == 0) {
        return SvgColor.Black
    }
    if (t <= stops[0].offset) {
        return stops[0].color
    }
    var lower = stops[0]
    var upper = stops[stops.size - 1]
    var foundUpper = false
    for (stop in stops) {
        if (stop.offset <= t) {
            lower = stop
        } else if (!foundUpper) {
            upper = stop
            foundUpper = true
        }
    }
    if (lower.offset >= t || !foundUpper) {
        return lower.color
    }
    let span = upper.offset - lower.offset
    if (span <= 1e-12) {
        return upper.color
    }
    let local = (t - lower.offset) / span
    SvgColor(
        interpolateSvgChannel(lower.color.red, upper.color.red, local),
        interpolateSvgChannel(lower.color.green, upper.color.green, local),
        interpolateSvgChannel(lower.color.blue, upper.color.blue, local),
        alpha: clampSvgUnit(lower.color.alpha + (upper.color.alpha - lower.color.alpha) * local)
    )
}

private func interpolateSvgChannel(first: UInt8, second: UInt8, t: Float64): UInt8 {
    let value = Float64(first) + (Float64(second) - Float64(first)) * clampSvgUnit(t)
    UInt8(Int64(round(value)))
}
