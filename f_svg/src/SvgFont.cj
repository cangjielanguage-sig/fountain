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
 * 字体接口：只暴露字形路径、advance、上下沿与字形包围盒。
 *
 * 核心库不内置 CJK；调用方通过 `SvgFontRegistry` 注入具体字体。
 */
public interface SvgFont {
    func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData
    func advance(codePoint: Int64, fontSize: Float64): Float64
    func ascent(fontSize: Float64): Float64
    func descent(fontSize: Float64): Float64
    func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds
}

/** 一次字体解析结果：命中的字体与实际使用的 stretch 百分比。 */
internal class SvgFontMatch {
    let font: ?SvgFont
    let stretch: Float64

    init(font: ?SvgFont, stretch: Float64) {
        this.font = font
        this.stretch = stretch
    }
}

/** 字体注册表：按 family 列表回退，weight / style 未命中时回退 normal / normal。 */
public class SvgFontRegistry {
    private let fonts = HashMap<String, SvgFont>()
    /** stretch 维度独立存储；键为 `family|weight|style|stretch`。 */
    private let stretchFonts = HashMap<String, SvgFont>()
    /** 每个 family/weight/style 已注册的 stretch 列表。 */
    private let stretchValues = HashMap<String, ArrayList<Float64>>()
    private let registeredFamilies = HashMap<String, Bool>()
    /** 派生注册表的委托目标；`None` 表示自身持有字体。 */
    private var base: ?SvgFontRegistry = None
    /** 别名 family（小写）到目标 family（小写）。 */
    private let aliases = HashMap<String, String>()

    public init() {}

    public func register(family: String, font: SvgFont): Unit {
        this.register(family, font, stretch: 100.0)
    }

    /** 按 stretch 百分比注册；未指定 stretch 的旧调用等价于 100%。 */
    public func register(family: String, font: SvgFont, stretch!: Float64): Unit {
        let normalized = normalizeSvgFontFamily(family)
        let percent = if (stretch > 0.0 && isFiniteSvgNumber(stretch)) { stretch } else { 100.0 }
        if (percent == 100.0) {
            this.fonts[SvgFontRegistry.key(normalized, "normal", "normal")] = font
        }
        this.stretchFonts[SvgFontRegistry.stretchKey(normalized, "normal", "normal", percent)] = font
        let groupKey = SvgFontRegistry.key(normalized, "normal", "normal")
        match (this.stretchValues.get(groupKey)) {
            case Some(list) =>
                if (!list.contains(percent)) {
                    list.add(percent)
                }
            case None =>
                let created = ArrayList<Float64>()
                created.add(percent)
                this.stretchValues[groupKey] = created
        }
        if (this.registeredFamilies.get(normalized).isNone()) {
            this.registeredFamilies[normalized] = true
        }
    }

    /**
     * 构造一次性派生注册表：别名 family 先映射到目标 family，再委托 base 解析。
     *
     * CSS `@font-face` 的目标取自 `src: local(<family>)`；`src` 无 `local()` 时，
     * 仅当同名 family 已注册才建立恒等别名。目标未注册时别名不生效并记 warning，
     * 不回退到注册表的首个 family。`url(...)` 不加载文件，仅由解析阶段记 warning。
     * base 不被写入。
     */
    public static func derived(
        base: SvgFontRegistry,
        aliases: Array<CssFontFaceRule>,
        warnings!: ?ArrayList<String> = None
    ): SvgFontRegistry {
        let result = SvgFontRegistry()
        result.base = Some(base)
        for (rule in aliases) {
            let name = normalizeSvgFontFamily(rule.family)
            var target: ?String = None
            let locals = match (rule.src) {
                case Some(text) => parseCssLocalFontFamilies(text)
                case None => Array<String>()
            }
            if (locals.size > 0) {
                for (local in locals) {
                    let normalized = normalizeSvgFontFamily(local)
                    if (base.hasFamily(normalized)) {
                        target = Some(normalized)
                        break
                    }
                }
            } else if (base.hasFamily(name)) {
                target = Some(name)
            }
            match (target) {
                case Some(value) => result.aliases[name] = value
                case None =>
                    match (warnings) {
                        case Some(list) =>
                            list.add("@font-face 目标 family「${rule.family}」未注册，别名不生效")
                        case None => ()
                    }
            }
        }
        result
    }

    /** 注册表中是否存在该 family。 */
    internal func hasFamily(name: String): Bool {
        this.registeredFamilies.get(name).isSome()
    }

    public func resolve(family: String, weight: String, style: String): ?SvgFont {
        this.resolve(family, weight, style, stretch: 100.0)
    }

    /** 先精确百分比，再取已注册 stretch 中差值最小者，最后回退 100%。 */
    public func resolve(family: String, weight: String, style: String, stretch!: Float64): ?SvgFont {
        this.resolveDetailed(family, weight, style, stretch: stretch).font
    }

