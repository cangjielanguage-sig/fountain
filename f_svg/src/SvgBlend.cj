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

import std.math.*
import fountain::f_base.*

/**
 * CSS `mix-blend-mode` 的 12 种可分离混合模式。
 *
 * 与 `feBlend` 使用的 `SvgBlendMode` 相互独立，避免破坏既有 5 值枚举的穷尽匹配。
 */
public enum SvgMixBlendMode <: Equatable<SvgMixBlendMode> & ToString {
    | Normal
    | Multiply
    | Screen
    | Overlay
    | Darken
    | Lighten
    | ColorDodge
    | ColorBurn
    | HardLight
    | SoftLight
    | Difference
    | Exclusion

    public operator func ==(that: SvgMixBlendMode): Bool {
        match ((this, that)) {
            case (Normal, Normal) => true
            case (Multiply, Multiply) => true
            case (Screen, Screen) => true
            case (Overlay, Overlay) => true
            case (Darken, Darken) => true
            case (Lighten, Lighten) => true
            case (ColorDodge, ColorDodge) => true
            case (ColorBurn, ColorBurn) => true
            case (HardLight, HardLight) => true
            case (SoftLight, SoftLight) => true
            case (Difference, Difference) => true
            case (Exclusion, Exclusion) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Normal => "normal"
            case Multiply => "multiply"
            case Screen => "screen"
            case Overlay => "overlay"
            case Darken => "darken"
            case Lighten => "lighten"
            case ColorDodge => "color-dodge"
            case ColorBurn => "color-burn"
            case HardLight => "hard-light"
            case SoftLight => "soft-light"
            case Difference => "difference"
            case Exclusion => "exclusion"
        }
    }

    /** 解析 CSS 关键字；未知返回 `None`。 */
    public static func fromName(name: String): ?SvgMixBlendMode {
        match (name.trimAscii().toAsciiLower()) {
            case "normal" => Some(Normal)
            case "multiply" => Some(Multiply)
            case "screen" => Some(Screen)
            case "overlay" => Some(Overlay)
            case "darken" => Some(Darken)
            case "lighten" => Some(Lighten)
            case "color-dodge" => Some(ColorDodge)
            case "color-burn" => Some(ColorBurn)
            case "hard-light" => Some(HardLight)
            case "soft-light" => Some(SoftLight)
            case "difference" => Some(Difference)
            case "exclusion" => Some(Exclusion)
            case _ => None
        }
    }

    /** 缺省值 `normal`。 */
    public static func fromNameOrDefault(name: ?String): SvgMixBlendMode {
        match (name) {
            case Some(text) => fromName(text) ?? Normal
            case None => Normal
        }
    }
}

/** 计算样式值到混合模式；非法值按 `normal`。 */
internal func svgMixBlendModeOf(style: SvgComputedStyle): SvgMixBlendMode {
    SvgMixBlendMode.fromNameOrDefault(style.get("mix-blend-mode"))
}

/**
 * 以预乘 RGBA 计算 `source` 在 `backdrop` 上的混合结果。
 *
 * 公式来自 CSS Compositing and Blending：先反预乘求混合色，再按 source-over
 * 组合 alpha，最后钳制到 `0..1`。`normal` 与既有 source-over 完全等价。
 */
internal func blendSvgRgba(
    backdrop: SvgRgba,
    source: SvgRgba,
    mode: SvgMixBlendMode
): SvgRgba {
    if (mode == SvgMixBlendMode.Normal) {
        return source.over(backdrop)
    }
    let backdropAlpha = clampSvgUnit(backdrop.alpha)
    let sourceAlpha = clampSvgUnit(source.alpha)
    if (sourceAlpha <= 0.0) {
        return backdrop
    }
    if (backdropAlpha <= 0.0) {
        return source
    }
    let cb = (
        clampSvgUnit(backdrop.red / backdropAlpha),
        clampSvgUnit(backdrop.green / backdropAlpha),
        clampSvgUnit(backdrop.blue / backdropAlpha)
    )
    let cs = (
        clampSvgUnit(source.red / sourceAlpha),
        clampSvgUnit(source.green / sourceAlpha),
        clampSvgUnit(source.blue / sourceAlpha)
    )
    let blended = (
        blendCssChannel(cb[0], cs[0], mode),
        blendCssChannel(cb[1], cs[1], mode),
        blendCssChannel(cb[2], cs[2], mode)
    )
    let factor = backdropAlpha * sourceAlpha
    SvgRgba(
        clampSvgUnit(source.red * (1.0 - backdropAlpha) + factor * blended[0] +
            backdrop.red * (1.0 - sourceAlpha)),
        clampSvgUnit(source.green * (1.0 - backdropAlpha) + factor * blended[1] +
            backdrop.green * (1.0 - sourceAlpha)),
        clampSvgUnit(source.blue * (1.0 - backdropAlpha) + factor * blended[2] +
            backdrop.blue * (1.0 - sourceAlpha)),
        clampSvgUnit(sourceAlpha + backdropAlpha * (1.0 - sourceAlpha))
    )
}

/** 单通道可分离混合；输入输出均为非预乘 `0..1`。 */
internal func blendCssChannel(cb: Float64, cs: Float64, mode: SvgMixBlendMode): Float64 {
    let result = match (mode) {
        case Normal => cs
        case Multiply => cb * cs
        case Screen => cb + cs - cb * cs
        case Overlay => if (cb <= 0.5) {
            2.0 * cb * cs
        } else {
            1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
        }
        case Darken => min(cb, cs)
        case Lighten => max(cb, cs)
        case ColorDodge =>
            if (cb <= 0.0) {
                0.0
            } else if (cs >= 1.0) {
                1.0
            } else {
                min(1.0, cb / (1.0 - cs))
            }
        case ColorBurn =>
            if (cb >= 1.0) {
                1.0
            } else if (cs <= 0.0) {
                0.0
            } else {
                1.0 - min(1.0, (1.0 - cb) / cs)
            }
        case HardLight => if (cs <= 0.5) {
            2.0 * cb * cs
        } else {
            1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
        }
        case SoftLight =>
            if (cs <= 0.5) {
                cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
            } else {
                let d = if (cb <= 0.25) {
                    ((16.0 * cb - 12.0) * cb + 4.0) * cb
                } else {
                    sqrt(cb)
                }
                cb + (2.0 * cs - 1.0) * (d - cb)
            }
        case Difference => abs(cb - cs)
        case Exclusion => cb + cs - 2.0 * cb * cs
    }
    clampSvgUnit(result)
}
