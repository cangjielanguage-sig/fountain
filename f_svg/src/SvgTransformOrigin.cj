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

/**
 * `transform-origin` 的字符串归一化：总是输出「水平值 垂直值」。
 *
 * 单值补 `center`；`top` / `bottom` 作为单值时把 `center` 放到水平位。
 * 非法关键字（如 `middle`）返回 `None`。
 */
internal func normalizeCssTransformOrigin(text: String): ?String {
    let tokens = splitCssWhitespaceWords(text.trimAscii())
    if (tokens.size == 0 || tokens.size > 2) {
        return None
    }
    if (tokens.size == 1) {
        let single = tokens[0]
        let lower = single.toAsciiLower()
        if (lower == "top" || lower == "bottom") {
            return "center " + lower
        }
        if (!isCssHorizontalOriginValue(single) && !isCssVerticalOriginValue(single)) {
            return None
        }
        return single + " center"
    }
    let horizontal = tokens[0]
    let vertical = tokens[1]
    if (!isCssHorizontalOriginValue(horizontal)) {
        return None
    }
    if (!isCssVerticalOriginValue(vertical)) {
        return None
    }
    horizontal + " " + vertical
}

private func isCssHorizontalOriginValue(text: String): Bool {
    let lower = text.toAsciiLower()
    match (lower) {
        case "left" | "right" | "center" => true
        case _ => SvgLength.tryParse(text).isSome()
    }
}

private func isCssVerticalOriginValue(text: String): Bool {
    let lower = text.toAsciiLower()
    match (lower) {
        case "top" | "bottom" | "center" => true
        case _ => SvgLength.tryParse(text).isSome()
    }
}

/**
 * 元素的有效变换：`T(origin) × M × T(-origin)`。
 *
 * `transform-box: view-box` 以视口为参考盒，`fill-box` 以元素包围盒为参考；
 * 缺省 `0 0` + `view-box` 直接返回原矩阵，保证 M1–M4 输出逐字节不变。
 */
internal func effectiveElementTransform(
    element: SvgElement,
    style!: ?SvgComputedStyle,
    bounds!: ?SvgBounds,
    viewportWidth!: Float64,
    viewportHeight!: Float64
): SvgMatrix {
    let transform = match (element.transform) {
        case Some(value) => value
        case None => return SvgMatrix.identity
    }
    let matrix = transform.toMatrix()
    let originText = match (style) {
        case Some(value) => value.get("transform-origin") ?? "0 0"
        case None => match (element.attr("transform-origin")) {
            case Some(value) => value
            case None => "0 0"
        }
    }
    let box = match (style) {
        case Some(value) => value.get("transform-box") ?? "view-box"
        case None => match (element.attr("transform-box")) {
            case Some(value) => value.toAsciiLower()
            case None => "view-box"
        }
    }
    if (originText.trimAscii() == "0 0" && box == "view-box") {
        return matrix
    }
    var referenceWidth = viewportWidth
    var referenceHeight = viewportHeight
    var referenceX = 0.0
    var referenceY = 0.0
    if (box == "fill-box") {
        match (bounds) {
            case Some(value) =>
                referenceX = value.x
                referenceY = value.y
                referenceWidth = value.width
                referenceHeight = value.height
            case None => ()
        }
    }
    let tokens = splitCssWhitespaceWords(originText.trimAscii())
    let horizontal = if (tokens.size > 0) { tokens[0] } else { "0" }
    let vertical = if (tokens.size > 1) { tokens[1] } else { "center" }
    let originX = referenceX + resolveOriginComponent(horizontal, referenceWidth, true)
    let originY = referenceY + resolveOriginComponent(vertical, referenceHeight, false)
    if (abs(originX) <= 1e-12 && abs(originY) <= 1e-12) {
        return matrix
    }
    SvgMatrix.translate(originX, originY)
        .multiply(matrix)
        .multiply(SvgMatrix.translate(-originX, -originY))
}

private func resolveOriginComponent(text: String, reference: Float64, horizontal: Bool): Float64 {
    let lower = text.toAsciiLower()
    match (lower) {
        case "left" => return 0.0
        case "top" => return 0.0
        case "center" => return reference / 2.0
        case "right" => return reference
        case "bottom" => return reference
        case _ => ()
    }
    let length = match (SvgLength.tryParse(text)) {
        case Some(value) => value
        case None => return 0.0
    }
    match (length.unit) {
        case Percent => length.value / 100.0 * reference
        case Em => length.value * 16.0
        case Ex => length.value * 8.0
        case _ => length.value
    }
}
