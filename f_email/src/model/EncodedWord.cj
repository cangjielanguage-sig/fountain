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

import std.collection.ArrayList
import cangjie_tpc::charset4cj.charset.Charsets
import cangjie_tpc::charset4cj.charset.encoding.Charset

/**
 * RFC 2047 encoded-word。
 *
 * 解码侧两条容易漏的规则：相邻 encoded-word 之间的空白要**丢弃**（一个词被折断成两段时，
 * 中间那个空格是分隔符不是内容）；普通文本与 encoded-word 混排时，普通文本的空白要**保留**。
 *
 * 编码侧只在确实需要时编码（含非 ASCII 或控制字符），并且**不切断多字节字符**——
 * 按字符边界切块，每块单独 base64/Q 编码。
 */
public class EncodedWord {
    /**
     * 解码整段文本：既处理纯 encoded-word，也处理与普通文本混排。
     */
    public static func decode(text: String, strict!: Bool = false): String {
        let runes = text.toRuneArray()
        let out = StringBuilder()
        var pending = ""
        var lastEncoded = false
        var i = 0
        var failed = false
        while (i < runes.size) {
            if (runes[i] == r'=' && i + 1 < runes.size && runes[i + 1] == r'?') {
                let parsed = parseAt(runes, i, strict)
                if (let Some((decoded, next)) <- parsed) {
                    if (!lastEncoded) {
                        out.append(pending)
                    }
                    pending = ""
                    out.append(decoded)
                    lastEncoded = true
                    i = next
                    continue
                }
                failed = true
            }
            let ch = runes[i]
            if (isWhitespace(ch)) {
                pending = pending + String([ch])
            } else {
                out.append(pending)
                pending = ""
                out.append(ch)
                lastEncoded = false
            }
            i += 1
        }
        if (failed && strict) {
            throw MimeException("非法的 encoded-word：${text}")
        }
        out.append(pending)
        out.toString()
    }

    /**
     * 编码文本。
     *
     * 纯 ASCII 且不含控制字符时原样返回；否则按字符边界切成多个 word，每个 word ≤ [maxWordLength]，
     * word 之间用 `CRLF + 空格` 连接。
     */
    public static func encode(
        text: String,
        charset!: Charset = Charsets.UTF8,
        maxWordLength!: Int64 = 75
    ): String {
        if (!needsEncoding(text)) {
            return text
        }
        let runes = text.toRuneArray()
        let nonAscii = countNonAscii(text)
        let useQ = nonAscii * 3 < text.toArray().size
        let charsetName = charsetName(charset)
        let marker = if (useQ) { "Q" } else { "B" }
        let overhead = 2 + charsetName.size + 2 + 1 + 2 // =?charset?X?...?=
        var budget = maxWordLength - overhead
        if (budget < 4) {
            budget = 4
        }
        let words = ArrayList<String>()
        var chunk = ArrayList<Rune>()
        var chunkBytes = 0
        var chunkQ = 0
        for (ch in runes) {
            let bytes = String([ch]).toArray().size
            let q = qEncodedSize(ch)
            let predicted = if (useQ) {
                overhead + chunkQ + q
            } else {
                overhead + 4 * ((chunkBytes + bytes + 2) / 3)
            }
            if (chunk.size > 0 && predicted > maxWordLength) {
                words.add(renderWord(chunk, charsetName, marker, useQ))
                chunk = ArrayList<Rune>()
                chunkBytes = 0
                chunkQ = 0
            }
            chunk.add(ch)
            chunkBytes += bytes
            chunkQ += q
        }
        if (chunk.size > 0) {
            words.add(renderWord(chunk, charsetName, marker, useQ))
        }
        let out = StringBuilder()
        var first = true
        for (word in words) {
            if (!first) {
                out.append("\r\n ")
            }
            out.append(word)
            first = false
        }
        out.toString()
    }

    /** 是否必须编码：出现非 ASCII 或控制字符。 */
    public static func needsEncoding(text: String): Bool {
        for (ch in text.runes()) {
            let v = UInt32(ch)
            if (v > 126 || v < 32) {
                return true
            }
        }
        false
    }

