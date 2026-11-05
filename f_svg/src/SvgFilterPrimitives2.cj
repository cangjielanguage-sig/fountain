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

internal func readSvgNumberList(element: SvgElement, name: String): ?SvgNumberList {
    match (element.attr(name)) {
        case Some(text) =>
            try {
                Some(SvgNumberList.parse(text))
            } catch (_: SvgException) {
                None
            }
        case None => None
    }
}

internal func writeSvgNumberList(element: SvgElement, name: String, value: ?SvgNumberList): Unit {
    match (value) {
        case Some(list) => element.setAttr(name, list.toString())
        case None => element.removeAttr(name)
    }
}

internal func readSvgNumberArray(element: SvgElement, name: String): Array<Float64> {
    match (readSvgNumberList(element, name)) {
        case Some(list) => list.values
        case None => Array<Float64>()
    }
}

internal func writeSvgNumberArray(element: SvgElement, name: String, value: Array<Float64>): Unit {
    element.setAttr(name, SvgNumberList(value).toString())
}

/** `feFunc*` 公用的传递函数参数。 */
public abstract class SvgFeFunc <: SvgElement {
    private let typeCache = SvgValueCache<SvgTransferFunctionType>()
    private let tableCache = SvgValueCache<SvgNumberList>()
    private let slopeCache = SvgValueCache<Float64>()
    private let interceptCache = SvgValueCache<Float64>()
    private let amplitudeCache = SvgValueCache<Float64>()
    private let exponentCache = SvgValueCache<Float64>()
    private let offsetCache = SvgValueCache<Float64>()

    protected init(tag: String) {
        super(tag)
    }

    /** `type` 属性；`type` 在部分上下文为关键字，故命名 `functionType`。 */
    public mut prop functionType: SvgTransferFunctionType {
        get() {
            this.typeCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("type")) {
                        case Some(text) => SvgTransferFunctionType.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgTransferFunctionType.Identity
        }
        set(value) {
            this.setAttr("type", value.toString())
        }
    }

    public mut prop tableValues: Array<Float64> {
        get() {
            match (this.tableCache.get(this.attributesVersion, {=> readSvgNumberList(this, "tableValues")})) {
                case Some(list) => list.values
                case None => Array<Float64>()
            }
        }
        set(value) {
            writeSvgNumberArray(this, "tableValues", value)
        }
    }

    public mut prop slope: Float64 {
        get() {
            this.slopeCache.get(this.attributesVersion, {=> readFloat(this, "slope")}) ?? 1.0
        }
        set(value) {
            writeFloat(this, "slope", Some(value))
        }
    }

