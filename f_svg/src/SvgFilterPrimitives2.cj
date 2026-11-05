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

// ---------------------------------------------------------------------------
// 新原语实现：每个原语读取输入缓冲并返回新缓冲，不原地修改。
// ---------------------------------------------------------------------------

internal func componentTransferFilterBuffer(
    input: SvgFilterBuffer,
    transfer: SvgFeComponentTransfer,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let functions: Array<?SvgFeFunc> = [
        transfer.functionFor(SvgChannelSelector.R),
        transfer.functionFor(SvgChannelSelector.G),
        transfer.functionFor(SvgChannelSelector.B),
        transfer.functionFor(SvgChannelSelector.A)
    ]
    let output = SvgFilterBuffer(input.width, input.height)
    var index = 0
    while (index < input.pixels.size) {
        var channel = 0
        while (channel < 4) {
            let source = Float64(input.pixels[index + channel]) / 255.0
            let mapped = transferChannel(source, functions[channel], warnings, channel)
            output.pixels[index + channel] = UInt8(Int64(round(clampSvgUnit(mapped) * 255.0)))
            channel++
        }
        index += 4
    }
    output
}

private func transferChannel(
    value: Float64,
    function: ?SvgFeFunc,
    warnings: ArrayList<String>,
    channel: Int64
): Float64 {
    let fn = match (function) {
        case Some(value) => value
        case None => return value
    }
    match (fn.functionType) {
        case Identity => value
        case Table =>
            let values = fn.tableValues
            if (values.size == 0) {
                warnings.add("feFunc 通道 ${channel} 的 tableValues 为空，按 identity 处理")
                return value
            }
            if (values.size == 1) {
                return values[0]
            }
            let scaled = clampSvgUnit(value) * Float64(values.size - 1)
            let lower = Int64(floor(scaled))
            let upper = if (lower + 1 < values.size) { lower + 1 } else { lower }
            let fraction = scaled - Float64(lower)
            values[lower] * (1.0 - fraction) + values[upper] * fraction
        case Discrete =>
            let values = fn.tableValues
            if (values.size == 0) {
                warnings.add("feFunc 通道 ${channel} 的 tableValues 为空，按 identity 处理")
                return value
            }
            var category = Int64(floor(clampSvgUnit(value) * Float64(values.size)))
            if (category >= values.size) {
                category = values.size - 1
            }
            values[category]
        case Linear =>
            let slope = fn.slope
            let intercept = fn.intercept
            if (!isFiniteSvgNumber(slope) || !isFiniteSvgNumber(intercept)) {
                warnings.add("feFunc 通道 ${channel} 的 linear 参数非有限，按 identity 处理")
                value
            } else {
                slope * value + intercept
            }
        case Gamma =>
            let amplitude = fn.amplitude
            let exponent = fn.exponent
            let offset = fn.offset
            if (!isFiniteSvgNumber(amplitude) || !isFiniteSvgNumber(exponent) ||
                !isFiniteSvgNumber(offset)) {
                warnings.add("feFunc 通道 ${channel} 的 gamma 参数非有限，按 identity 处理")
                value
            } else {
                let base = if (value > 0.0) { value } else { 0.0 }
                amplitude * pow(base, exponent) + offset
            }
    }
}

