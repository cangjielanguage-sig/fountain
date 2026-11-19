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

import std.collection.{ArrayList, HashMap}

/**
 * 头参数集合（`Content-Type` / `Content-Disposition` 的分号参数）。
 *
 * 解析侧按 RFC 2231 处理三种写法，优先级 `name*` > 续行 `name*0*` > `name` > RFC 2047：
 *
 * ```
 * filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf
 * filename*0*=UTF-8''%E4%B8%AD; filename*1*=%E6%96%87.pdf
 * filename="=?UTF-8?B?...?="          // 旧客户端的非标准写法，仅解析兼容
 * ```
 *
 * 生成侧**不用 RFC 2047**：非 ASCII 一律 `name*=UTF-8''...`，纯 ASCII 用 `name="..."`。
 */
public class MimeParameters {
    private let items = ArrayList<(String, String)>()

    public init() {}

    public prop size: Int64 {
        get() {
            items.size
        }
    }

    public func add(name: String, value: String): Unit {
        items.add((name.toAsciiLower(), value))
    }

    public func get(name: String): ?String {
        let key = name.toAsciiLower()
        for ((name0, value) in items) {
            if (name0 == key) {
                return Some(value)
            }
        }
        None
    }

    public func contains(name: String): Bool {
        get(name).isSome()
    }

    public func entries(): Array<(String, String)> {
        items.toArray()
    }

    public func isEmpty(): Bool {
        items.isEmpty()
    }

    /** 生成 `; name=value` 片段（含前导分号）。 */
    public func toHeaderValue(): String {
        let out = StringBuilder()
        for ((name, value) in items) {
            out.append("; ")
            if (MimeParameter.needsExtended(value)) {
                out.append(name)
                out.append("*=")
                out.append("UTF-8''")
                out.append(MimeParameter.percentEncode(value.toArray()))
            } else {
                out.append(name)
                out.append("=\"")
                out.append(MimeParameter.escapeQuoted(value))
                out.append("\"")
            }
        }
        out.toString()
    }
}

/** RFC 2231 / RFC 2047 参数解析与生成。 */
public class MimeParameter {
    /**
     * 解析参数列表原文（第一个 `;` 之后的部分）。
     *
     * 调用方先剥掉 media type / disposition 本身再传进来。
     */
    public static func parse(text: String, strict!: Bool = false): MimeParameters {
        let raw = splitSegments(text)
        let values = HashMap<String, String>()
        let order = ArrayList<String>()
        for (segment in raw) {
            let eq = segment.indexOf("=") ?? -1
            if (eq < 0) {
                if (strict) {
                    throw MimeException("非法参数（缺少 =）：${segment}")
                }
                continue
            }
            let name = segment[0..eq].trimAscii().toAsciiLower()
            let value = unquote(segment[(eq + 1)..].trimAscii())
            if (name.size == 0) {
                continue
            }
            if (!values.contains(name)) {
                order.add(name)
            }
            values[name] = value
        }
        let result = MimeParameters()
        let consumed = HashMap<String, Bool>()
        for (name in order) {
            if (consumed.contains(name)) {
                continue
            }
            let base = baseName(name)
            if (consumed.contains(base)) {
                continue
            }
            if (let Some(value) <- resolve(base, values)) {
                result.add(base, value)
                consumed[base] = true
            }
        }
        result
    }

    /**
     * 解析单个 `name*=charset'lang'value` 值。
     */
    public static func parseExtended(value: String): ?String {
        let firstQuote = value.indexOf("'") ?? -1
        if (firstQuote < 0) {
            return None
        }
        let charset = value[0..firstQuote]
        let rest = value[(firstQuote + 1)..]
        let secondQuote = rest.indexOf("'") ?? -1
        if (secondQuote < 0) {
            return None
        }
        let encoded = rest[(secondQuote + 1)..]
        let bytes = percentDecode(encoded)
        Some(CharsetResolver.decode(bytes, Some(charset)).text)
    }

    /** 生成单个参数值：非 ASCII 走 RFC 2231，纯 ASCII 加引号。 */
    public static func formatValue(value: String): String {
        if (needsExtended(value)) {
            return "UTF-8''${percentEncode(value.toArray())}"
        }
        "\"${escapeQuoted(value)}\""
    }

    // ---------- 内部 ----------

    private static func baseName(name: String): String {
        let star = name.indexOf("*") ?? -1
        if (star > 0) {
            return name[0..star]
        }
        name
    }

