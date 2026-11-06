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

/** `dominant-baseline` 的取值。 */
public enum SvgDominantBaseline <: Equatable<SvgDominantBaseline> & ToString {
    | Auto
    | Alphabetic
    | Ideographic
    | Middle
    | Central
    | Hanging
    | Mathematical
    | TextBeforeEdge
    | TextAfterEdge

    public operator func ==(that: SvgDominantBaseline): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Alphabetic, Alphabetic) => true
            case (Ideographic, Ideographic) => true
            case (Middle, Middle) => true
            case (Central, Central) => true
            case (Hanging, Hanging) => true
            case (Mathematical, Mathematical) => true
            case (TextBeforeEdge, TextBeforeEdge) => true
            case (TextAfterEdge, TextAfterEdge) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Alphabetic => "alphabetic"
            case Ideographic => "ideographic"
            case Middle => "middle"
            case Central => "central"
            case Hanging => "hanging"
            case Mathematical => "mathematical"
            case TextBeforeEdge => "text-before-edge"
            case TextAfterEdge => "text-after-edge"
        }
    }

    internal static func fromName(name: String): ?SvgDominantBaseline {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "alphabetic" => Some(Alphabetic)
            case "ideographic" => Some(Ideographic)
            case "middle" => Some(Middle)
            case "central" => Some(Central)
            case "hanging" => Some(Hanging)
            case "mathematical" => Some(Mathematical)
            case "text-before-edge" => Some(TextBeforeEdge)
            case "text-after-edge" => Some(TextAfterEdge)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgDominantBaseline {
        match (raw) {
            case Some(text) =>
                match (SvgDominantBaseline.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 auto")
                        Auto
                }
            case None => Auto
        }
    }
}

/** `alignment-baseline` 的取值。 */
public enum SvgAlignmentBaseline <: Equatable<SvgAlignmentBaseline> & ToString {
    | Auto
    | Baseline
    | BeforeEdge
    | TextBeforeEdge
    | Middle
    | Central
    | AfterEdge
    | TextAfterEdge
    | Ideographic
    | Alphabetic
    | Hanging
    | Mathematical

    public operator func ==(that: SvgAlignmentBaseline): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Baseline, Baseline) => true
            case (BeforeEdge, BeforeEdge) => true
            case (TextBeforeEdge, TextBeforeEdge) => true
            case (Middle, Middle) => true
            case (Central, Central) => true
            case (AfterEdge, AfterEdge) => true
            case (TextAfterEdge, TextAfterEdge) => true
            case (Ideographic, Ideographic) => true
            case (Alphabetic, Alphabetic) => true
            case (Hanging, Hanging) => true
            case (Mathematical, Mathematical) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Baseline => "baseline"
            case BeforeEdge => "before-edge"
            case TextBeforeEdge => "text-before-edge"
            case Middle => "middle"
            case Central => "central"
            case AfterEdge => "after-edge"
            case TextAfterEdge => "text-after-edge"
            case Ideographic => "ideographic"
            case Alphabetic => "alphabetic"
            case Hanging => "hanging"
            case Mathematical => "mathematical"
        }
    }

    internal static func fromName(name: String): ?SvgAlignmentBaseline {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "baseline" => Some(Baseline)
            case "before-edge" => Some(BeforeEdge)
            case "text-before-edge" => Some(TextBeforeEdge)
            case "middle" => Some(Middle)
            case "central" => Some(Central)
            case "after-edge" => Some(AfterEdge)
            case "text-after-edge" => Some(TextAfterEdge)
            case "ideographic" => Some(Ideographic)
            case "alphabetic" => Some(Alphabetic)
            case "hanging" => Some(Hanging)
            case "mathematical" => Some(Mathematical)
            case _ => None
        }
    }

    internal static func toDominant(value: SvgAlignmentBaseline): SvgDominantBaseline {
        match (value) {
            case Auto => SvgDominantBaseline.Auto
            case Baseline => SvgDominantBaseline.Alphabetic
            case BeforeEdge => SvgDominantBaseline.TextBeforeEdge
            case TextBeforeEdge => SvgDominantBaseline.TextBeforeEdge
            case Middle => SvgDominantBaseline.Middle
            case Central => SvgDominantBaseline.Central
            case AfterEdge => SvgDominantBaseline.TextAfterEdge
            case TextAfterEdge => SvgDominantBaseline.TextAfterEdge
            case Ideographic => SvgDominantBaseline.Ideographic
            case Alphabetic => SvgDominantBaseline.Alphabetic
            case Hanging => SvgDominantBaseline.Hanging
            case Mathematical => SvgDominantBaseline.Mathematical
        }
    }
}

/** `baseline-shift`：关键字或长度；长度百分比相对 `font-size`。 */
public enum SvgBaselineShift <: Equatable<SvgBaselineShift> & ToString {
    | Baseline
    | Sub
    | Super
    | Length(SvgLength)

    public operator func ==(that: SvgBaselineShift): Bool {
        match ((this, that)) {
            case (Baseline, Baseline) => true
            case (Sub, Sub) => true
            case (Super, Super) => true
            case (Length(left), Length(right)) => left == right
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Baseline => "baseline"
            case Sub => "sub"
            case Super => "super"
            case Length(value) => value.toString()
        }
    }

    internal static func fromName(name: String): ?SvgBaselineShift {
        let trimmed = name.trimAscii()
        match (trimmed.toAsciiLower()) {
            case "baseline" => Some(Baseline)
            case "sub" => Some(Sub)
            case "super" => Some(Super)
            case _ =>
                match (SvgLength.tryParse(trimmed)) {
                    case Some(length) => Some(Length(length))
                    case None => None
                }
        }
    }
}

/** 基线表与 `baseline-shift` 偏移计算。正值向下。 */
public class SvgTextBaseline {
    /** 基线关键字对应的 y 偏移（正值向下）。 */
    public static func offset(
        value: SvgDominantBaseline,
        ascent: Float64,
        descent: Float64,
        fontSize: Float64
    ): Float64 {
        match (value) {
            case Auto | Alphabetic => 0.0 * fontSize
            case TextBeforeEdge => -ascent
            case Hanging => -0.8 * ascent
            case Middle | Central => (descent - ascent) / 2.0
            case Mathematical => -0.5 * ascent
            case Ideographic | TextAfterEdge => descent
        }
    }

    public static func offset(
        value: SvgAlignmentBaseline,
        ascent: Float64,
        descent: Float64,
        fontSize: Float64
    ): Float64 {
        offset(SvgAlignmentBaseline.toDominant(value), ascent, descent, fontSize)
    }

    /** `baseline-shift` 的 y 偏移：关键字按字号比例，正值向上。 */
    public static func shift(value: SvgBaselineShift, fontSize: Float64): Float64 {
        match (value) {
            case Baseline => 0.0
            case Sub => 0.2 * fontSize
            case Super => -0.4 * fontSize
            case Length(length) =>
                let absolute = if (length.unit == SvgLengthUnit.Percent) {
                    length.value / 100.0 * fontSize
                } else {
                    length.value
                }
                -absolute
        }
    }
}
