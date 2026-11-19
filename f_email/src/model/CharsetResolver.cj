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
package fountain::f_email.model

import cangjie_tpc::charset4cj.charset.Charsets
import cangjie_tpc::charset4cj.charset.encoding.Charset

/**
 * 字符集回退链的配置。
 *
 * 默认链是 `UTF-8 → GB18030 → WINDOWS_1252`：中文邮件里"声明 utf-8 实际是 GBK"
 * 与"声明 gb2312 实际是 GBK"一样常见，直接报错会让大量正常邮件读不出来。
 */
public struct CharsetOptions {
    public let fallback: Array<Charset>
    public let strict: Bool

    public init(
        fallback!: Array<Charset> = [Charsets.UTF8, Charsets.GB18030, Charsets.WINDOWS_1252],
        strict!: Bool = false
    ) {
        this.fallback = fallback
        this.strict = strict
    }
}

/** 解码结果：文本 + 实际使用的字符集 + 是否发生过替换。 */
public struct DecodedText {
    public let text: String
    public let charset: Charset
    public let lossy: Bool

    public init(text: String, charset: Charset, lossy: Bool) {
        this.text = text
        this.charset = charset
        this.lossy = lossy
    }
}

/**
 * 邮件常见字符集别名表与四级回退链。
 *
 * 这是**唯一**调用 `charset4cj` 的地方；上层只拿 [Charset] 与 [DecodedText]。
 */
public class CharsetResolver {
    private static let REPLACEMENT: String = String([Rune(0xFFFD)])

    /** 别名表：邮件里常见写法 → charset4cj 的实例。 */
    private static func alias(name: String): ?Charset {
        match (name) {
            case "us-ascii" => return Some(Charsets.UTF8)
            case "ascii" => return Some(Charsets.UTF8)
            case "ansi_x3.4-1968" => return Some(Charsets.UTF8)
            case "utf8" => return Some(Charsets.UTF8)
            case "utf-8" => return Some(Charsets.UTF8)
            case "gb2312" => return Some(Charsets.GBK)
            case "gbk" => return Some(Charsets.GBK)
            case "cp936" => return Some(Charsets.GBK)
            case "x-gbk" => return Some(Charsets.GBK)
            case "ms936" => return Some(Charsets.GBK)
            case "gb18030" => return Some(Charsets.GB18030)
            case "big5" => return Some(Charsets.BIG5)
            case "cp950" => return Some(Charsets.BIG5)
            case "iso-8859-1" => return Some(Charsets.WINDOWS_1252)
            case "latin1" => return Some(Charsets.WINDOWS_1252)
            case "shift_jis" => return Some(Charsets.SHIFT_JIS)
            case "sjis" => return Some(Charsets.SHIFT_JIS)
            case "cp932" => return Some(Charsets.SHIFT_JIS)
            case "euc-kr" => return Some(Charsets.EUCKR)
            case "ks_c_5601-1987" => return Some(Charsets.EUCKR)
            case "iso-2022-jp" => return Some(Charsets.ISO_2022_JP)
            case _ => ()
        }
        None
    }

    /**
     * 把声明名解析成字符集。
     *
     * 声明缺失或无法识别时返回 `defaultCharset`（默认 UTF-8）；真正的多级尝试在 [decode]。
     */
    public static func resolve(
        name: ?String,
        options!: CharsetOptions = CharsetOptions(),
        defaultCharset!: Charset = Charsets.UTF8
    ): Charset {
        if (let Some(raw) <- name) {
            let normalized = raw.trimAscii().toAsciiLower()
            if (options.strict && normalized.size > 0 && !isKnown(normalized)) {
                throw MimeException("未知字符集：${raw}")
            }
            if (normalized.size > 0) {
                if (let Some(found) <- alias(normalized)) {
                    return found
                }
                if (let Some(found) <- matchLabel(normalized)) {
                    return found
                }
            }
        }
        defaultCharset
    }

    /** 声明名是否被认识（用于区分"声明未知"与"声明缺失"）。 */
    public static func isKnown(name: String): Bool {
        let normalized = name.trimAscii().toAsciiLower()
        if (alias(normalized).isSome()) {
            return true
        }
        matchLabel(normalized).isSome()
    }

    /**
     * 按回退链解码。
     *
     * 1. 声明且认识 → 用它；解码抛异常则进入回退链。
     * 2. 声明缺失 → `defaultCharset`。
     * 3. 声明未知 → 依次尝试 `options.fallback`。
     * 4. 全部失败 → `WINDOWS_1252` 逐字节映射（永不失败），`lossy=true`。
     */
    public static func decode(
        bytes: Array<Byte>,
        name: ?String,
        options!: CharsetOptions = CharsetOptions(),
        defaultCharset!: Charset = Charsets.UTF8
    ): DecodedText {
        let declared: ?Charset = if (let Some(raw) <- name) {
            let normalized = raw.trimAscii().toAsciiLower()
            if (let Some(found) <- alias(normalized)) {
                Some(found)
            } else {
                matchLabel(normalized)
            }
        } else {
            None<Charset>
        }
        if (let Some(charset) <- declared) {
            if (let Some(text) <- tryDecode(bytes, charset)) {
                return DecodedText(text, charset, text.contains(REPLACEMENT))
            }
        } else if (name.isNone()) {
            if (let Some(text) <- tryDecode(bytes, defaultCharset)) {
                return DecodedText(text, defaultCharset, text.contains(REPLACEMENT))
            }
        }
        for (charset in options.fallback) {
            if (let Some(text) <- tryDecode(bytes, charset)) {
                if (!text.contains(REPLACEMENT)) {
                    return DecodedText(text, charset, false)
                }
            }
        }
        if (options.strict) {
            throw MimeException("无法用任何字符集解码正文（声明：${name ?? "无"}）")
        }
        DecodedText(latin1(bytes), Charsets.WINDOWS_1252, true)
    }

    /** 用指定字符集严格解码；失败返回 `None`。 */
    public static func tryDecode(bytes: Array<Byte>, charset: Charset): ?String {
        try {
            Some(charset.newDecoder().decode(bytes))
        } catch (_: Exception) {
            None<String>
        }
    }

    public static func encode(text: String, charset: Charset): Array<Byte> {
        charset.newEncoder().encode(text)
    }

    // ---------- 内部 ----------

    private static func matchLabel(name: String): ?Charset {
        for (charset in allCharsets()) {
            if (charset.nameEquals(name)) {
                return Some(charset)
            }
        }
        None<Charset>
    }

    private static func allCharsets(): Array<Charset> {
        [
            Charsets.UTF8,
            Charsets.UTF16BE,
            Charsets.UTF16LE,
            Charsets.GBK,
            Charsets.GB18030,
            Charsets.BIG5,
            Charsets.EUCKR,
            Charsets.SHIFT_JIS,
            Charsets.ISO_2022_JP,
            Charsets.WINDOWS_1252
        ]
    }

    /** Latin-1 逐字节映射：任何输入都能出文本，永不失败。 */
    private static func latin1(bytes: Array<Byte>): String {
        let runes = Array<Rune>(bytes.size, repeat: r'\0')
        for (i in 0..bytes.size) {
            runes[i] = Rune(UInt32(bytes[i]))
        }
        String(runes)
    }
}
