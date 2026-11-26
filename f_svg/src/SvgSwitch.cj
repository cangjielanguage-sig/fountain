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

/** `switch` 条件求值。求值只读文档，不修改任何状态。 */
public class SvgSwitch {
    /** 本模块支持的 SVG 1.1 特性字符串。 */
    private static let KNOWN_FEATURES: Array<String> = [
        "http://www.w3.org/TR/SVG11/feature#Structure",
        "http://www.w3.org/TR/SVG11/feature#Shape",
        "http://www.w3.org/TR/SVG11/feature#Text",
        "http://www.w3.org/TR/SVG11/feature#Paint",
        "http://www.w3.org/TR/SVG11/feature#Color",
        "http://www.w3.org/TR/SVG11/feature#Filter",
        "http://www.w3.org/TR/SVG11/feature#Image",
        "http://www.w3.org/TR/SVG11/feature#Pattern",
        "http://www.w3.org/TR/SVG11/feature#Marker",
        "http://www.w3.org/TR/SVG11/feature#Clip",
        "http://www.w3.org/TR/SVG11/feature#Mask",
        "http://www.w3.org/TR/SVG11/feature#Gradient",
        "http://www.w3.org/TR/SVG11/feature#Style",
        "http://www.w3.org/TR/SVG11/feature#View",
        "http://www.w3.org/TR/SVG11/feature#Animation",
        "http://www.w3.org/TR/SVG11/feature#Hyperlinking",
        "http://www.w3.org/TR/SVG11/feature#XlinkAttribute"
    ]

    /** 返回第一个满足条件的可渲染直接子元素；无匹配返回 `None`。 */
    public static func select(
        container: SvgElement,
        styles: SvgComputedStyleTree,
        languages: Array<String>
    ): ?SvgElement {
        for (node in container.children) {
            match (node) {
                case ElementNode(child) =>
                    if (!matches(child, languages)) {
                        continue
                    }
                    let hidden = match (styles.get(child)) {
                        case Some(style) => style.display() == "none"
                        case None => false
                    }
                    if (!hidden) {
                        return Some(child)
                    }
                case _ => ()
            }
        }
        None
    }

    /** 单个元素的条件是否满足。 */
    public static func matches(element: SvgElement, languages: Array<String>): Bool {
        match (element.attr("requiredExtensions")) {
            case Some(value) =>
                if (value.trimAscii().size > 0) {
                    return false
                }
            case None => ()
        }
        match (element.attr("requiredFeatures")) {
            case Some(value) =>
                let features = splitSwitchTokens(value)
                for (feature in features) {
                    if (!isKnownFeature(feature)) {
                        return false
                    }
                }
            case None => ()
        }
        match (element.attr("systemLanguage")) {
            case Some(value) =>
                let declared = splitSwitchTokens(value)
                if (declared.size > 0) {
                    var matched = false
                    for (language in declared) {
                        for (available in languages) {
                            if (languageMatches(language, available)) {
                                matched = true
                            }
                        }
                    }
                    if (!matched) {
                        return false
                    }
                }
            case None => ()
        }
        true
    }

    private static func isKnownFeature(value: String): Bool {
        for (feature in KNOWN_FEATURES) {
            if (feature == value) {
                return true
            }
        }
        false
    }
}

private func splitSwitchTokens(text: String): Array<String> {
    let result = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var index = 0
    while (index < bytes.size) {
        while (index < bytes.size && (isSvgSpace(bytes[index]) || bytes[index] == b',')) {
            index++
        }
        if (index >= bytes.size) {
            break
        }
        let start = index
        while (index < bytes.size && !isSvgSpace(bytes[index]) && bytes[index] != b',') {
            index++
        }
        let token = text[start..index].trimAscii()
        if (token.size > 0) {
            result.add(token)
        }
    }
    result.toArray()
}

/** 大小写不敏感的前缀匹配，边界为 `-`：`zh` 匹配 `zh-CN`，不匹配 `zhx`。 */
internal func languageMatches(declared: String, available: String): Bool {
    let left = declared.trimAscii().toAsciiLower()
    let right = available.trimAscii().toAsciiLower()
    if (left.size == 0 || right.size == 0) {
        return false
    }
    if (left == right) {
        return true
    }
    if (left.size < right.size && right[0..left.size] == left && right[left.size] == b'-') {
        return true
    }
    if (right.size < left.size && left[0..right.size] == right && left[right.size] == b'-') {
        return true
    }
    false
}