internal func morphologyFilterBuffer(
    input: SvgFilterBuffer,
    morphology: SvgFeMorphology,
    scaleX: Float64,
    scaleY: Float64,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let values = morphology.radius.values
    var radiusX = if (values.size > 0) { values[0] } else { 0.0 }
    var radiusY = if (values.size > 1) { values[1] } else { radiusX }
    if (!isFiniteSvgNumber(radiusX) || !isFiniteSvgNumber(radiusY)) {
        warnings.add("feMorphology 的 radius 非有限，按 0 处理")
        radiusX = 0.0
        radiusY = 0.0
    }
    if (radiusX < 0.0 || radiusY < 0.0) {
        warnings.add("feMorphology 的 radius 含负值，按 0 处理")
        radiusX = if (radiusX > 0.0) { radiusX } else { 0.0 }
        radiusY = if (radiusY > 0.0) { radiusY } else { 0.0 }
    }
    let pixelRadiusX = Int64(round(radiusX * scaleX))
    let pixelRadiusY = Int64(round(radiusY * scaleY))
    if (pixelRadiusX <= 0 && pixelRadiusY <= 0) {
        return input.copy()
    }
    let erode = morphology.operatorKind == SvgMorphologyOperator.Erode
    let output = SvgFilterBuffer(input.width, input.height)
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            var channel = 0
            while (channel < 4) {
                var extreme: Int64 = if (erode) { 255 } else { 0 }
                var offsetY = -pixelRadiusY
                while (offsetY <= pixelRadiusY) {
                    let sampleY = y + offsetY
                    if (sampleY >= 0 && sampleY < input.height) {
                        var offsetX = -pixelRadiusX
                        while (offsetX <= pixelRadiusX) {
                            let sampleX = x + offsetX
                            if (sampleX >= 0 && sampleX < input.width) {
                                let value = Int64(
                                    input.pixels[(sampleY * input.width + sampleX) * 4 + channel]
                                )
                                if (erode) {
                                    if (value < extreme) {
                                        extreme = value
                                    }
                                } else {
                                    if (value > extreme) {
                                        extreme = value
                                    }
                                }
                            }
                            offsetX++
                        }
                    }
                    offsetY++
                }
                output.pixels[(y * input.width + x) * 4 + channel] = UInt8(extreme)
                channel++
            }
            x++
        }
        y++
    }
    output
}

internal func convolveFilterBuffer(
    input: SvgFilterBuffer,
    convolve: SvgFeConvolveMatrix,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let orderValues = convolve.order.values
    var orderX: Int64 = 3
    var orderY: Int64 = 3
    if (orderValues.size == 1) {
        orderX = Int64(round(orderValues[0]))
        orderY = orderX
    } else if (orderValues.size >= 2) {
        orderX = Int64(round(orderValues[0]))
        orderY = Int64(round(orderValues[1]))
    }
    if (orderX <= 0 || orderY <= 0) {
        warnings.add("feConvolveMatrix 的 order 非正整数，按直通处理")
        return input.copy()
    }
    // 上限在分配任何缓冲之前检查。
    if (orderX > 9 || orderY > 9) {
        throw SvgException(
            "feConvolveMatrix 的 order 超过 9×9 上限，实际 ${orderX}×${orderY}",
            kind: SvgErrorKind.Limit
        )
    }
    let kernel = convolve.kernelMatrix
    if (Int64(kernel.size) != orderX * orderY) {
        warnings.add(
            "feConvolveMatrix 的 kernelMatrix 长度 ${kernel.size} 与 order ${orderX}×${orderY} 不符，按直通处理"
        )
        return input.copy()
    }
    for (value in kernel) {
        if (!isFiniteSvgNumber(value)) {
            warnings.add("feConvolveMatrix 的 kernelMatrix 含非有限值，按直通处理")
            return input.copy()
        }
    }
    var divisor = match (convolve.divisor) {
        case Some(value) => value
        case None =>
            var sum = 0.0
            for (value in kernel) {
                sum += value
            }
            sum
    }
    if (!isFiniteSvgNumber(divisor) || divisor == 0.0) {
        divisor = 1.0
    }
    var bias = convolve.bias
    if (!isFiniteSvgNumber(bias)) {
        warnings.add("feConvolveMatrix 的 bias 非有限，按 0 处理")
        bias = 0.0
    }
    var targetX = match (convolve.targetX) {
        case Some(value) => value
        case None => orderX / 2
    }
    var targetY = match (convolve.targetY) {
        case Some(value) => value
        case None => orderY / 2
    }
    if (targetX < 0 || targetX >= orderX) {
        targetX = orderX / 2
    }
    if (targetY < 0 || targetY >= orderY) {
        targetY = orderY / 2
    }
    let preserveAlpha = convolve.preserveAlpha
    let output = SvgFilterBuffer(input.width, input.height)
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            let channelLimit = if (preserveAlpha) { 3 } else { 4 }
            var channel = 0
            while (channel < channelLimit) {
                var sum = 0.0
                var kernelY = 0
                while (kernelY < orderY) {
                    var kernelX = 0
                    while (kernelX < orderX) {
                        let sampleX = x - targetX + kernelX
                        let sampleY = y - targetY + kernelY
                        let sample = convolveSample(input, sampleX, sampleY, channel, convolve.edgeMode)
                        sum += sample * kernel[kernelY * orderX + kernelX]
                        kernelX++
                    }
                    kernelY++
                }
                let value = sum / divisor + bias * 255.0
                output.pixels[(y * input.width + x) * 4 + channel] = UInt8(
                    Int64(round(clampSvgUnit(value / 255.0) * 255.0))
                )
                channel++
            }
            if (preserveAlpha) {
                let base = (y * input.width + x) * 4
                output.pixels[base + 3] = input.pixels[base + 3]
            }
            x++
        }
        y++
    }
    output
}

