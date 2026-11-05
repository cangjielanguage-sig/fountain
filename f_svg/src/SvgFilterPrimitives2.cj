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

/** `feFunc*` 的传递函数类型。 */
public enum SvgTransferFunctionType <: Equatable<SvgTransferFunctionType> & ToString {
    | Identity
    | Table
    | Discrete
    | Linear
    | Gamma

    public operator func ==(that: SvgTransferFunctionType): Bool {
        match ((this, that)) {
            case (Identity, Identity) => true
            case (Table, Table) => true
            case (Discrete, Discrete) => true
            case (Linear, Linear) => true
            case (Gamma, Gamma) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Identity => "identity"
            case Table => "table"
            case Discrete => "discrete"
            case Linear => "linear"
            case Gamma => "gamma"
        }
    }

    internal static func fromName(name: String): ?SvgTransferFunctionType {
        match (name.trimAscii().toAsciiLower()) {
            case "identity" => Some(Identity)
            case "table" => Some(Table)
            case "discrete" => Some(Discrete)
            case "linear" => Some(Linear)
            case "gamma" => Some(Gamma)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgTransferFunctionType {
        match (raw) {
            case Some(text) =>
                match (SvgTransferFunctionType.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 identity")
                        Identity
                }
            case None => Identity
        }
    }
}

/** `feMorphology` 的操作。 */
public enum SvgMorphologyOperator <: Equatable<SvgMorphologyOperator> & ToString {
    | Erode
    | Dilate

    public operator func ==(that: SvgMorphologyOperator): Bool {
        match ((this, that)) {
            case (Erode, Erode) => true
            case (Dilate, Dilate) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Erode => "erode"
            case Dilate => "dilate"
        }
    }

    internal static func fromName(name: String): ?SvgMorphologyOperator {
        match (name.trimAscii().toAsciiLower()) {
            case "erode" => Some(Erode)
            case "dilate" => Some(Dilate)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgMorphologyOperator {
        match (raw) {
            case Some(text) =>
                match (SvgMorphologyOperator.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 erode")
                        Erode
                }
            case None => Erode
        }
    }
}

/**
 * `feConvolveMatrix` 的边界模式。
 *
 * 以类 + 静态常量建模，避免与 `Option.None` 的枚举构造器同名冲突。
 */
public class SvgEdgeMode <: Equatable<SvgEdgeMode> & ToString {
    private let ordinal: Int64

    private init(ordinal: Int64) {
        this.ordinal = ordinal
    }

    public static let Duplicate = SvgEdgeMode(0)
    public static let Wrap = SvgEdgeMode(1)
    public static let NoEdge = SvgEdgeMode(2)

    public operator func ==(that: SvgEdgeMode): Bool {
        this.ordinal == that.ordinal
    }

    public func toString(): String {
        match (this.ordinal) {
            case 0 => "duplicate"
            case 1 => "wrap"
            case _ => "none"
        }
    }

    internal static func fromName(name: String): ?SvgEdgeMode {
        match (name.trimAscii().toAsciiLower()) {
            case "duplicate" => Some(SvgEdgeMode.Duplicate)
            case "wrap" => Some(SvgEdgeMode.Wrap)
            case "none" => Some(SvgEdgeMode.NoEdge)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgEdgeMode {
        match (raw) {
            case Some(text) =>
                match (SvgEdgeMode.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 duplicate")
                        SvgEdgeMode.Duplicate
                }
            case None => SvgEdgeMode.Duplicate
        }
    }
}

/** 位移映射的通道选择器。 */
public enum SvgChannelSelector <: Equatable<SvgChannelSelector> & ToString {
    | R
    | G
    | B
    | A

    public operator func ==(that: SvgChannelSelector): Bool {
        match ((this, that)) {
            case (R, R) => true
            case (G, G) => true
            case (B, B) => true
            case (A, A) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case R => "R"
            case G => "G"
            case B => "B"
            case A => "A"
        }
    }

    internal func channelIndex(): Int64 {
        match (this) {
            case R => 0
            case G => 1
            case B => 2
            case A => 3
        }
    }

    internal static func fromName(name: String): ?SvgChannelSelector {
        match (name.trimAscii().toAsciiLower()) {
            case "r" => Some(R)
            case "g" => Some(G)
            case "b" => Some(B)
            case "a" => Some(A)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgChannelSelector {
        match (raw) {
            case Some(text) =>
                match (SvgChannelSelector.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 A")
                        A
                }
            case None => A
        }
    }
}

/** `feTurbulence` 的噪声类型。 */
public enum SvgTurbulenceType <: Equatable<SvgTurbulenceType> & ToString {
    | FractalNoise
    | Turbulence

    public operator func ==(that: SvgTurbulenceType): Bool {
        match ((this, that)) {
            case (FractalNoise, FractalNoise) => true
            case (Turbulence, Turbulence) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case FractalNoise => "fractalNoise"
            case Turbulence => "turbulence"
        }
    }

    internal static func fromName(name: String): ?SvgTurbulenceType {
        match (name.trimAscii().toAsciiLower()) {
            case "fractalnoise" => Some(FractalNoise)
            case "turbulence" => Some(Turbulence)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgTurbulenceType {
        match (raw) {
            case Some(text) =>
                match (SvgTurbulenceType.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 turbulence")
                        Turbulence
                }
            case None => Turbulence
        }
    }
}

// 原语实现与元素模型在后续任务中补齐。
