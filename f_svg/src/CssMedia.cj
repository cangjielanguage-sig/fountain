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

/** 一条媒体特性条件。目前只支持宽度上下界。 */
public struct CssMediaFeature <: ToString {
    public let isMinWidth: Bool
    public let width: Float64

    public init(isMinWidth: Bool, width: Float64) {
        this.isMinWidth = isMinWidth
        this.width = width
    }

    func matches(viewportWidth: Float64): Bool {
        if (this.isMinWidth) {
            viewportWidth >= this.width
        } else {
            viewportWidth <= this.width
        }
    }

    public func toString(): String {
        let name = if (this.isMinWidth) { "min-width" } else { "max-width" }
        "${name}: ${formatSvgNumber(this.width)}px"
    }
}

/** 单个媒体查询：媒体类型 + 若干 `and` 条件。 */
public class CssMediaQueryItem <: ToString {
    /** 空字符串表示省略类型（等价 `all`）。 */
    public let mediaType: String
    public let features: Array<CssMediaFeature>

    init(mediaType: String, features: Array<CssMediaFeature>) {
        this.mediaType = mediaType
        this.features = features
    }

    func matches(viewportWidth: Float64): Bool {
        let accepted = this.mediaType == "" || this.mediaType == "all" || this.mediaType == "screen"
        if (!accepted) {
            return false
        }
        for (feature in this.features) {
            if (!feature.matches(viewportWidth)) {
                return false
            }
        }
        true
    }

    public func toString(): String {
        let out = StringBuilder()
        if (this.mediaType.size > 0) {
            out.append(this.mediaType)
        }
        for (feature in this.features) {
            if (out.toString().size > 0) {
                out.append(" and ")
            }
            out.append("(")
            out.append(feature.toString())
            out.append(")")
        }
        if (out.toString().size == 0) {
            return "all"
        }
        out.toString()
    }
}

/**
 * 媒体查询列表：逗号分隔，任一命中即生效。
 *
 * 解析容错：非法查询被丢弃并写 warning；全部非法时 `parse` 返回 `None`。
 */
public class CssMediaQuery <: ToString {
    public let items: Array<CssMediaQueryItem>

    private init(items: Array<CssMediaQueryItem>) {
        this.items = items
    }

    /** 解析失败返回 `None`，不产生 warning。 */
    public static func parse(text: String): ?CssMediaQuery {
        CssMediaQuery.parse(text, ArrayList<String>())
    }

    internal static func parse(text: String, warnings: ArrayList<String>): ?CssMediaQuery {
        let items = ArrayList<CssMediaQueryItem>()
        for (segment in splitCssMediaList(text)) {
            let trimmed = segment.trimAscii()
            if (trimmed.size == 0) {
                continue
            }
            match (parseCssMediaItem(trimmed)) {
                case Some(item) => items.add(item)
                case None =>
                    warnings.add("已跳过无法解析的 @media 查询「${trimmed}」")
            }
        }
        if (items.size == 0) {
            return None
        }
        CssMediaQuery(items.toArray())
    }

    /** 视口宽度是否命中任一查询。 */
    public func matches(viewportWidth: Float64): Bool {
        for (item in this.items) {
            if (item.matches(viewportWidth)) {
                return true
            }
        }
        false
    }

    public func toString(): String {
        let texts = ArrayList<String>()
        for (item in this.items) {
            texts.add(item.toString())
        }
        joinCssStrings(texts, ", ")
    }
}

/** 按顶层逗号拆分媒体查询列表。 */
private func splitCssMediaList(text: String): Array<String> {
    let result = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var depth = 0
    var start = 0
    for (index in 0..bytes.size) {
        match (bytes[index]) {
            case b'(' => depth++
            case b')' => if (depth > 0) {
                depth--
            }
            case b',' => if (depth == 0) {
                result.add(text[start..index])
                start = index + 1
            }
            case _ => ()
        }
    }
    result.add(text[start..])
    result.toArray()
}

/** 解析单个查询；失败返回 `None`。 */
private func parseCssMediaItem(text: String): ?CssMediaQueryItem {
    let bytes = text.unsafeBytes()
    var i = skipCssSpaces(bytes, 0)
    var mediaType = ""
    if (i < bytes.size && bytes[i] != b'(') {
        let start = i
        while (i < bytes.size && (isCssIdentByte(bytes[i]))) {
            i++
        }
        if (i == start) {
            return None
        }
        mediaType = text[start..i].toAsciiLower()
        i = skipCssSpaces(bytes, i)
    }
    let features = ArrayList<CssMediaFeature>()
    while (i < bytes.size) {
        if (mediaType.size > 0 || features.size > 0) {
            let keywordStart = i
            while (i < bytes.size && isCssIdentByte(bytes[i])) {
                i++
            }
            if (text[keywordStart..i].toAsciiLower() != "and") {
                return None
            }
            i = skipCssSpaces(bytes, i)
        }
        if (i >= bytes.size || bytes[i] != b'(') {
            return None
        }
        let close = findCssClosingParen(bytes, i)
        if (close < 0) {
            return None
        }
        match (parseCssMediaFeature(text[i + 1..close].trimAscii())) {
            case Some(feature) => features.add(feature)
            case None => return None
        }
        i = skipCssSpaces(bytes, close + 1)
    }
    if (mediaType.size == 0 && features.size == 0) {
        return None
    }
    CssMediaQueryItem(mediaType, features.toArray())
}

/** 解析 `min-width: 600px` / `max-width: 400px`。 */
private func parseCssMediaFeature(text: String): ?CssMediaFeature {
    let colon = indexOfSvgByte(text, b':')
    if (colon < 0) {
        return None
    }
    let name = text[0..colon].trimAscii().toAsciiLower()
    let valueText = text[colon + 1..].trimAscii().toAsciiLower()
    let isMin = match (name) {
        case "min-width" => true
        case "max-width" => false
        case _ => return None
    }
    if (valueText.size < 3 || !valueText.endsWith("px")) {
        return None
    }
    let numberText = valueText[0..valueText.size - 2].trimAscii()
    let value = match (tryParseSvgFloat(numberText)) {
        case Some(parsed) => parsed
        case None => return None
    }
    if (value < 0.0 || !isFiniteSvgNumber(value)) {
        return None
    }
    CssMediaFeature(isMin, value)
}