private func convolveSample(
    input: SvgFilterBuffer,
    x: Int64,
    y: Int64,
    channel: Int64,
    edgeMode: SvgEdgeMode
): Float64 {
    var sampleX = x
    var sampleY = y
    if (sampleX < 0 || sampleX >= input.width || sampleY < 0 || sampleY >= input.height) {
        if (edgeMode == SvgEdgeMode.NoEdge) {
            return 0.0
        }
        if (edgeMode == SvgEdgeMode.Wrap) {
            sampleX = positiveSvgMod(sampleX, input.width)
            sampleY = positiveSvgMod(sampleY, input.height)
        } else {
            sampleX = clampSvgIndex(sampleX, input.width)
            sampleY = clampSvgIndex(sampleY, input.height)
        }
    }
    Float64(input.pixels[(sampleY * input.width + sampleX) * 4 + channel])
}

private func positiveSvgMod(value: Int64, modulus: Int64): Int64 {
    let remainder = value % modulus
    if (remainder < 0) {
        remainder + modulus
    } else {
        remainder
    }
}

private func clampSvgIndex(value: Int64, size: Int64): Int64 {
    if (value < 0) {
        return 0
    }
    if (value >= size) {
        return size - 1
    }
    value
}

internal func turbulenceFilterBuffer(
    input: SvgFilterBuffer,
    turbulence: SvgFeTurbulence,
    scaleX: Float64,
    scaleY: Float64,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    var octaves = turbulence.numOctaves
    if (octaves > 8) {
        throw SvgException(
            "feTurbulence 的 numOctaves 超过 8 上限，实际 ${octaves}",
            kind: SvgErrorKind.Limit
        )
    }
    if (octaves < 1) {
        warnings.add("feTurbulence 的 numOctaves 小于 1，按 1 处理")
        octaves = 1
    }
    let frequencyValues = turbulence.baseFrequency.values
    var frequencyX = if (frequencyValues.size > 0) { frequencyValues[0] } else { 0.0 }
    var frequencyY = if (frequencyValues.size > 1) { frequencyValues[1] } else { frequencyX }
    if (!isFiniteSvgNumber(frequencyX) || !isFiniteSvgNumber(frequencyY) ||
        frequencyX < 0.0 || frequencyY < 0.0) {
        warnings.add("feTurbulence 的 baseFrequency 非法，按 0 处理")
        frequencyX = 0.0
        frequencyY = 0.0
    }
    let seedValue = turbulence.seed
    let seed = if (isFiniteSvgNumber(seedValue)) { Int64(round(seedValue)) } else { 0 }
    let fractal = turbulence.turbulenceType == SvgTurbulenceType.FractalNoise
    let output = SvgFilterBuffer(input.width, input.height)
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            var value = 0.0
            var totalAmplitude = 0.0
            var amplitude = 1.0
            var octaveFrequencyX = frequencyX / scaleX
            var octaveFrequencyY = frequencyY / scaleY
            var octave: Int64 = 0
            while (octave < octaves) {
                let noise = perlinSvgNoise(
                    Float64(x) * octaveFrequencyX,
                    Float64(y) * octaveFrequencyY,
                    seed + octave * 1013
                )
                if (fractal) {
                    value += noise * amplitude
                } else {
                    value += abs(noise) * amplitude
                }
                totalAmplitude += amplitude
                amplitude *= 0.5
                octaveFrequencyX *= 2.0
                octaveFrequencyY *= 2.0
                octave++
            }
            if (totalAmplitude > 0.0) {
                value = value / totalAmplitude
            }
            if (fractal) {
                value = 0.5 + 0.5 * value
            }
            let channel = UInt8(Int64(round(clampSvgUnit(value) * 255.0)))
            let base = (y * input.width + x) * 4
            output.pixels[base] = channel
            output.pixels[base + 1] = channel
            output.pixels[base + 2] = channel
            output.pixels[base + 3] = 255
            x++
        }
        y++
    }
    output
}

