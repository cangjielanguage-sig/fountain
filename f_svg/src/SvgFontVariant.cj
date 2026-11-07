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

/** `font-stretch` 的 9 个关键字与百分比。 */
public enum SvgFontStretch <: Equatable<SvgFontStretch> & ToString {
    | UltraCondensed
    | ExtraCondensed
    | Condensed
    | SemiCondensed
    | Normal
    | SemiExpanded
    | Expanded
    | ExtraExpanded
    | UltraExpanded
    | Percent(Float64)

    public operator func ==(that: SvgFontStretch): Bool {
        match ((this, that)) {
            case (UltraCondensed, UltraCondensed) => true
            case (ExtraCondensed, ExtraCondensed) => true
            case (Condensed, Condensed) => true
            case (SemiCondensed, SemiCondensed) => true
            case (Normal, Normal) => true
            case (SemiExpanded, SemiExpanded) => true
            case (Expanded, Expanded) => true
            case (ExtraExpanded, ExtraExpanded) => true
            case (UltraExpanded, UltraExpanded) => true
            case (Percent(left), Percent(right)) => left == right
            case _ => false
        }
    }

    public func percentage(): Float64 {
        match (this) {
            case UltraCondensed => 50.0
            case ExtraCondensed => 62.5
            case Condensed => 75.0
            case SemiCondensed => 87.5
            case Normal => 100.0
            case SemiExpanded => 112.5
            case Expanded => 125.0
            case ExtraExpanded => 150.0
            case UltraExpanded => 200.0
            case Percent(value) => value
        }
    }

    public func toString(): String {
        match (this) {
            case UltraCondensed => "ultra-condensed"
            case ExtraCondensed => "extra-condensed"
            case Condensed => "condensed"
            case SemiCondensed => "semi-condensed"
            case Normal => "normal"
            case SemiExpanded => "semi-expanded"
            case Expanded => "expanded"
            case ExtraExpanded => "extra-expanded"
            case UltraExpanded => "ultra-expanded"
            case Percent(value) => formatSvgNumber(value) + "%"
        }
    }

    internal static func fromName(name: String): ?SvgFontStretch {
        let lower = name.trimAscii().toAsciiLower()
        match (lower) {
            case "ultra-condensed" => Some(UltraCondensed)
            case "extra-condensed" => Some(ExtraCondensed)
            case "condensed" => Some(Condensed)
            case "semi-condensed" => Some(SemiCondensed)
            case "normal" => Some(Normal)
            case "semi-expanded" => Some(SemiExpanded)
            case "expanded" => Some(Expanded)
            case "extra-expanded" => Some(ExtraExpanded)
            case "ultra-expanded" => Some(UltraExpanded)
            case _ =>
                if (lower.endsWith("%")) {
                    match (tryParseSvgFloat(lower[0..lower.size - 1])) {
                        case Some(value) => if (value > 0.0 && isFiniteSvgNumber(value)) {
                            Some(Percent(value))
                        } else {
                            Option<SvgFontStretch>.None
                        }
                        case None => Option<SvgFontStretch>.None
                    }
                } else {
                    Option<SvgFontStretch>.None
                }
        }
    }
}

/** OpenType 特性开关集合；默认 `liga` / `clig` 开，`dlig` / `hlig` / `calt` 关。 */
public class SvgFontFeatures <: ToString {
    public static let MAX_ENTRIES: Int64 = 64
    private var switches: HashMap<String, Bool> = HashMap<String, Bool>()
    private let ordered = ArrayList<String>()
    private var explicitCount: Int64 = 0

    private init() {
        this.switches["liga"] = true
        this.switches["clig"] = true
        this.switches["dlig"] = false
        this.switches["hlig"] = false
        this.switches["calt"] = false
        this.switches["kern"] = true
        for (tag in ["liga", "clig", "dlig", "hlig", "calt", "kern"]) {
            this.ordered.add(tag)
        }
    }

    public prop size: Int64 {
        get() {
            this.explicitCount
        }
    }

    public func enabled(tag: String): Bool {
        this.switches.get(tag) ?? false
    }

    internal func set(tag: String, value: Bool): Unit {
        if (!this.switches.contains(tag)) {
            this.ordered.add(tag)
        }
        this.switches[tag] = value
    }