    public mut prop intercept: Float64 {
        get() {
            this.interceptCache.get(this.attributesVersion, {=> readFloat(this, "intercept")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "intercept", Some(value))
        }
    }

    public mut prop amplitude: Float64 {
        get() {
            this.amplitudeCache.get(this.attributesVersion, {=> readFloat(this, "amplitude")}) ?? 1.0
        }
        set(value) {
            writeFloat(this, "amplitude", Some(value))
        }
    }

    public mut prop exponent: Float64 {
        get() {
            this.exponentCache.get(this.attributesVersion, {=> readFloat(this, "exponent")}) ?? 1.0
        }
        set(value) {
            writeFloat(this, "exponent", Some(value))
        }
    }

    public mut prop offset: Float64 {
        get() {
            this.offsetCache.get(this.attributesVersion, {=> readFloat(this, "offset")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "offset", Some(value))
        }
    }
}

public class SvgFeFuncR <: SvgFeFunc {
    public init() {
        super("feFuncR")
    }
}

public class SvgFeFuncG <: SvgFeFunc {
    public init() {
        super("feFuncG")
    }
}

public class SvgFeFuncB <: SvgFeFunc {
    public init() {
        super("feFuncB")
    }
}

public class SvgFeFuncA <: SvgFeFunc {
    public init() {
        super("feFuncA")
    }
}

/** `feComponentTransfer`：四个通道函数子元素。 */
public class SvgFeComponentTransfer <: SvgFilterPrimitive {
    public init() {
        super("feComponentTransfer")
    }

    /** 指定通道的函数；缺失返回 `None`。 */
    public func functionFor(channel: SvgChannelSelector): ?SvgFeFunc {
        let tag = match (channel) {
            case R => "feFuncR"
            case G => "feFuncG"
            case B => "feFuncB"
            case A => "feFuncA"
        }
        for (node in this.children) {
            match (node) {
                case ElementNode(element) =>
                    match (element) {
                        case fn: SvgFeFunc => if (fn.tag == tag) {
                            return Some(fn)
                        }
                        case _ => ()
                    }
                case _ => ()
            }
        }
        None
    }
}

/** `feMorphology`。 */
public class SvgFeMorphology <: SvgFilterPrimitive {
    private let operatorCache = SvgValueCache<SvgMorphologyOperator>()
    private let radiusCache = SvgValueCache<SvgNumberList>()

    public init() {
        super("feMorphology")
    }

    public mut prop operatorKind: SvgMorphologyOperator {
        get() {
            this.operatorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("operator")) {
                        case Some(text) => SvgMorphologyOperator.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgMorphologyOperator.Erode
        }
        set(value) {
            this.setAttr("operator", value.toString())
        }
    }

    public mut prop radius: SvgNumberList {
        get() {
            this.radiusCache.get(this.attributesVersion, {=> readSvgNumberList(this, "radius")}) ??
                SvgNumberList(Array<Float64>())
        }
        set(value) {
            writeSvgNumberList(this, "radius", Some(value))
        }
    }
}

/** `feConvolveMatrix`。 */
public class SvgFeConvolveMatrix <: SvgFilterPrimitive {
    private let orderCache = SvgValueCache<SvgNumberList>()
    private let kernelCache = SvgValueCache<SvgNumberList>()
    private let divisorCache = SvgValueCache<Float64>()
    private let biasCache = SvgValueCache<Float64>()
    private let targetXCache = SvgValueCache<Float64>()
    private let targetYCache = SvgValueCache<Float64>()
    private let edgeModeCache = SvgValueCache<SvgEdgeMode>()
    private let preserveAlphaCache = SvgValueCache<Bool>()

    public init() {
        super("feConvolveMatrix")
    }

    public mut prop order: SvgNumberList {
        get() {
            this.orderCache.get(this.attributesVersion, {=> readSvgNumberList(this, "order")}) ??
                SvgNumberList([3.0])
        }
        set(value) {
            writeSvgNumberList(this, "order", Some(value))
        }
    }

    public mut prop kernelMatrix: Array<Float64> {
        get() {
            match (this.kernelCache.get(this.attributesVersion, {=> readSvgNumberList(this, "kernelMatrix")})) {
                case Some(list) => list.values
                case None => Array<Float64>()
            }
        }
        set(value) {
            writeSvgNumberArray(this, "kernelMatrix", value)
        }
    }

    public mut prop divisor: ?Float64 {
        get() {
            this.divisorCache.get(this.attributesVersion, {=> readFloat(this, "divisor")})
        }
        set(value) {
            writeFloat(this, "divisor", value)
        }
    }

    public mut prop bias: Float64 {
        get() {
            this.biasCache.get(this.attributesVersion, {=> readFloat(this, "bias")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "bias", Some(value))
        }
    }

    public mut prop targetX: ?Int64 {
        get() {
            match (this.targetXCache.get(this.attributesVersion, {=> readFloat(this, "targetX")})) {
                case Some(value) => Some(Int64(round(value)))
                case None => None
            }
        }
        set(value) {
            match (value) {
                case Some(number) => writeFloat(this, "targetX", Some(Float64(number)))
                case None => writeFloat(this, "targetX", None)
            }
        }
    }

    public mut prop targetY: ?Int64 {
        get() {
            match (this.targetYCache.get(this.attributesVersion, {=> readFloat(this, "targetY")})) {
                case Some(value) => Some(Int64(round(value)))
                case None => None
            }
        }
        set(value) {
            match (value) {
                case Some(number) => writeFloat(this, "targetY", Some(Float64(number)))
                case None => writeFloat(this, "targetY", None)
            }
        }
    }

    public mut prop edgeMode: SvgEdgeMode {
        get() {
            this.edgeModeCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("edgeMode")) {
                        case Some(text) => SvgEdgeMode.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgEdgeMode.Duplicate
        }
        set(value) {
            this.setAttr("edgeMode", value.toString())
        }
    }

    public mut prop preserveAlpha: Bool {
        get() {
            this.preserveAlphaCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("preserveAlpha")) {
                        case Some(text) =>
                            let lower = text.trimAscii().toAsciiLower()
                            Some(lower == "true" || lower == "1")
                        case None => None
                    }
                }
            ) ?? false
        }
        set(value) {
            this.setAttr("preserveAlpha", if (value) { "true" } else { "false" })
        }
    }
}