private func perlinSvgNoise(x: Float64, y: Float64, seed: Int64): Float64 {
    let x0 = Int64(floor(x))
    let y0 = Int64(floor(y))
    let fractionX = x - Float64(x0)
    let fractionY = y - Float64(y0)
    let smoothX = fractionX * fractionX * (3.0 - 2.0 * fractionX)
    let smoothY = fractionY * fractionY * (3.0 - 2.0 * fractionY)
    let n00 = svgGradientDot(x0, y0, fractionX, fractionY, seed)
    let n10 = svgGradientDot(x0 + 1, y0, fractionX - 1.0, fractionY, seed)
    let n01 = svgGradientDot(x0, y0 + 1, fractionX, fractionY - 1.0, seed)
    let n11 = svgGradientDot(x0 + 1, y0 + 1, fractionX - 1.0, fractionY - 1.0, seed)
    let lower = n00 * (1.0 - smoothX) + n10 * smoothX
    let upper = n01 * (1.0 - smoothX) + n11 * smoothX
    lower * (1.0 - smoothY) + upper * smoothY
}

private func svgGradientDot(
    x: Int64,
    y: Int64,
    offsetX: Float64,
    offsetY: Float64,
    seed: Int64
): Float64 {
    let hash = svgNoiseHash(x, y, seed)
    let angle = Float64(hash & 0xFFFF) / 65536.0 * 2.0 * 3.141592653589793
    let gradientX = cos(angle)
    let gradientY = sin(angle)
    gradientX * offsetX + gradientY * offsetY
}

private func svgNoiseHash(x: Int64, y: Int64, seed: Int64): Int64 {
    var hash = x * 374761393 + y * 668265263 + seed * 69069
    hash = (hash ^ (hash >> 13)) * 1274126177
    hash ^ (hash >> 16)
}

internal func displacementFilterBuffer(
    input: SvgFilterBuffer,
    input2: SvgFilterBuffer,
    displacement: SvgFeDisplacementMap,
    scaleX: Float64,
    scaleY: Float64,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    var scale = displacement.scale
    if (!isFiniteSvgNumber(scale)) {
        warnings.add("feDisplacementMap 的 scale 非有限，按 0 处理")
        scale = 0.0
    }
    if (scale == 0.0) {
        return input.copy()
    }
    let xChannel = displacement.xChannelSelector.channelIndex()
    let yChannel = displacement.yChannelSelector.channelIndex()
    let output = SvgFilterBuffer(input.width, input.height)
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            let mapBase = (y * input2.width + x) * 4
            let xValue = Float64(input2.pixels[mapBase + xChannel]) / 255.0 - 0.5
            let yValue = Float64(input2.pixels[mapBase + yChannel]) / 255.0 - 0.5
            let offsetX = scale * xValue * scaleX
            let offsetY = scale * yValue * scaleY
            let sample = bilinearSvgSample(input, Float64(x) - offsetX, Float64(y) - offsetY)
            let base = (y * input.width + x) * 4
            output.pixels[base] = sample[0]
            output.pixels[base + 1] = sample[1]
            output.pixels[base + 2] = sample[2]
            output.pixels[base + 3] = sample[3]
            x++
        }
        y++
    }
    output
}