    public func toString(): String {
        let out = ArrayList<String>()
        for (tag in this.ordered) {
            if (this.switches.get(tag) ?? false) {
                out.add(tag)
            }
        }
        joinCssStrings(out, ",")
    }

    public static func parse(text: String): SvgFontFeatures {
        parse(text, ArrayList<String>())
    }

    /** 解析 `"liga" 0, "kern" 1`；超过 64 条忽略多余并 warning。 */
    public static func parse(text: String, warnings: ArrayList<String>): SvgFontFeatures {
        let result = SvgFontFeatures()
        var count: Int64 = 0
        for (piece in svgSplitFeatureEntries(text)) {
            let entry = svgParseFeatureEntry(piece, warnings) ?? continue
            count++
            if (count > MAX_ENTRIES) {
                warnings.add("font-feature-settings 条目超过 ${MAX_ENTRIES} 条，多余项已忽略")
                break
            }
            result.set(entry[0], entry[1])
            result.explicitCount++
        }
        result
    }

    /** 由计算样式合并：variant-ligatures 先，font-feature-settings 覆盖，font-kerning 最后覆盖 kern。 */
    internal static func fromStyle(style: SvgComputedStyle): SvgFontFeatures {
        let result = SvgFontFeatures()
        match (style.fontVariantLigatures()) {
            case "none" =>
                result.set("liga", false)
                result.set("clig", false)
            case "common-ligatures" =>
                result.set("liga", true)
                result.set("clig", true)
            case "discretionary-ligatures" => result.set("dlig", true)
            case "historical-ligatures" => result.set("hlig", true)
            case "contextual" => result.set("calt", true)
            case _ => ()
        }
        let explicitText = (style.get("font-feature-settings") ?? "").trimAscii()
        if (explicitText.size > 0 && explicitText.toAsciiLower() != "normal") {
            let warnings = ArrayList<String>()
            let explicit = SvgFontFeatures.parse(explicitText, warnings)
            for ((tag, value) in explicit.switches) {
                result.set(tag, value)
            }
        }
        match (style.fontKerning()) {
            case SvgFontKerning.None => result.set("kern", false)
            case SvgFontKerning.Normal => result.set("kern", true)
            case SvgFontKerning.Auto => ()
        }
        result
    }
}

/** 按顶层逗号拆分，忽略引号内逗号。 */
private func svgSplitFeatureEntries(text: String): Array<String> {
    let result = ArrayList<String>()
    let bytes = text.unsafeBytes()
    var start = 0
    var quoteByte = 0
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (byte == b'"' || byte == b'\'') {
            if (quoteByte == 0) {
                quoteByte = Int64(byte)
            } else if (quoteByte == Int64(byte)) {
                quoteByte = 0
            }
        } else if (byte == b',' && quoteByte == 0) {
            let piece = text[start..index].trimAscii()
            if (piece.size > 0) {
                result.add(piece)
            }
            start = index + 1
        }
    }
    let tail = text[start..].trimAscii()
    if (tail.size > 0) {
        result.add(tail)
    }
    result.toArray()
}

/** 解析单条 `"tag" 0|1|on|off`；非法返回 None 并 warning。 */
private func svgParseFeatureEntry(text: String, warnings: ArrayList<String>): ?(String, Bool) {
    let trimmed = text.trimAscii()
    if (trimmed.size < 3) {
        warnings.add("font-feature-settings 条目「${trimmed}」不合法")
        return None
    }
    let first = trimmed.unsafeBytes()[0]
    if (first != b'"' && first != b'\'') {
        warnings.add("font-feature-settings 条目「${trimmed}」缺少引号")
        return None
    }
    var close = -1
    let bytes = trimmed.unsafeBytes()
    var index = 1
    while (index < bytes.size) {
        if (bytes[index] == first) {
            close = index
            break
        }
        index++
    }
    if (close < 0) {
        warnings.add("font-feature-settings 条目「${trimmed}」引号未闭合")
        return None
    }
    let tag = trimmed[1..close]
    if (tag.size != 4) {
        warnings.add("font-feature-settings 标签「${tag}」长度必须为 4")
        return None
    }
    let valueText = trimmed[close + 1..].trimAscii().toAsciiLower()
    let enabled = match (valueText) {
        case "" | "1" | "on" => true
        case "0" | "off" => false
        case _ =>
            warnings.add("font-feature-settings 标签「${tag}」的值「${valueText}」不合法")
            return None
    }
    Some((tag, enabled))
}
