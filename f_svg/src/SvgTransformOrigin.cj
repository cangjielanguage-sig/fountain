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