    // ---------- 内部 ----------

    private static func charsetName(charset: Charset): String {
        charset.toString().toAsciiUpper()
    }

    private static func countNonAscii(text: String): Int64 {
        var n = 0
        for (b in text.toArray()) {
            if (b > 126 || b < 32) {
                n += 1
            }
        }
        n
    }

    private static func encodedSize(ch: Rune, useQ: Bool): Int64 {
        if (useQ) {
            return qEncodedSize(ch)
        }
        // base64 按整块计算，单字符按 UTF-8 字节数估算上界
        Int64(String([ch]).toArray().size)
    }

    private static func qEncodedSize(ch: Rune): Int64 {
        let v = UInt32(ch)
        if (v == 32) {
            return 1
        }
        if (v >= 33 && v <= 126 && v != 61 && v != 63 && v != 95) {
            return 1
        }
        Int64(String([ch]).toArray().size) * 3
    }

    private static func renderWord(
        runes: ArrayList<Rune>,
        charsetName: String,
        marker: String,
        useQ: Bool
    ): String {
        let text = String(runes.toArray())
        let bytes = text.toArray()
        let payload = if (useQ) {
            qEncode(bytes)
        } else {
            Base64Codec.encodeUnwrapped(bytes)
        }
        "=?${charsetName}?${marker}?${payload}?="
    }

    private static func qEncode(bytes: Array<Byte>): String {
        let out = StringBuilder()
        for (b in bytes) {
            let v = Int64(b)
            if (v == 32) {
                out.append("_")
            } else if (v >= 33 && v <= 126 && v != 61 && v != 63 && v != 95) {
                out.append(Rune(UInt32(v)))
            } else {
                out.append("=")
                out.append(Rune(UInt32(QuotedPrintable.HEX[v >> 4])))
                out.append(Rune(UInt32(QuotedPrintable.HEX[v & 0x0F])))
            }
        }
        out.toString()
    }

    private static func qDecode(payload: String): Array<Byte> {
        let bytes = payload.toArray()
        let out = ArrayList<Byte>()
        var i = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (b == b'_') {
                out.add(b' ')
                i += 1
                continue
            }
            if (b == b'=' && i + 2 < bytes.size) {
                let hi = QuotedPrintable.hexValue(bytes[i + 1])
                let lo = QuotedPrintable.hexValue(bytes[i + 2])
                if (hi >= 0 && lo >= 0) {
                    out.add(UInt8((hi << 4) | lo))
                    i += 3
                    continue
                }
            }
            out.add(b)
            i += 1
        }
        out.toArray()
    }

    /** 在 `i` 处尝试解析一个 encoded-word；失败返回 `None`（宽松模式按普通文本处理）。 */
    private static func parseAt(runes: Array<Rune>, start: Int64, strict: Bool): ?(String, Int64) {
        var i = start + 2
        let charsetStart = i
        while (i < runes.size && runes[i] != r'?') {
            i += 1
        }
        if (i >= runes.size) {
            return None
        }
        let charsetText = String(runes[charsetStart..i])
        i += 1
        if (i >= runes.size) {
            return None
        }
        let encoding = runes[i]
        i += 1
        if (i >= runes.size || runes[i] != r'?') {
            return None
        }
        i += 1
        let payloadStart = i
        while (i + 1 < runes.size) {
            if (runes[i] == r'?' && runes[i + 1] == r'=') {
                let payload = String(runes[payloadStart..i])
                let bytes = if (encoding == r'B' || encoding == r'b') {
                    Base64Codec.decode(payload, strict: strict)
                } else if (encoding == r'Q' || encoding == r'q') {
                    qDecode(payload)
                } else {
                    return None
                }
                let decoded = CharsetResolver.decode(bytes, Some(charsetText), options: CharsetOptions(strict: strict))
                return Some((decoded.text, i + 2))
            }
            i += 1
        }
        None
    }

    private static func isWhitespace(ch: Rune): Bool {
        ch == r' ' || ch == r'\t' || ch == r'\r' || ch == r'\n'
    }
}
