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

/** 一个变换操作。 */
public enum SvgTransformOp <: Equatable<SvgTransformOp> & ToString {
    | Matrix(SvgMatrix)
    | Translate(Float64, Float64)
    /** `angle, cx, cy` */
    | Rotate(Float64, Float64, Float64)
    | Scale(Float64, Float64)
    | SkewX(Float64)
    | SkewY(Float64)

    public func toMatrix(): SvgMatrix {
        match (this) {
            case Matrix(matrix) => matrix
            case Translate(tx, ty) => SvgMatrix.translate(tx, ty)
            case Rotate(angle, cx, cy) => SvgMatrix.rotateAround(angle, cx, cy)
            case Scale(sx, sy) => SvgMatrix.scale(sx, sy)
            case SkewX(angle) => SvgMatrix.skewX(angle)
            case SkewY(angle) => SvgMatrix.skewY(angle)
        }
    }

    public func toString(): String {
        match (this) {
            case Matrix(matrix) => "matrix(${matrix.toString().replace(",", " ")})"
            case Translate(tx, ty) =>
                if (ty == 0.0) {
                    "translate(${formatSvgNumber(tx)})"
                } else {
                    "translate(${formatSvgNumber(tx)} ${formatSvgNumber(ty)})"
                }
            case Rotate(angle, cx, cy) =>
                if (cx == 0.0 && cy == 0.0) {
                    "rotate(${formatSvgNumber(angle)})"
                } else {
                    "rotate(${formatSvgNumber(angle)} ${formatSvgNumber(cx)} ${formatSvgNumber(cy)})"
                }
            case Scale(sx, sy) =>
                if (sx == sy) {
                    "scale(${formatSvgNumber(sx)})"
                } else {
                    "scale(${formatSvgNumber(sx)} ${formatSvgNumber(sy)})"
                }
            case SkewX(angle) => "skewX(${formatSvgNumber(angle)})"
            case SkewY(angle) => "skewY(${formatSvgNumber(angle)})"
        }
    }

    public operator func ==(that: SvgTransformOp): Bool {
        match ((this, that)) {
            case (Matrix(left), Matrix(right)) => left == right
            case (Translate(tx1, ty1), Translate(tx2, ty2)) => tx1 == tx2 && ty1 == ty2
            case (Rotate(a1, cx1, cy1), Rotate(a2, cx2, cy2)) => a1 == a2 && cx1 == cx2 && cy1 == cy2
            case (Scale(sx1, sy1), Scale(sx2, sy2)) => sx1 == sx2 && sy1 == sy2
            case (SkewX(a1), SkewX(a2)) => a1 == a2
            case (SkewY(a1), SkewY(a2)) => a1 == a2
            case _ => false
        }
    }
}

/**
 * `transform` 属性：有序的变换列表。
 *
 * 合成顺序为 `A B C` ⇒ `A × B × C`，即最后书写的变换最先作用于坐标。
 */
public struct SvgTransform <: Equatable<SvgTransform> & ToString {
    public let operations: Array<SvgTransformOp>

    public init(operations: Array<SvgTransformOp>) {
        this.operations = operations
    }

    public static let identity = SvgTransform(Array<SvgTransformOp>())

    public static func parse(text: String): SvgTransform {
        let trimmed = text.trimAscii()
        if (trimmed.size == 0) {
            return identity
        }
        let bytes = trimmed.unsafeBytes()
        let operations = ArrayList<SvgTransformOp>()
        var i = 0
        while (true) {
            i = skipSvgSpaces(bytes, i)
            if (i >= bytes.size) {
                break
            }
            if (bytes[i] == b',') {
                throw invalidValue("变换列表出现多余的逗号")
            }
            let nameStart = i
            while (i < bytes.size && isSvgAlpha(bytes[i])) {
                i++
            }
            if (i == nameStart) {
                throw invalidValue("无法识别的变换「${trimmed[nameStart..trimmed.size]}」")
            }
            let name = trimmed[nameStart..i]
            i = skipSvgSpaces(bytes, i)
            if (i >= bytes.size || bytes[i] != b'(') {
                throw invalidValue("变换「${name}」缺少左括号")
            }
            i++
            var close = i
            while (close < bytes.size && bytes[close] != b')') {
                close++
            }
            if (close >= bytes.size) {
                throw invalidValue("变换「${name}」缺少右括号")
            }
            let values = parseTransformArgs(trimmed[i..close])
            operations.add(buildOperation(name, values))
            i = close + 1
            i = skipSvgSpaces(bytes, i)
            if (i < bytes.size && bytes[i] == b',') {
                i = skipSvgSpaces(bytes, i + 1)
                if (i >= bytes.size || bytes[i] == b',') {
                    throw invalidValue("变换列表出现多余的逗号")
                }
            }
        }
        SvgTransform(operations.toArray())
    }