/** `feTurbulence`。 */
public class SvgFeTurbulence <: SvgFilterPrimitive {
    private let typeCache = SvgValueCache<SvgTurbulenceType>()
    private let frequencyCache = SvgValueCache<SvgNumberList>()
    private let octavesCache = SvgValueCache<Int64>()
    private let seedCache = SvgValueCache<Float64>()
    private let stitchCache = SvgValueCache<Bool>()

    public init() {
        super("feTurbulence")
    }

    public mut prop turbulenceType: SvgTurbulenceType {
        get() {
            this.typeCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("type")) {
                        case Some(text) => SvgTurbulenceType.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgTurbulenceType.Turbulence
        }
        set(value) {
            this.setAttr("type", value.toString())
        }
    }

    public mut prop baseFrequency: SvgNumberList {
        get() {
            this.frequencyCache.get(
                this.attributesVersion,
                {=> readSvgNumberList(this, "baseFrequency")}
            ) ?? SvgNumberList(Array<Float64>())
        }
        set(value) {
            writeSvgNumberList(this, "baseFrequency", Some(value))
        }
    }

    public mut prop numOctaves: Int64 {
        get() {
            this.octavesCache.get(
                this.attributesVersion,
                {=>
                    match (readFloat(this, "numOctaves")) {
                        case Some(value) => Some(Int64(round(value)))
                        case None => None
                    }
                }
            ) ?? 1
        }
        set(value) {
            writeFloat(this, "numOctaves", Some(Float64(value)))
        }
    }

    public mut prop seed: Float64 {
        get() {
            this.seedCache.get(this.attributesVersion, {=> readFloat(this, "seed")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "seed", Some(value))
        }
    }

    public mut prop stitchTiles: Bool {
        get() {
            this.stitchCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("stitchTiles")) {
                        case Some(text) => Some(text.trimAscii().toAsciiLower() == "stitch")
                        case None => None
                    }
                }
            ) ?? false
        }
        set(value) {
            this.setAttr("stitchTiles", if (value) { "stitch" } else { "noStitch" })
        }
    }
}

/** `feDisplacementMap`。 */
public class SvgFeDisplacementMap <: SvgFilterPrimitive {
    private let scaleCache = SvgValueCache<Float64>()
    private let xCache = SvgValueCache<SvgChannelSelector>()
    private let yCache = SvgValueCache<SvgChannelSelector>()

    public init() {
        super("feDisplacementMap")
    }

    public mut prop in2: ?String {
        get() {
            this.attr("in2")
        }
        set(value) {
            this.writeOptionalAttribute("in2", value)
        }
    }

    public mut prop scale: Float64 {
        get() {
            this.scaleCache.get(this.attributesVersion, {=> readFloat(this, "scale")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "scale", Some(value))
        }
    }

    public mut prop xChannelSelector: SvgChannelSelector {
        get() {
            this.xCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("xChannelSelector")) {
                        case Some(text) => SvgChannelSelector.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgChannelSelector.A
        }
        set(value) {
            this.setAttr("xChannelSelector", value.toString())
        }
    }

    public mut prop yChannelSelector: SvgChannelSelector {
        get() {
            this.yCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("yChannelSelector")) {
                        case Some(text) => SvgChannelSelector.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgChannelSelector.A
        }
        set(value) {
            this.setAttr("yChannelSelector", value.toString())
        }
    }
}

/** `feImage`。 */
public class SvgFeImage <: SvgFilterPrimitive {
    private let aspectCache = SvgValueCache<SvgPreserveAspectRatio>()

    public init() {
        super("feImage")
    }

    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            writeSvgHref(this, value)
        }
    }

    public mut prop preserveAspectRatio: SvgPreserveAspectRatio {
        get() {
            this.aspectCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("preserveAspectRatio")) {
                        case Some(text) => tryParseSvgPreserveAspectRatio(text)
                        case None => None
                    }
                }
            ) ?? SvgPreserveAspectRatio.Default
        }
        set(value) {
            this.setAttr("preserveAspectRatio", value.toString())
        }
    }
}
