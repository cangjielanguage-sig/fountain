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
            this.surfaceCache.get(this.attributesVersion, {=> readFloat(this, "surfaceScale")}) ?? 1.0
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
