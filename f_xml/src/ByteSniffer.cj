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
package fountain::f_xml

import std.io.InputStream
import std.collection.ArrayList

/**
 * 嗅探得到的输入编码。
 *
 * UTF-16 / UTF-32 是确定性的字节序编码，不走 `readln()`（见 `BlockRuneSource`）；
 * 其余编码交给 `charset4cj.TextReader`。
 */
internal enum DetectedEncoding <: ToString {
    | Utf8
    | Utf16Le
    | Utf16Be
    | Utf32Le
    | Utf32Be
    | Other(Charset)

    public func toString(): String {
        match (this) {
            case Utf8 => "UTF-8"
            case Utf16Le => "UTF-16LE"
            case Utf16Be => "UTF-16BE"
            case Utf32Le => "UTF-32LE"
            case Utf32Be => "UTF-32BE"
            case Other(cs) => cs.toString()
        }
    }
}

/** 嗅探结果：编码 + 已消费字节（含 BOM）+ 需要跳过前导 BOM 的字节数。 */
internal struct SniffResult {
    let encoding: DetectedEncoding
    let prefix: Array<Byte>
    let bomLength: Int64

    init(encoding: DetectedEncoding, prefix: Array<Byte>, bomLength: Int64) {
        this.encoding = encoding
        this.prefix = prefix
        this.bomLength = bomLength
    }
}

/**
 * 字节序与字符集嗅探。
 *
 * 优先级固定为 **BOM → XML 声明 → UTF-8**。BOM 与声明冲突时以 BOM 为准，不报错：
 * 现实里「UTF-8 BOM + 声明 latin1」大量存在，报错会把能读的文件判死。
 *
 * 最多消费 `4 + 1024` 字节，全部经 `PrefixStream` 回放，不丢弃。
 */
internal class ByteSniffer {
    static let EXTRA_SCAN: Int64 = 1024

    static func sniff(input: InputStream): SniffResult {
        let head = ArrayList<Byte>()
        readUpTo(input, head, 4)

        let isUtf32Be = head.size >= 4 && head[0] == 0x00 && head[1] == 0x00 && head[2] == 0xFE && head[3] == 0xFF
        let isUtf32Le = head.size >= 4 && head[0] == 0xFF && head[1] == 0xFE && head[2] == 0x00 && head[3] == 0x00
        if (isUtf32Be) {
            fill(input, head, 4 + EXTRA_SCAN)
            return SniffResult(DetectedEncoding.Utf32Be, head.toArray(), 4)
        }
        if (isUtf32Le) {
            fill(input, head, 4 + EXTRA_SCAN)
            return SniffResult(DetectedEncoding.Utf32Le, head.toArray(), 4)
        }
        if (head.size >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) {
            fill(input, head, 4 + EXTRA_SCAN)
            return SniffResult(DetectedEncoding.Utf8, head.toArray(), 3)
        }
        if (head.size >= 2 && head[0] == 0xFF && head[1] == 0xFE) {
            fill(input, head, 4 + EXTRA_SCAN)
            return SniffResult(DetectedEncoding.Utf16Le, head.toArray(), 2)
        }
        if (head.size >= 2 && head[0] == 0xFE && head[1] == 0xFF) {
            fill(input, head, 4 + EXTRA_SCAN)
            return SniffResult(DetectedEncoding.Utf16Be, head.toArray(), 2)
        }

        // 无 BOM：按 XML 1.0 附录 F 的魔数判字节序。
        if (head.size >= 4) {
            if (head[0] == 0x3C && head[1] == 0x00 && head[2] == 0x3F && head[3] == 0x00) {
                fill(input, head, 4 + EXTRA_SCAN)
                return SniffResult(DetectedEncoding.Utf16Le, head.toArray(), 0)
            }
            if (head[0] == 0x00 && head[1] == 0x3C && head[2] == 0x00 && head[3] == 0x3F) {
                fill(input, head, 4 + EXTRA_SCAN)
                return SniffResult(DetectedEncoding.Utf16Be, head.toArray(), 0)
            }
            if (head[0] == 0x00 && head[1] == 0x00 && head[2] == 0x00 && head[3] == 0x3C) {
                fill(input, head, 4 + EXTRA_SCAN)
                return SniffResult(DetectedEncoding.Utf32Be, head.toArray(), 0)
            }
            if (head[0] == 0x3C && head[1] == 0x00 && head[2] == 0x00 && head[3] == 0x00) {
                fill(input, head, 4 + EXTRA_SCAN)
                return SniffResult(DetectedEncoding.Utf32Le, head.toArray(), 0)
            }
        }

        fill(input, head, 4 + EXTRA_SCAN)
        let bytes = head.toArray()
        if (let Some(name) <- findDeclaredEncoding(bytes)) {
            if (let Some(encoding) <- resolveCharset(name)) {
                return SniffResult(encoding, bytes, 0)
            }
            // 未知字符集名按 UTF-8 处理：真实的解码会在遇到非 ASCII 时给出明确错误，
            // 而「声明里写了个我们不认识的名字」不应让整份文档连前导区都读不出来。
        }
        SniffResult(DetectedEncoding.Utf8, bytes, 0)
    }

