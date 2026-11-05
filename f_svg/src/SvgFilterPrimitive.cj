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

/** 滤镜原语基类：`in` 与 `result` 图连接属性。 */
public abstract class SvgFilterPrimitive <: SvgElement {
    protected init(tag: String) {
        super(tag)
    }

    public mut prop inSource: ?String {
        get() {
            this.attr("in")
        }
        set(value) {
            this.writeOptionalAttribute("in", value)
        }
    }

    public mut prop result: ?String {
        get() {
            this.attr("result")
        }
        set(value) {
            this.writeOptionalAttribute("result", value)
        }
    }
}

/** `feGaussianBlur` 原语。 */
public class SvgFeGaussianBlur <: SvgFilterPrimitive {
    private let deviationCache = SvgValueCache<SvgNumberList>()

    public init() {
        super("feGaussianBlur")
    }

    public mut prop stdDeviation: SvgNumberList {
        get() {
            this.deviationCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("stdDeviation")) {
                        case Some(text) =>
                            try {
                                SvgNumberList.parse(text)
                            } catch (_: SvgException) {
                                SvgNumberList(Array<Float64>())
                            }
                        case None => SvgNumberList(Array<Float64>())
                    }
                }
            ) ?? SvgNumberList(Array<Float64>())
        }
        set(value) {
            this.setAttr("stdDeviation", value.toString())
        }
    }
}

/** `feOffset` 原语。 */
public class SvgFeOffset <: SvgFilterPrimitive {
    private let dxCache = SvgValueCache<SvgLength>()
    private let dyCache = SvgValueCache<SvgLength>()

    public init() {
        super("feOffset")
    }

    public mut prop dx: SvgLength {
        get() {
            this.dxCache.get(this.attributesVersion, {=> readLength(this, "dx")}) ?? SvgLength(0.0)
        }
        set(value) {
            writeLength(this, "dx", Some(value))
        }
    }

    public mut prop dy: SvgLength {
        get() {
            this.dyCache.get(this.attributesVersion, {=> readLength(this, "dy")}) ?? SvgLength(0.0)
        }
        set(value) {
            writeLength(this, "dy", Some(value))
        }
    }
}

/** `feFlood` 原语。 */
public class SvgFeFlood <: SvgFilterPrimitive {
    private let colorCache = SvgValueCache<SvgPaint>()
    private let opacityCache = SvgValueCache<Float64>()

    public init() {
        super("feFlood")
    }

    public mut prop floodColor: SvgPaint {
        get() {
            this.colorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("flood-color")) {
                        case Some(text) => tryParseSvgPaint(text)
                        case None => None
                    }
                }
            ) ?? SvgPaint.of(SvgColor.Black)
        }
        set(value) {
            this.setAttr("flood-color", value.toString())
        }
    }

    public mut prop floodOpacity: Float64 {
        get() {
            this.opacityCache.get(this.attributesVersion, {=> readFloat(this, "flood-opacity")}) ?? 1.0
        }
        set(value) {
            writeFloat(this, "flood-opacity", Some(clampSvgUnit(value)))
        }
    }
}

/** `feBlend` 原语。 */
public class SvgFeBlend <: SvgFilterPrimitive {
    private let modeCache = SvgValueCache<SvgBlendMode>()

    public init() {
        super("feBlend")
    }

    public mut prop in2: ?String {
        get() {
            this.attr("in2")
        }
        set(value) {
            this.writeOptionalAttribute("in2", value)
        }
    }

    public mut prop mode: SvgBlendMode {
        get() {
            this.modeCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("mode")) {
                        case Some(text) => SvgBlendMode.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgBlendMode.Normal
        }
        set(value) {
            this.setAttr("mode", value.toString())
        }
    }
}

/** `feComposite` 原语。 */
public class SvgFeComposite <: SvgFilterPrimitive {
    private let operatorCache = SvgValueCache<SvgCompositeOperator>()
    private let k1Cache = SvgValueCache<Float64>()
    private let k2Cache = SvgValueCache<Float64>()
    private let k3Cache = SvgValueCache<Float64>()
    private let k4Cache = SvgValueCache<Float64>()

    public init() {
        super("feComposite")
    }

    public mut prop in2: ?String {
        get() {
            this.attr("in2")
        }
        set(value) {
            this.writeOptionalAttribute("in2", value)
        }
    }

    /** `operator` 属性；`operator` 是语言关键字，故命名为 `operatorKind`。 */
    public mut prop operatorKind: SvgCompositeOperator {
        get() {
            this.operatorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("operator")) {
                        case Some(text) => SvgCompositeOperator.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgCompositeOperator.Over
        }
        set(value) {
            this.setAttr("operator", value.toString())
        }
    }

    public mut prop k1: Float64 {
        get() {
            this.k1Cache.get(this.attributesVersion, {=> readFloat(this, "k1")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "k1", Some(value))
        }
    }

    public mut prop k2: Float64 {
        get() {
            this.k2Cache.get(this.attributesVersion, {=> readFloat(this, "k2")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "k2", Some(value))
        }
    }

    public mut prop k3: Float64 {
        get() {
            this.k3Cache.get(this.attributesVersion, {=> readFloat(this, "k3")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "k3", Some(value))
        }
    }

    public mut prop k4: Float64 {
        get() {
            this.k4Cache.get(this.attributesVersion, {=> readFloat(this, "k4")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "k4", Some(value))
        }
    }
}

/** `feMerge` 原语：子节点为 `feMergeNode` 序列。 */
public class SvgFeMerge <: SvgFilterPrimitive {
    public init() {
        super("feMerge")
    }

    /** 按子节点顺序读取各 `feMergeNode` 的 `in`；缺省为空字符串。 */
    public prop inputs: ArrayList<String> {
        get() {
            let result = ArrayList<String>()
            for (node in this.children) {
                match (node) {
                    case ElementNode(element) =>
                        match (element) {
                            case mergeNode: SvgFeMergeNode => result.add(mergeNode.inSource ?? "")
                            case _ => ()
                        }
                    case _ => ()
                }
            }
            result
        }
    }
}

/** `feMergeNode` 子元素。 */
public class SvgFeMergeNode <: SvgElement {
    public init() {
        super("feMergeNode")
    }

    public mut prop inSource: ?String {
        get() {
            this.attr("in")
        }
        set(value) {
            this.writeOptionalAttribute("in", value)
        }
    }
}

/** `feColorMatrix` 原语。 */
public class SvgFeColorMatrix <: SvgFilterPrimitive {
    private let typeCache = SvgValueCache<SvgColorMatrixType>()
    private let valuesCache = SvgValueCache<Array<Float64>>()

    public init() {
        super("feColorMatrix")
    }

    public mut prop matrixType: SvgColorMatrixType {
        get() {
            this.typeCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("type")) {
                        case Some(text) => SvgColorMatrixType.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgColorMatrixType.Matrix
        }
        set(value) {
            this.setAttr("type", value.toString())
        }
    }

    public mut prop values: Array<Float64> {
        get() {
            this.valuesCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("values")) {
                        case Some(text) =>
                            try {
                                Some(SvgNumberList.parse(text).values)
                            } catch (_: SvgException) {
                                Some(Array<Float64>())
                            }
                        case None => None
                    }
                }
            ) ?? Array<Float64>()
        }
        set(value) {
            this.setAttr("values", SvgNumberList(value).toString())
        }
    }
}

/** `feTile` 原语。 */
public class SvgFeTile <: SvgFilterPrimitive {
    public init() {
        super("feTile")
    }
}
