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

/** 关键帧插值模式。 */
public enum SvgCalcMode <: Equatable<SvgCalcMode> & ToString {
    | Linear
    | Discrete
    | Spline
    | Paced

    public operator func ==(that: SvgCalcMode): Bool {
        match ((this, that)) {
            case (Linear, Linear) => true
            case (Discrete, Discrete) => true
            case (Spline, Spline) => true
            case (Paced, Paced) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Linear => "Linear"
            case Discrete => "Discrete"
            case Spline => "Spline"
            case Paced => "Paced"
        }
    }

    internal static func fromName(name: String): SvgCalcMode {
        match (name.trimAscii().toAsciiLower()) {
            case "discrete" => Discrete
            case "spline" => Spline
            case "paced" => Paced
            case _ => Linear
        }
    }
}

/** 各类型插值实现。 */
public class SvgInterpolator {
    public static func numeric(from: Float64, to: Float64, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): Float64 {
        if (mode == SvgCalcMode.Discrete) {
            return if (t >= 1.0) { to } else { from }
        }
        from + (to - from) * clampSvgUnit(t)
    }

    public static func numericList(
        from: Array<Float64>,
        to: Array<Float64>,
        t: Float64,
        mode!: SvgCalcMode = SvgCalcMode.Linear
    ): Array<Float64> {
        let count = if (from.size > to.size) { from.size } else { to.size }
        let result = Array<Float64>(count, repeat: 0.0)
        let common = if (from.size < to.size) { from.size } else { to.size }
        for (index in 0..common) {
            result[index] = numeric(from[index], to[index], t, mode: mode)
        }
        for (index in common..count) {
            result[index] = if (from.size > to.size) { from[index] } else { to[index] }
        }
        result
    }

    public static func color(from: SvgColor, to: SvgColor, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): SvgColor {
        if (mode == SvgCalcMode.Discrete) {
            return if (t >= 1.0) { to } else { from }
        }
        let local = clampSvgUnit(t)
        SvgColor(
            interpolateChannel(from.red, to.red, local),
            interpolateChannel(from.green, to.green, local),
            interpolateChannel(from.blue, to.blue, local),
            alpha: clampSvgUnit(from.alpha + (to.alpha - from.alpha) * local)
        )
    }

    /** 路径结构一致时逐坐标插值，否则返回 `None`。 */
    public static func path(from: SvgPathData, to: SvgPathData, t: Float64): ?SvgPathData {
        if (from.commands.size != to.commands.size) {
            return None
        }
        let commands = ArrayList<SvgPathCommand>()
        for (index in 0..from.commands.size) {
            let first = from.commands[index]
            let second = to.commands[index]
            if (first.kind != second.kind || first.relative != second.relative ||
                first.values.size != second.values.size) {
                return None
            }
            let values = Array<Float64>(first.values.size, repeat: 0.0)
            for (valueIndex in 0..first.values.size) {
                let isFlag = first.kind == SvgPathCommandKind.ArcTo && (valueIndex == 3 || valueIndex == 4)
                if (isFlag) {
                    values[valueIndex] = if (t >= 0.5) { second.values[valueIndex] } else { first.values[valueIndex] }
                } else {
                    values[valueIndex] = numeric(first.values[valueIndex], second.values[valueIndex], t)
                }
            }
            commands.add(SvgPathCommand(first.kind, first.relative, values))
        }
        Some(SvgPathData(commands.toArray()))
    }

    /** 字符串 / 枚举只能离散插值。 */
    public static func stringValue(from: String, to: String, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): String {
        if (mode == SvgCalcMode.Discrete || t < 1.0) {
            from
        } else {
            to
        }
    }

    /** 三次贝塞尔缓动：返回 x = t 时的 y。 */
    public static func splineValue(t: Float64, x1: Float64, y1: Float64, x2: Float64, y2: Float64): Float64 {
        let target = clampSvgUnit(t)
        var u = target
        for (_ in 0..10) {
            let x = bezierCoordinate(u, x1, x2)
            let derivative = bezierDerivative(u, x1, x2)
            if (abs(derivative) < 1e-6) {
                break
            }
            let next = u - (x - target) / derivative
            u = if (next < 0.0) { 0.0 } else if (next > 1.0) { 1.0 } else { next }
        }
        bezierCoordinate(u, y1, y2)
    }

    /** 同结构变换逐参数插值；无法分解时返回 `None`。 */
    public static func transform(from: SvgTransform, to: SvgTransform, t: Float64, mode!: SvgCalcMode = SvgCalcMode.Linear): ?SvgTransform {
        if (mode == SvgCalcMode.Discrete) {
            return Some(if (t >= 1.0) { to } else { from })
        }
        if (from.operations.size != to.operations.size) {
            return None
        }
        let operations = ArrayList<SvgTransformOp>()
        for (index in 0..from.operations.size) {
            match ((from.operations[index], to.operations[index])) {
                case (Translate(ax, ay), Translate(bx, by)) =>
                    operations.add(SvgTransformOp.Translate(numeric(ax, bx, t), numeric(ay, by, t)))
                case (Scale(ax, ay), Scale(bx, by)) =>
                    operations.add(SvgTransformOp.Scale(numeric(ax, bx, t), numeric(ay, by, t)))
                case (Rotate(angle1, cx1, cy1), Rotate(angle2, cx2, cy2)) =>
                    operations.add(
                        SvgTransformOp.Rotate(
                            numeric(angle1, angle2, t),
                            numeric(cx1, cx2, t),
                            numeric(cy1, cy2, t)
                        )
                    )
                case (SkewX(angle1), SkewX(angle2)) =>
                    operations.add(SvgTransformOp.SkewX(numeric(angle1, angle2, t)))
                case (SkewY(angle1), SkewY(angle2)) =>
                    operations.add(SvgTransformOp.SkewY(numeric(angle1, angle2, t)))
                case (Matrix(first), Matrix(second)) =>
                    operations.add(
                        SvgTransformOp.Matrix(
                            SvgMatrix(
                                numeric(first.a, second.a, t),
                                numeric(first.b, second.b, t),
                                numeric(first.c, second.c, t),
                                numeric(first.d, second.d, t),
                                numeric(first.e, second.e, t),
                                numeric(first.f, second.f, t)
                            )
                        )
                    )
                case _ => return None
            }
        }
        Some(SvgTransform(operations.toArray()))
    }
}

private func interpolateChannel(first: UInt8, second: UInt8, t: Float64): UInt8 {
    UInt8(Int64(round(Float64(first) + (Float64(second) - Float64(first)) * t)))
}

private func bezierCoordinate(t: Float64, first: Float64, second: Float64): Float64 {
    let mt = 1.0 - t
    3.0 * mt * mt * t * first + 3.0 * mt * t * t * second + t * t * t
}

private func bezierDerivative(t: Float64, first: Float64, second: Float64): Float64 {
    let mt = 1.0 - t
    3.0 * mt * mt * first + 6.0 * mt * t * (second - first) + 3.0 * t * t * (1.0 - second)
}