    private static func resolve(base: String, values: HashMap<String, String>): ?String {
        // 1. 单段扩展值
        if (let Some(single) <- values.get(base + "*")) {
            if (let Some(decoded) <- parseExtended(single)) {
                return Some(decoded)
            }
        }
        // 2. 续行
        if (values.contains(base + "*0") || values.contains(base + "*0*")) {
            if (let Some(joined) <- joinContinuation(base, values)) {
                return Some(joined)
            }
        }
        // 3. 普通参数
        if (let Some(plain) <- values.get(base)) {
            if (plain.contains("=?")) {
                return Some(EncodedWord.decode(plain))
            }
            return Some(plain)
        }
        // 4. 只会剩下 "base*1" 这类缺 0 的残片：忽略
        None
    }

    private static func joinContinuation(base: String, values: HashMap<String, String>): ?String {
        var charset = "UTF-8"
        var index = 0
        let bytes = ArrayList<Byte>()
        var first = true
        while (true) {
            let starredName = "${base}*${index}*"
            let plainName = "${base}*${index}"
            let segment = if (let Some(v) <- values.get(starredName)) {
                Some((v, true))
            } else if (let Some(v) <- values.get(plainName)) {
                Some((v, false))
            } else {
                None<(String, Bool)>
            }
            if (let Some((value, encoded)) <- segment) {
                var payload = value
                if (first && encoded) {
                    let firstQuote = payload.indexOf("'") ?? -1
                    if (firstQuote > 0) {
                        charset = payload[0..firstQuote]
                        let rest = payload[(firstQuote + 1)..]
                        let second = rest.indexOf("'") ?? -1
                        if (second >= 0) {
                            payload = rest[(second + 1)..]
                        }
                    }
                }
                let part = if (encoded) {
                    percentDecode(payload)
                } else {
                    payload.toArray()
                }
                for (b in part) {
                    bytes.add(b)
                }
                first = false
                index += 1
            } else {
                break
            }
        }
        if (first) {
            return None
        }
        Some(CharsetResolver.decode(bytes.toArray(), Some(charset)).text)
    }

    private static func splitSegments(text: String): Array<String> {
        let out = ArrayList<String>()
        var current = ""
        var inQuote = false
        var inComment = false
        var escaped = false
        for (ch in text.toRuneArray()) {
            if (escaped) {
                current = current + String([ch])
                escaped = false
                continue
            }
            if (ch == r'\\' && inQuote) {
                current = current + String([ch])
                escaped = true
                continue
            }
            if (ch == r'"') {
                inQuote = !inQuote
                current = current + String([ch])
                continue
            }
            if (!inQuote) {
                if (ch == r'(') {
                    inComment = true
                    continue
                } else if (ch == r')') {
                    if (inComment) {
                        inComment = false
                        continue
                    }
                    inComment = false
                }
            }
            if (inComment) {
                continue
            }
            if (ch == r';' && !inQuote) {
                let segment = current
                if (segment.trimAscii().size > 0) {
                    out.add(segment)
                }
                current = ""
                continue
            }
            current = current + String([ch])
        }
        let tail = current
        if (tail.trimAscii().size > 0) {
            out.add(tail)
        }
        out.toArray()
    }

    private static func unquote(text: String): String {
        if (text.size >= 2 && text[0] == b'"' && text[text.size - 1] == b'"') {
            let inner = text[1..(text.size - 1)]
            return inner.replace("\\\"", "\"").replace("\\\\", "\\")
        }
        text
    }

    static func needsExtended(value: String): Bool {
        for (b in value.toArray()) {
            if (b > 126 || b < 32) {
                return true
            }
        }
        false
    }

    static func escapeQuoted(value: String): String {
        value.replace("\\", "\\\\").replace("\"", "\\\"")
    }

    static func percentDecode(text: String): Array<Byte> {
        let bytes = text.toArray()
        let out = ArrayList<Byte>()
        var i = 0
        while (i < bytes.size) {
            if (bytes[i] == b'%' && i + 2 < bytes.size) {
                let hi = QuotedPrintable.hexValue(bytes[i + 1])
                let lo = QuotedPrintable.hexValue(bytes[i + 2])
                if (hi >= 0 && lo >= 0) {
                    out.add(UInt8((hi << 4) | lo))
                    i += 3
                    continue
                }
            }
            out.add(bytes[i])
            i += 1
        }
        out.toArray()
    }

    static func percentEncode(bytes: Array<Byte>): String {
        let out = StringBuilder()
        for (b in bytes) {
            let v = Int64(b)
            if (isUnreserved(v)) {
                out.append(Rune(UInt32(v)))
            } else {
                out.append("%")
                out.append(Rune(UInt32(QuotedPrintable.HEX[v >> 4])))
                out.append(Rune(UInt32(QuotedPrintable.HEX[v & 0x0F])))
            }
        }
        out.toString()
    }

    private static func isUnreserved(v: Int64): Bool {
        (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) ||
            v == 45 || v == 46 || v == 95 || v == 126
    }
}
