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

/** `feBlend` 的混合模式。 */
public enum SvgBlendMode <: Equatable<SvgBlendMode> & ToString {
    | Normal
    | Multiply
    | Screen
    | Darken
    | Lighten

    public operator func ==(that: SvgBlendMode): Bool {
        match ((this, that)) {
            case (Normal, Normal) => true
            case (Multiply, Multiply) => true
            case (Screen, Screen) => true
            case (Darken, Darken) => true
            case (Lighten, Lighten) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Normal => "normal"
            case Multiply => "multiply"
            case Screen => "screen"
            case Darken => "darken"
            case Lighten => "lighten"
        }
    }

    internal static func fromName(name: String): ?SvgBlendMode {
        match (name) {
            case "normal" => Some(Normal)
            case "multiply" => Some(Multiply)
            case "screen" => Some(Screen)
            case "darken" => Some(Darken)
            case "lighten" => Some(Lighten)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgBlendMode {
        match (raw) {
            case Some(text) =>
                match (SvgBlendMode.fromName(text.trimAscii())) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 normal")
                        Normal
                }
            case None => Normal
        }
    }
}

/** `feComposite` 的合成算子。 */
public enum SvgCompositeOperator <: Equatable<SvgCompositeOperator> & ToString {
    | Over
    | In
    | Out
    | Atop
    | Xor
    | Arithmetic

    public operator func ==(that: SvgCompositeOperator): Bool {
        match ((this, that)) {
            case (Over, Over) => true
            case (In, In) => true
            case (Out, Out) => true
            case (Atop, Atop) => true
            case (Xor, Xor) => true
            case (Arithmetic, Arithmetic) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Over => "over"
            case In => "in"
            case Out => "out"
            case Atop => "atop"
            case Xor => "xor"
            case Arithmetic => "arithmetic"
        }
    }

    internal static func fromName(name: String): ?SvgCompositeOperator {
        match (name) {
            case "over" => Some(Over)
            case "in" => Some(In)
            case "out" => Some(Out)
            case "atop" => Some(Atop)
            case "xor" => Some(Xor)
            case "arithmetic" => Some(Arithmetic)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgCompositeOperator {
        match (raw) {
            case Some(text) =>
                match (SvgCompositeOperator.fromName(text.trimAscii())) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 over")
                        Over
                }
            case None => Over
        }
    }
}

/** `feColorMatrix` 的矩阵类型。 */
public enum SvgColorMatrixType <: Equatable<SvgColorMatrixType> & ToString {
    | Matrix
    | Saturate
    | HueRotate
    | LuminanceToAlpha

    public operator func ==(that: SvgColorMatrixType): Bool {
        match ((this, that)) {
            case (Matrix, Matrix) => true
            case (Saturate, Saturate) => true
            case (HueRotate, HueRotate) => true
            case (LuminanceToAlpha, LuminanceToAlpha) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Matrix => "matrix"
            case Saturate => "saturate"
            case HueRotate => "hueRotate"
            case LuminanceToAlpha => "luminanceToAlpha"
        }
    }

    internal static func fromName(name: String): ?SvgColorMatrixType {
        match (name) {
            case "matrix" => Some(Matrix)
            case "saturate" => Some(Saturate)
            case "hueRotate" => Some(HueRotate)
            case "luminanceToAlpha" => Some(LuminanceToAlpha)
            case _ => None
        }
    }
}

// TODO(M3-1/M3-2): 滤镜原语基类与八个 fe* 原语模型。
