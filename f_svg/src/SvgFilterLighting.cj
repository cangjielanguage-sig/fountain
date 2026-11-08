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

/** 光照原语的公有部分。 */
public abstract class SvgLightingPrimitive <: SvgFilterPrimitive {
    private let surfaceCache = SvgValueCache<Float64>()
    private let colorCache = SvgValueCache<SvgPaint>()

    protected init(tag: String) {
        super(tag)
    }

    public mut prop surfaceScale: Float64 {
        get() {
            this.surfaceCache.get(
                this.attributesVersion,
                {=> readLightingFloat(this, "surfaceScale")}
            ) ?? 1.0
        }
        set(value) {
            writeFloat(this, "surfaceScale", Some(value))
        }
    }

    public mut prop lightingColor: SvgPaint {
        get() {
            this.colorCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("lighting-color")) {
                        case Some(text) => tryParseSvgPaint(text)
                        case None => None
                    }
                }
            ) ?? SvgPaint.of(SvgColor.White)
        }
        set(value) {
            this.setAttr("lighting-color", value.toString())
        }
    }

    /** 第一个光源子元素；缺失返回 `None`。 */
    public func lightSource(): ?SvgElement {
        for (node in this.children) {
            match (node) {
                case ElementNode(element) =>
                    match (element) {
                        case _: SvgFeDistantLight => return Some(element)
                        case _: SvgFePointLight => return Some(element)
                        case _: SvgFeSpotLight => return Some(element)
                        case _ => ()
                    }
                case _ => ()
            }
        }
        None
    }

    /** 全部光源子元素，按文档顺序；用于非法结构校验。 */
    public func lightSources(): ArrayList<SvgElement> {
        let result = ArrayList<SvgElement>()
        for (node in this.children) {
            match (node) {
                case ElementNode(element) =>
                    match (element) {
                        case _: SvgFeDistantLight => result.add(element)
                        case _: SvgFePointLight => result.add(element)
                        case _: SvgFeSpotLight => result.add(element)
                        case _ => ()
                    }
                case _ => ()
            }
        }
        result
    }
}

/** `feDiffuseLighting`。 */
public class SvgFeDiffuseLighting <: SvgLightingPrimitive {
    private let constantCache = SvgValueCache<Float64>()

    public init() {
        super("feDiffuseLighting")
    }

    public mut prop diffuseConstant: Float64 {
        get() {
            this.constantCache.get(this.attributesVersion, {=> readFloat(this, "diffuseConstant")}) ??
                1.0
        }
        set(value) {
            writeFloat(this, "diffuseConstant", Some(value))
        }
    }
}

/** `feSpecularLighting`。 */
public class SvgFeSpecularLighting <: SvgLightingPrimitive {
    private let constantCache = SvgValueCache<Float64>()
    private let exponentCache = SvgValueCache<Float64>()

    public init() {
        super("feSpecularLighting")
    }

    public mut prop specularConstant: Float64 {
        get() {
            this.constantCache.get(this.attributesVersion, {=> readFloat(this, "specularConstant")}) ??
                1.0
        }
        set(value) {
            writeFloat(this, "specularConstant", Some(value))
        }
    }

    public mut prop specularExponent: Float64 {
        get() {
            this.exponentCache.get(this.attributesVersion, {=> readFloat(this, "specularExponent")}) ??
                1.0
        }
        set(value) {
            writeFloat(this, "specularExponent", Some(value))
        }
    }
}

/** `feDistantLight`。 */
public class SvgFeDistantLight <: SvgElement {
    private let azimuthCache = SvgValueCache<Float64>()
    private let elevationCache = SvgValueCache<Float64>()

    public init() {
        super("feDistantLight")
    }