    public func toMatrix(): SvgMatrix {
        var result = SvgMatrix.identity
        for (operation in this.operations) {
            result = result.multiply(operation.toMatrix())
        }
        result
    }

    public func toString(): String {
        let out = StringBuilder()
        for (index in 0..this.operations.size) {
            if (index > 0) {
                out.append(" ")
            }
            out.append(this.operations[index].toString())
        }
        out.toString()
    }

    public operator func ==(that: SvgTransform): Bool {
        this.operations == that.operations
    }
}

private func parseTransformArgs(content: String): Array<Float64> {
    let values = ArrayList<Float64>()
    let bytes = content.unsafeBytes()
    var i = 0
    while (true) {
        i = skipSvgSpaces(bytes, i)
        if (i >= bytes.size) {
            break
        }
        match (scanSvgNumber(content, i)) {
            case Some(token) =>
                values.add(requireFinite(token.value, "变换参数"))
                i = token.end
            case None => throw invalidValue("变换参数不是合法数字「${content}」")
        }
        i = skipSvgSpaces(bytes, i)
        if (i >= bytes.size) {
            break
        }
        if (bytes[i] == b',') {
            i = skipSvgSpaces(bytes, i + 1)
            if (i >= bytes.size || bytes[i] == b',') {
                throw invalidValue("变换参数出现多余的逗号")
            }
        } else if (!isNumberStart(bytes[i])) {
            throw invalidValue("变换参数不是合法数字「${content}」")
        }
    }
    values.toArray()
}

internal func isNumberStart(byte: Byte): Bool {
    isSvgDigit(byte) || byte == b'+' || byte == b'-' || byte == b'.'
}

private func buildOperation(name: String, values: Array<Float64>): SvgTransformOp {
    match (name) {
        case "matrix" =>
            expectArgCount(name, values, 6)
            SvgTransformOp.Matrix(
                SvgMatrix(values[0], values[1], values[2], values[3], values[4], values[5])
            )
        case "translate" =>
            if (values.size == 1) {
                SvgTransformOp.Translate(values[0], 0.0)
            } else if (values.size == 2) {
                SvgTransformOp.Translate(values[0], values[1])
            } else {
                throw invalidValue("translate 需要 1 或 2 个参数，实际 ${values.size} 个")
            }
        case "scale" =>
            if (values.size == 1) {
                SvgTransformOp.Scale(values[0], values[0])
            } else if (values.size == 2) {
                SvgTransformOp.Scale(values[0], values[1])
            } else {
                throw invalidValue("scale 需要 1 或 2 个参数，实际 ${values.size} 个")
            }
        case "rotate" =>
            if (values.size == 1) {
                SvgTransformOp.Rotate(values[0], 0.0, 0.0)
            } else if (values.size == 3) {
                SvgTransformOp.Rotate(values[0], values[1], values[2])
            } else {
                throw invalidValue("rotate 需要 1 或 3 个参数，实际 ${values.size} 个")
            }
        case "skewX" =>
            expectArgCount(name, values, 1)
            SvgTransformOp.SkewX(values[0])
        case "skewY" =>
            expectArgCount(name, values, 1)
            SvgTransformOp.SkewY(values[0])
        case _ => throw invalidValue("未知的变换函数「${name}」")
    }
}

private func expectArgCount(name: String, values: Array<Float64>, expected: Int64): Unit {
    if (values.size != expected) {
        throw invalidValue("${name} 需要 ${expected} 个参数，实际 ${values.size} 个")
    }
}