    /** 解析并返回实际命中的 stretch 百分比；用于决定是否需要合成缩放。 */
    internal func resolveDetailed(
        family: String,
        weight: String,
        style: String,
        stretch!: Float64
    ): SvgFontMatch {
        let normalizedWeight = weight.trimAscii().toAsciiLower()
        let normalizedStyle = style.trimAscii().toAsciiLower()
        let target = if (stretch > 0.0 && isFiniteSvgNumber(stretch)) { stretch } else { 100.0 }
        for (name in splitSvgFontFamilies(family)) {
            match (this.aliases.get(name)) {
                case Some(targetName) =>
                    match (this.base) {
                        case Some(delegate) =>
                            let aliasMatch = delegate.resolveDetailed(
                                targetName,
                                weight,
                                style,
                                stretch: 100.0
                            )
                            if (aliasMatch.font.isSome()) {
                                return aliasMatch
                            }
                        case None => ()
                    }
                case None => ()
            }
            match (this.stretchFonts.get(
                SvgFontRegistry.stretchKey(name, normalizedWeight, normalizedStyle, target)
            )) {
                case Some(font) => return SvgFontMatch(Some(font), target)
                case None => ()
            }
            let groupKey = SvgFontRegistry.key(name, normalizedWeight, normalizedStyle)
            let nearest = SvgFontRegistry.nearestStretch(this.stretchValues.get(groupKey), target)
            if (nearest.isSome()) {
                let nearestValue = nearest ?? 100.0
                match (this.stretchFonts.get(
                    SvgFontRegistry.stretchKey(
                        name,
                        normalizedWeight,
                        normalizedStyle,
                        nearestValue
                    )
                )) {
                    case Some(font) => return SvgFontMatch(Some(font), nearestValue)
                    case None => ()
                }
            }
            match (this.fonts.get(SvgFontRegistry.key(name, normalizedWeight, normalizedStyle))) {
                case Some(font) => return SvgFontMatch(Some(font), 100.0)
                case None => ()
            }
            match (this.fonts.get(SvgFontRegistry.key(name, "normal", "normal"))) {
                case Some(font) => return SvgFontMatch(Some(font), 100.0)
                case None => ()
            }
        }
        match (this.base) {
            case Some(delegate) => delegate.resolveDetailed(family, weight, style, stretch: target)
            case None => SvgFontMatch(Option<SvgFont>.None, target)
        }
    }

    private static func nearestStretch(values: ?ArrayList<Float64>, target: Float64): ?Float64 {
        match (values) {
            case Some(list) =>
                var best: ?Float64 = None
                var bestDelta = 0.0
                for (value in list) {
                    let delta = if (value > target) { value - target } else { target - value }
                    match (best) {
                        case Some(_) => if (delta < bestDelta) {
                            best = Some(value)
                            bestDelta = delta
                        }
                        case None =>
                            best = Some(value)
                            bestDelta = delta
                    }
                }
                best
            case None => Option<Float64>.None
        }
    }

    /** 每次返回新实例，避免调用方注册污染其他渲染。 */
    public static func defaultRegistry(): SvgFontRegistry {
        let registry = SvgFontRegistry()
        let font = SvgHersheyFont()
        registry.register("Hershey", font)
        registry.register("serif", font)
        registry.register("sans-serif", font)
        registry.register("monospace", font)
        registry
    }

    private static func key(family: String, weight: String, style: String): String {
        "${family}|${weight}|${style}"
    }

    private static func stretchKey(
        family: String,
        weight: String,
        style: String,
        stretch: Float64
    ): String {
        "${family}|${weight}|${style}|${formatSvgNumber(stretch)}"
    }
}

internal func normalizeSvgFontFamily(family: String): String {
    trimAsciiQuotes(family.trimAscii()).toAsciiLower()
}

/** 提取 `src` 中所有 `local(<family>)` 的名称；大小写不敏感，忽略引号。 */
internal func parseCssLocalFontFamilies(value: String): Array<String> {
    let result = ArrayList<String>()
    let lower = value.toAsciiLower()
    let bytes = lower.unsafeBytes()
    var index = 0
    while (index + 5 < bytes.size) {
        if (bytes[index] == b'l' && bytes[index + 1] == b'o' && bytes[index + 2] == b'c' &&
            bytes[index + 3] == b'a' && bytes[index + 4] == b'l' && bytes[index + 5] == b'(') {
            let start = index + 6
            var end = start
            while (end < bytes.size && bytes[end] != b')') {
                end++
            }
            if (end < bytes.size) {
                let name = trimAsciiQuotes(value[start..end].trimAscii())
                if (name.size > 0) {
                    result.add(name)
                }
            }
            index = end + 1
        } else {
            index++
        }
    }
    result.toArray()
}

/** 逗号分隔的 family 列表；去引号与首尾空白。 */
internal func splitSvgFontFamilies(family: String): Array<String> {
    let result = ArrayList<String>()
    let bytes = family.unsafeBytes()
    var i = 0
    while (i < bytes.size) {
        while (i < bytes.size && (isCssSpace(bytes[i]) || bytes[i] == b',')) {
            i++
        }
        let start = i
        while (i < bytes.size && bytes[i] != b',') {
            i++
        }
        let part = trimAsciiQuotes(family[start..i].trimAscii())
        if (part.size > 0) {
            result.add(part.toAsciiLower())
        }
    }
    result.toArray()
}

/** 去掉成对的单双引号。 */
internal func trimAsciiQuotes(text: String): String {
    if (text.size >= 2) {
        let bytes = text.unsafeBytes()
        let first = bytes[0]
        let last = bytes[bytes.size - 1]
        if ((first == b'"' && last == b'"') || (first == b'\'' && last == b'\'')) {
            return text[1..text.size - 1].trimAscii()
        }
    }
    text
}