    public mut prop azimuth: Float64 {
        get() {
            this.azimuthCache.get(this.attributesVersion, {=> readFloat(this, "azimuth")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "azimuth", Some(value))
        }
    }

    public mut prop elevation: Float64 {
        get() {
            this.elevationCache.get(this.attributesVersion, {=> readFloat(this, "elevation")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "elevation", Some(value))
        }
    }
}

/** `fePointLight`。 */
public class SvgFePointLight <: SvgElement {
    private let xCache = SvgValueCache<Float64>()
    private let yCache = SvgValueCache<Float64>()
    private let zCache = SvgValueCache<Float64>()

    public init() {
        super("fePointLight")
    }

    public mut prop x: Float64 {
        get() {
            this.xCache.get(this.attributesVersion, {=> readFloat(this, "x")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "x", Some(value))
        }
    }

    public mut prop y: Float64 {
        get() {
            this.yCache.get(this.attributesVersion, {=> readFloat(this, "y")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "y", Some(value))
        }
    }

    public mut prop z: Float64 {
        get() {
            this.zCache.get(this.attributesVersion, {=> readFloat(this, "z")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "z", Some(value))
        }
    }
}

/** `feSpotLight`。 */
public class SvgFeSpotLight <: SvgElement {
    private let xCache = SvgValueCache<Float64>()
    private let yCache = SvgValueCache<Float64>()
    private let zCache = SvgValueCache<Float64>()
    private let targetXCache = SvgValueCache<Float64>()
    private let targetYCache = SvgValueCache<Float64>()
    private let targetZCache = SvgValueCache<Float64>()
    private let exponentCache = SvgValueCache<Float64>()
    private let coneCache = SvgValueCache<Float64>()

    public init() {
        super("feSpotLight")
    }

    public mut prop x: Float64 {
        get() {
            this.xCache.get(this.attributesVersion, {=> readFloat(this, "x")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "x", Some(value))
        }
    }

    public mut prop y: Float64 {
        get() {
            this.yCache.get(this.attributesVersion, {=> readFloat(this, "y")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "y", Some(value))
        }
    }

    public mut prop z: Float64 {
        get() {
            this.zCache.get(this.attributesVersion, {=> readFloat(this, "z")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "z", Some(value))
        }
    }

    public mut prop pointsAtX: Float64 {
        get() {
            this.targetXCache.get(this.attributesVersion, {=> readFloat(this, "pointsAtX")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "pointsAtX", Some(value))
        }
    }

    public mut prop pointsAtY: Float64 {
        get() {
            this.targetYCache.get(this.attributesVersion, {=> readFloat(this, "pointsAtY")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "pointsAtY", Some(value))
        }
    }

    public mut prop pointsAtZ: Float64 {
        get() {
            this.targetZCache.get(this.attributesVersion, {=> readFloat(this, "pointsAtZ")}) ?? 0.0
        }
        set(value) {
            writeFloat(this, "pointsAtZ", Some(value))
        }
    }

    public mut prop specularExponent: Float64 {
        get() {
            this.exponentCache.get(this.attributesVersion, {=> readFloat(this, "specularExponent")}) ??
                1.0
        }
        set(value) {
            writeFloat(this, "specularExponent", Some(value))
        }
    }

    public mut prop limitingConeAngle: ?Float64 {
        get() {
            this.coneCache.get(this.attributesVersion, {=> readFloat(this, "limitingConeAngle")})
        }
        set(value) {
            writeFloat(this, "limitingConeAngle", value)
        }
    }
}

// ---------------------------------------------------------------------------
// 光照求值：alpha 作为高度场，中心差分求法线。
// ---------------------------------------------------------------------------

/** 读取数值；额外接受 `nan` / `inf`，用于校验非有限参数的降级路径。 */
private func readLightingFloat(element: SvgElement, name: String): ?Float64 {
    match (element.attr(name)) {
        case Some(text) =>
            match (text.trimAscii().toAsciiLower()) {
                case "nan" => Some(Float64.NaN)
                case "inf" | "infinity" => Some(Float64.Inf)
                case "-inf" | "-infinity" => Some(-Float64.Inf)
                case _ => tryParseSvgFloat(text)
            }
        case None => None
    }
}

private struct M4LightVector {    let x: Float64
    let y: Float64
    let z: Float64
    let attenuation: Float64

    init(x: Float64, y: Float64, z: Float64, attenuation: Float64) {
        this.x = x
        this.y = y
        this.z = z
        this.attenuation = attenuation
    }
}

private func m4Normalize(x: Float64, y: Float64, z: Float64): M4LightVector {
    let length = sqrt(x * x + y * y + z * z)
    if (length <= 1.0e-9 || !isFiniteSvgNumber(length)) {
        return M4LightVector(0.0, 0.0, 1.0, 1.0)
    }
    M4LightVector(x / length, y / length, z / length, 1.0)
}

private func m4HeightAt(
    input: SvgFilterBuffer,
    x: Int64,
    y: Int64,
    surfaceScale: Float64,
    axisScale: Float64
): Float64 {
    if (x < 0 || y < 0 || x >= input.width || y >= input.height) {
        return 0.0
    }
    let alpha = Float64(input.pixels[(y * input.width + x) * 4 + 3]) / 255.0
    alpha * surfaceScale * axisScale
}

private func m4LightFor(
    light: SvgElement,
    px: Float64,
    py: Float64,
    scaleX: Float64,
    scaleY: Float64
): M4LightVector {
    let averageScale = (scaleX + scaleY) / 2.0
    match (light) {
        case distant: SvgFeDistantLight =>
            let azimuth = distant.azimuth * 3.141592653589793 / 180.0
            let elevation = distant.elevation * 3.141592653589793 / 180.0
            M4LightVector(
                cos(elevation) * cos(azimuth),
                cos(elevation) * sin(azimuth),
                sin(elevation),
                1.0
            )
        case point: SvgFePointLight =>
            let lx = point.x * scaleX
            let ly = point.y * scaleY
            let lz = point.z * averageScale
            let dx = lx - px
            let dy = ly - py
            let dz = lz
            let distanceSquared = dx * dx + dy * dy + dz * dz
            let attenuation = 1.0 / (1.0 + 0.05 * distanceSquared)
            let direction = m4Normalize(dx, dy, dz)
            M4LightVector(direction.x, direction.y, direction.z, attenuation)
        case spot: SvgFeSpotLight =>
            let lx = spot.x * scaleX
            let ly = spot.y * scaleY
            let lz = spot.z * averageScale
            let dx = lx - px
            let dy = ly - py
            let dz = lz
            let distanceSquared = dx * dx + dy * dy + dz * dz
            let attenuation = 1.0 / (1.0 + 0.05 * distanceSquared)
            var cone = 1.0
            match (spot.limitingConeAngle) {
                case Some(angle) =>
                    let toTargetX = (spot.pointsAtX - spot.x) * scaleX
                    let toTargetY = (spot.pointsAtY - spot.y) * scaleY
                    let toTargetZ = (spot.pointsAtZ - spot.z) * averageScale
                    let axis = m4Normalize(toTargetX, toTargetY, toTargetZ)
                    let toSurface = m4Normalize(-dx, -dy, -dz)
                    let cosine = axis.x * toSurface.x + axis.y * toSurface.y +
                        axis.z * toSurface.z
                    let limit = cos(clampSvgUnit(angle / 180.0) * 3.141592653589793)
                    if (cosine < limit) {
                        cone = 0.0
                    }
                case None => ()
            }
            let direction = m4Normalize(dx, dy, dz)
            M4LightVector(
                direction.x,
                direction.y,
                direction.z,
                attenuation * cone
            )
        case _ =>
            M4LightVector(0.0, 0.0, 1.0, 0.0)
    }
}

internal func lightingFilterBuffer(
    input: SvgFilterBuffer,
    lighting: SvgLightingPrimitive,
    specularLighting: Bool,
    scaleX: Float64,
    scaleY: Float64,
    warnings: ArrayList<String>
): SvgFilterBuffer {
    let output = SvgFilterBuffer(input.width, input.height)
    let light = match (lighting.lightSource()) {
        case Some(value) => value
        case None =>
            warnings.add("光照原语缺少光源，输出透明")
            return output
    }
    if (!isFiniteSvgNumber(lighting.surfaceScale)) {
        warnings.add("光照原语的 surfaceScale 非有限，输出透明")
        return output
    }
    let surfaceScale = lighting.surfaceScale
    let colorPaint = lighting.lightingColor
    let color = match (colorPaint.color) {
        case Some(value) => value
        case None => SvgColor.White
    }
    let colorAlpha = color.alpha
    var constant = 1.0
    var exponent = 1.0
    let diffuse = match (lighting) {
        case value: SvgFeDiffuseLighting =>
            constant = value.diffuseConstant
            true
        case value: SvgFeSpecularLighting =>
            constant = value.specularConstant
            exponent = value.specularExponent
            false
        case _ => !specularLighting
    }
    if (!isFiniteSvgNumber(constant) || !isFiniteSvgNumber(exponent)) {
        warnings.add("光照原语的光照常量非有限，输出透明")
        return output
    }
    var y = 0
    while (y < input.height) {
        var x = 0
        while (x < input.width) {
            let alphaByte = Int64(input.pixels[(y * input.width + x) * 4 + 3])
            if (alphaByte == 0) {
                x++
                continue
            }
            let left = m4HeightAt(input, x - 1, y, surfaceScale, scaleX)
            let right = m4HeightAt(input, x + 1, y, surfaceScale, scaleX)
            let top = m4HeightAt(input, x, y - 1, surfaceScale, scaleY)
            let bottom = m4HeightAt(input, x, y + 1, surfaceScale, scaleY)
            let normal = m4Normalize(-(right - left) * 0.5, -(bottom - top) * 0.5, 1.0)
            let lightVector = m4LightFor(light, Float64(x) + 0.5, Float64(y) + 0.5, scaleX, scaleY)
            var intensity = 0.0
            if (diffuse) {
                let dot = normal.x * lightVector.x + normal.y * lightVector.y +
                    normal.z * lightVector.z
                if (dot > 0.0) {
                    intensity = constant * dot * lightVector.attenuation
                }
            } else {
                let halfX = lightVector.x
                let halfY = lightVector.y
                let halfZ = lightVector.z + 1.0
                let halfLength = sqrt(halfX * halfX + halfY * halfY + halfZ * halfZ)
                if (halfLength > 1.0e-9) {
                    let hx = halfX / halfLength
                    let hy = halfY / halfLength
                    let hz = halfZ / halfLength
                    let dot = normal.x * hx + normal.y * hy + normal.z * hz
                    if (dot > 0.0) {
                        intensity = constant * pow(dot, exponent) * lightVector.attenuation
                    }
                }
            }
            if (intensity > 1.0) {
                intensity = 1.0
            }
            let base = (y * input.width + x) * 4
            output.pixels[base] = UInt8(
                Int64(round(clampSvgUnit(Float64(color.red) / 255.0 * intensity * colorAlpha) * 255.0))
            )
            output.pixels[base + 1] = UInt8(
                Int64(round(clampSvgUnit(Float64(color.green) / 255.0 * intensity * colorAlpha) * 255.0))
            )
            output.pixels[base + 2] = UInt8(
                Int64(round(clampSvgUnit(Float64(color.blue) / 255.0 * intensity * colorAlpha) * 255.0))
            )
            output.pixels[base + 3] = UInt8(alphaByte)
            x++
        }
        y++
    }
    output
}