    private static func readUpTo(input: InputStream, sink: ArrayList<Byte>, total: Int64): Unit {
        while (sink.size < total) {
            let buf = Array<Byte>(total - sink.size, repeat: 0)
            let n = input.read(buf)
            if (n <= 0) {
                return
            }
            for (i in 0..n) {
                sink.add(buf[i])
            }
        }
    }

    private static func fill(input: InputStream, sink: ArrayList<Byte>, total: Int64): Unit {
        readUpTo(input, sink, total)
    }

    /**
     * 在已读字节里找 `<?xml ... encoding="..."?>`，单双引号都接受。
     *
     * 只扫描 ASCII 兼容编码：UTF-16/32 在魔数阶段已经确定，不会再走到这里。
     */
    static func findDeclaredEncoding(bytes: Array<Byte>): ?String {
        let text = asciiOf(bytes)
        if (let Some(start) <- text.indexOf("<?xml")) {
            let declEnd = match (text.indexOf("?>", start)) {
                case Some(e) => e
                case None => text.size
            }
            let decl = text[start..declEnd].toArray()
            if (let Some(encIndex) <- text[start..declEnd].indexOf("encoding")) {
                let enc = Int64(encIndex)
                var i = enc + "encoding".size
                while (i < decl.size && isAsciiSpaceByte(decl[i])) {
                    i++
                }
                if (i < decl.size && decl[i] == 0x3D) {
                    i++
                    while (i < decl.size && isAsciiSpaceByte(decl[i])) {
                        i++
                    }
                    if (i < decl.size) {
                        let quoteByte = decl[i]
                        if (quoteByte == 0x22 || quoteByte == 0x27) {
                            i++
                            let valueStart = i
                            while (i < decl.size && decl[i] != quoteByte) {
                                i++
                            }
                            if (i < decl.size) {
                                return String.fromUtf8(decl[valueStart..i])
                            }
                        }
                    }
                }
            }
        }
        None
    }

    private static func asciiOf(bytes: Array<Byte>): String {
        let out = ArrayList<Byte>()
        for (b in bytes) {
            out.add(b)
        }
        String.fromUtf8(out.toArray())
    }

    private static func isAsciiSpaceByte(b: Byte): Bool {
        b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A
    }

    /** 把声明里的字符集名解析成编码；名称大小写不敏感（`Charsets.forName` 已覆盖标签）。 */
    static func resolveCharset(name: String): ?DetectedEncoding {
        let trimmed = name.trimAscii()
        if (trimmed.isEmpty()) {
            return None
        }
        match (trimmed.toAsciiUpper()) {
            case "UTF-8" | "UTF8" => Some(DetectedEncoding.Utf8)
            case "UTF-16" | "UTF-16LE" | "UTF16LE" => Some(DetectedEncoding.Utf16Le)
            case "UTF-16BE" | "UTF16BE" => Some(DetectedEncoding.Utf16Be)
            case "UTF-32" | "UTF-32LE" | "UTF32LE" => Some(DetectedEncoding.Utf32Le)
            case "UTF-32BE" | "UTF32BE" => Some(DetectedEncoding.Utf32Be)
            case _ => match (Charsets.forName(trimmed)) {
                case Some(cs) => Some(DetectedEncoding.Other(cs))
                case None => None
            }
        }
    }
}