/** 非预乘双线性采样；越界权重按透明。 */
private func bilinearSvgSample(input: SvgFilterBuffer, x: Float64, y: Float64): Array<Byte> {
    let result = Array<Byte>(4, repeat: 0)
    let centerX = x - 0.5
    let centerY = y - 0.5
    let left = Int64(floor(centerX))
    let top = Int64(floor(centerY))
    let fractionX = centerX - Float64(left)
    let fractionY = centerY - Float64(top)
    let columns: Array<Int64> = [left, left + 1, left, left + 1]
    let rows: Array<Int64> = [top, top, top + 1, top + 1]
    let weights: Array<Float64> = [
        (1.0 - fractionX) * (1.0 - fractionY),
        fractionX * (1.0 - fractionY),
        (1.0 - fractionX) * fractionY,
        fractionX * fractionY
    ]
    var alpha = 0.0
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    for (index in 0..4) {
        let column = columns[index]
        let row = rows[index]
        if (column < 0 || row < 0 || column >= input.width || row >= input.height) {
            continue
        }
        let base = (row * input.width + column) * 4
        let weight = weights[index]
        let sampleAlpha = Float64(input.pixels[base + 3]) / 255.0
        alpha += sampleAlpha * weight
        red += Float64(input.pixels[base]) * sampleAlpha * weight
        green += Float64(input.pixels[base + 1]) * sampleAlpha * weight
        blue += Float64(input.pixels[base + 2]) * sampleAlpha * weight
    }
    if (alpha <= 0.0) {
        return result
    }
    result[0] = UInt8(Int64(round(clampSvgUnit(red / alpha))))
    result[1] = UInt8(Int64(round(clampSvgUnit(green / alpha))))
    result[2] = UInt8(Int64(round(clampSvgUnit(blue / alpha))))
    result[3] = UInt8(Int64(round(clampSvgUnit(alpha) * 255.0)))
    result
}

internal func feImageFilterBuffer(
    input: SvgFilterBuffer,
    image: SvgFeImage,
    images: ?SvgImageResource,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let output = SvgFilterBuffer(input.width, input.height)
    let href = match (image.href) {
        case Some(value) => value
        case None =>
            warnings.add("feImage 缺少 href，输出透明")
            return output
    }
    let resource = match (images) {
        case Some(value) => value
        case None =>
            warnings.add("feImage 没有可用的图像资源提供者，输出透明（href=${href}）")
            return output
    }
    let source = match (resource.load(href)) {
        case Some(value) => value
        case None =>
            warnings.add("feImage 的资源不可用，输出透明（href=${href}）")
            return output
    }
    let aspect = image.preserveAspectRatio
    let targetWidth = Float64(input.width)
    let targetHeight = Float64(input.height)
    let sourceWidth = Float64(source.width)
    let sourceHeight = Float64(source.height)
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    if (aspect.align == SvgAspectAlign.NoAlign) {
        scale = 1.0
        offsetX = 0.0
        offsetY = 0.0
    } else {
        let scaleX = targetWidth / sourceWidth
        let scaleY = targetHeight / sourceHeight
        scale = if (aspect.slice) { max(scaleX, scaleY) } else { min(scaleX, scaleY) }
        let contentWidth = sourceWidth * scale
        let contentHeight = sourceHeight * scale
        let factorX = if (aspect.align.isXMin()) { 0.0 } else if (aspect.align.isXMax()) { 1.0 } else { 0.5 }
        let factorY = if (aspect.align.isYMin()) { 0.0 } else if (aspect.align.isYMax()) { 1.0 } else { 0.5 }
        offsetX = (targetWidth - contentWidth) * factorX
        offsetY = (targetHeight - contentHeight) * factorY
    }
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            let localX = Float64(x) + 0.5 - offsetX
            let localY = Float64(y) + 0.5 - offsetY
            let sourceX = if (aspect.align == SvgAspectAlign.NoAlign) {
                localX / (targetWidth / sourceWidth)
            } else {
                localX / scale
            }
            let sourceY = if (aspect.align == SvgAspectAlign.NoAlign) {
                localY / (targetHeight / sourceHeight)
            } else {
                localY / scale
            }
            if (sourceX >= 0.0 && sourceY >= 0.0 &&
                sourceX < sourceWidth && sourceY < sourceHeight) {
                let column = clampSvgIndex(Int64(floor(sourceX)), source.width)
                let row = clampSvgIndex(Int64(floor(sourceY)), source.height)
                let sourceBase = (row * source.width + column) * 4
                let targetBase = (y * input.width + x) * 4
                output.pixels[targetBase] = source.pixels[sourceBase]
                output.pixels[targetBase + 1] = source.pixels[sourceBase + 1]
                output.pixels[targetBase + 2] = source.pixels[sourceBase + 2]
                output.pixels[targetBase + 3] = source.pixels[sourceBase + 3]
            }
            x++
        }
        y++
    }
    output
}
