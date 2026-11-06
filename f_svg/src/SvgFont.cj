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

/** 字体注册表：按 family 列表回退，weight / style 未命中时回退 normal / normal。 */
public class SvgFontRegistry {
    private let fonts = HashMap<String, SvgFont>()
    private let registeredFamilies = HashMap<String, Bool>()
    /** 派生注册表的委托目标；`None` 表示自身持有字体。 */
    private var base: ?SvgFontRegistry = None
    /** 别名 family（小写）到目标 family（小写）。 */
    private let aliases = HashMap<String, String>()

    public init() {}

    public func register(family: String, font: SvgFont): Unit {
        let normalized = normalizeSvgFontFamily(family)
        this.fonts[SvgFontRegistry.key(normalized, "normal", "normal")] = font
        if (this.registeredFamilies.get(normalized).isNone()) {
            this.registeredFamilies[normalized] = true
        }
    }

    /**
     * 构造一次性派生注册表：别名 family 先映射到目标 family，再委托 base 解析。
     *
     * CSS `@font-face` 不携带可加载的目标，因此目标取「已注册的同名 family」；
     * 同名未注册时别名不生效，记 warning，不回退到注册表的首个 family。
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
            if (!base.hasFamily(name)) {
                match (warnings) {
                    case Some(list) =>
                        list.add("@font-face 目标 family「${rule.family}」未注册，别名不生效")
                    case None => ()
                }
                continue
            }
            result.aliases[name] = name
        }
        result
    }

    /** 注册表中是否存在该 family。 */
    internal func hasFamily(name: String): Bool {
        this.registeredFamilies.get(name).isSome()
    }

    public func resolve(family: String, weight: String, style: String): ?SvgFont {
        let normalizedWeight = weight.trimAscii().toAsciiLower()
        let normalizedStyle = style.trimAscii().toAsciiLower()
        for (name in splitSvgFontFamilies(family)) {
            match (this.aliases.get(name)) {
                case Some(target) =>
                    match (this.base) {
                        case Some(delegate) =>
                            match (delegate.resolve(target, weight, style)) {
                                case Some(font) => return Some(font)
                                case None => ()
                            }
                        case None => ()
                    }
                case None => ()
            }
            match (this.fonts.get(SvgFontRegistry.key(name, normalizedWeight, normalizedStyle))) {
                case Some(font) => return Some(font)
                case None => ()
            }
            match (this.fonts.get(SvgFontRegistry.key(name, "normal", "normal"))) {
                case Some(font) => return Some(font)
                case None => ()
            }
        }
        match (this.base) {
            case Some(delegate) => delegate.resolve(family, weight, style)
            case None => None
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
}

internal func normalizeSvgFontFamily(family: String): String {
    trimAsciiQuotes(family.trimAscii()).toAsciiLower()
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
