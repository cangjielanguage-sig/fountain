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
package fountain::f_email.imap

import std.collection.ArrayList
import fountain::f_email.model.{Base64Codec, MailProtocolException}

/**
 * IMAP 的 modified UTF-7（RFC 3501 第 5.1.3 节）。
 *
 * 与标准 UTF-7 的差别只有两点：`&` 代替 `+` 作为 shift 起始，`,` 代替 `/`。
 * 邮箱名必须走这套编码——除非 `ENABLE UTF8=ACCEPT` 已经生效（见 [ImapClient])。
 *
 * 解码分两种态度：`strict=false`（默认）遇到非法序列保留原文，宁可显示成乱码也不丢邮箱；
 * `strict=true` 抛 `MailProtocolException`，供测试与严格场景使用。
 */
public class ImapUtf7 {
    public static func decode(text: String, strict!: Bool = false): String {
        if ((text.indexOf("&") ?? -1) < 0) {
            return text
        }
        let out = ArrayList<Rune>()
        let runes = text.toRuneArray()
        var index = 0
        while (index < runes.size) {
            let current = runes[index]
            if (UInt32(current) != UInt32(r'&')) {
                out.add(current)
                index += 1
                continue
            }
            // 找序列末尾的 '-'
            var end = index + 1
            while (end < runes.size && UInt32(runes[end]) != UInt32(r'-')) {
                end += 1
            }
            let encoded = ArrayList<Rune>()
            for (i in (index + 1)..end) {
                encoded.add(runes[i])
            }
            if (encoded.size == 0) {
                // "&-" 表示字面量 '&'
                out.add(r'&')
                index = if (end < runes.size) {
                    end + 1
                } else {
                    end
                }
                continue
            }
            var base64 = ""
            for (rune in encoded) {
                if (UInt32(rune) == UInt32(r',')) {
                    base64 = base64 + "/"
                } else {
                    if (strict && !isBase64Rune(rune)) {
                        throw MailProtocolException("modified UTF-7 含非法 base64 字符：${text}")
                    }
                    base64 = base64 + String([rune])
                }
            }
            let decoded = try {
                Base64Codec.decode(base64)
            } catch (e: Exception) {
                if (strict) {
                    throw MailProtocolException("modified UTF-7 的 base64 非法：${text}")
                }
                // 宽容：原样保留
                out.add(r'&')
                index += 1
                continue
            }
            if (decoded.size % 2 != 0) {
                if (strict) {
                    throw MailProtocolException("modified UTF-7 的 UTF-16 长度非法：${text}")
                }
                out.add(r'&')
                index += 1
                continue
            }
            let before = out.size
            appendUtf16(out, decoded)
            if (out.size == before) {
                // 宽容：解不出内容就原样保留 `&...-`，至少不丢邮箱名
                var keep = end
                if (keep < runes.size) {
                    keep += 1
                }
                for (i in index..keep) {
                    out.add(runes[i])
                }
            }
            index = if (end < runes.size) {
                end + 1
            } else {
                end
            }
        }
        String(out.toArray())
    }

    public static func encode(text: String): String {
        let out = ArrayList<Rune>()
        let pending = ArrayList<Byte>()
        for (rune in text.runes()) {
            let code = UInt32(rune)
            if (code >= 0x20 && code <= 0x7E && rune != r'&') {
                flushPending(out, pending)
                out.add(rune)
                continue
            }
            if (rune == r'&') {
                flushPending(out, pending)
                out.add(r'&')
                out.add(r'-')
                continue
            }
            appendUtf16Bytes(pending, code)
        }
        flushPending(out, pending)
        String(out.toArray())
    }

    private static func isBase64Rune(rune: Rune): Bool {
        let code = UInt32(rune)
        if (code >= UInt32(r'A') && code <= UInt32(r'Z')) {
            return true
        }
        if (code >= UInt32(r'a') && code <= UInt32(r'z')) {
            return true
        }
        if (code >= UInt32(r'0') && code <= UInt32(r'9')) {
            return true
        }
        code == UInt32(r'+') || code == UInt32(r'/')
    }

    /** 是否全是可打印 ASCII（这种邮箱名不需要编码）。 */
    public static func isAscii(text: String): Bool {
        for (b in text.toArray()) {
            if (b < 0x20 || b > 0x7E) {
                return false
            }
        }
        true
    }

    // ---------- 内部 ----------

    private static func flushPending(out: ArrayList<Rune>, pending: ArrayList<Byte>): Unit {
        if (pending.size == 0) {
            return
        }
        var encoded = Base64Codec.encodeUnwrapped(pending.toArray())
        // RFC 3501：modified BASE64 不使用 '=' 填充
        while (encoded.size > 0 && encoded[(encoded.size - 1)..] == "=") {
            encoded = encoded[0..(encoded.size - 1)]
        }
        out.add(r'&')
        for (rune in encoded.runes()) {
            if (rune == r'/') {
                out.add(r',')
            } else {
                out.add(rune)
            }
        }
        out.add(r'-')
        pending.clear()
    }

    private static func appendUtf16Bytes(target: ArrayList<Byte>, code: UInt32): Unit {
        if (code <= 0xFFFF) {
            target.add(UInt8((code >> 8) & 0xFF))
            target.add(UInt8(code & 0xFF))
            return
        }
        let adjusted = code - 0x10000
        let high = 0xD800 + ((adjusted >> 10) & 0x3FF)
        let low = 0xDC00 + (adjusted & 0x3FF)
        target.add(UInt8((high >> 8) & 0xFF))
        target.add(UInt8(high & 0xFF))
        target.add(UInt8((low >> 8) & 0xFF))
        target.add(UInt8(low & 0xFF))
    }

    private static func appendUtf16(out: ArrayList<Rune>, bytes: Array<Byte>): Unit {
        var index = 0
        while (index + 1 < bytes.size) {
            let unit = (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            index += 2
            if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < bytes.size) {
                let low = (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    index += 2
                    let code = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    out.add(Rune(code))
                    continue
                }
            }
            if (unit >= 0xD800 && unit <= 0xDFFF) {
                // 孤立的代理项：替换字符，不让整个邮箱名失败
                out.add(Rune(0xFFFD))
                continue
            }
            out.add(Rune(unit))
        }
    }
}
