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
import std.io.{InputStream, OutputStream}

/**
 * base64 编解码。
 *
 * 不用 `stdx.encoding.base64`：它对缺 padding、含空白、含非法字符一律返回 `None`，
 * 而邮件里这三种情况都是常态。这里的解码忽略空白、容忍缺 padding，非法字符按严格/宽松两态处理。
 *
 * 编码按 RFC 2045：每 76 字符插入 `CRLF`，末尾补齐 `=`。
 */
public class Base64Codec {
    private static let ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    static let PAD: Byte = b'='

    /** 按 76 列 + CRLF 编码。 */
    public static func encode(bytes: Array<Byte>, lineLength!: Int64 = 76): String {
        let chars = encodeUnwrapped(bytes)
        if (lineLength <= 0 || chars.size <= lineLength) {
            return chars
        }
        let out = ArrayList<Byte>()
        var line = 0
        for (b in chars.toArray()) {
            if (line == lineLength) {
                out.add(b'\r')
                out.add(b'\n')
                line = 0
            }
            out.add(b)
            line += 1
        }
        String.fromUtf8(out.toArray())
    }

    /** 不折行的编码（modified UTF-7、SASL 初始响应使用）。 */
    public static func encodeUnwrapped(bytes: Array<Byte>): String {
        if (bytes.size == 0) {
            return ""
        }
        let out = ArrayList<Byte>()
        var i = 0
        while (i + 2 < bytes.size) {
            let n = (Int64(bytes[i]) << 16) | (Int64(bytes[i + 1]) << 8) | Int64(bytes[i + 2])
            out.add(ALPHABET[(n >> 18) & 0x3F])
            out.add(ALPHABET[(n >> 12) & 0x3F])
            out.add(ALPHABET[(n >> 6) & 0x3F])
            out.add(ALPHABET[n & 0x3F])
            i += 3
        }
        let rest = bytes.size - i
        if (rest == 1) {
            let n = Int64(bytes[i]) << 16
            out.add(ALPHABET[(n >> 18) & 0x3F])
            out.add(ALPHABET[(n >> 12) & 0x3F])
            out.add(PAD)
            out.add(PAD)
        } else if (rest == 2) {
            let n = (Int64(bytes[i]) << 16) | (Int64(bytes[i + 1]) << 8)
            out.add(ALPHABET[(n >> 18) & 0x3F])
            out.add(ALPHABET[(n >> 12) & 0x3F])
            out.add(ALPHABET[(n >> 6) & 0x3F])
            out.add(PAD)
        }
        String.fromUtf8(out.toArray())
    }

    /** 解码字符串：忽略空白、容忍缺 padding。 */
    public static func decode(text: String, strict!: Bool = false): Array<Byte> {
        decodeBytes(text.toArray(), strict: strict)
    }

    public static func decodeBytes(bytes: Array<Byte>, strict!: Bool = false): Array<Byte> {
        let out = ArrayList<Byte>()
        var group = Array<Byte>(4, repeat: 0)
        var count = 0
        var padded = false
        for (b in bytes) {
            if (isWhitespace(b)) {
                continue
            }
            if (b == PAD) {
                padded = true
                continue
            }
            if (padded && strict) {
                throw MimeException("base64 在 padding 之后仍有数据")
            }
            let value = charValue(b)
            if (value < 0) {
                if (strict) {
                    throw MimeException("base64 含非法字符：${Rune(UInt32(b))}")
                }
                continue
            }
            group[count] = UInt8(value)
            count += 1
            if (count == 4) {
                emitGroup(group, 4, out)
                count = 0
            }
        }
        if (count > 0) {
            if (count == 1) {
                if (strict) {
                    throw MimeException("base64 尾部只剩 1 个字符")
                }
            } else {
                // 缺 padding：当作补足 '=' 处理
                group[count] = PAD
                count += 1
                while (count < 4) {
                    group[count] = PAD
                    count += 1
                }
                emitGroup(group, 4, out)
            }
        }
        out.toArray()
    }

    // ---------- 内部 ----------

    static func isWhitespace(b: Byte): Bool {
        b == b' ' || b == b'\r' || b == b'\n' || b == b'\t'
    }

    static func charValue(b: Byte): Int64 {
        if (b >= b'A' && b <= b'Z') {
            return Int64(b - b'A')
        }
        if (b >= b'a' && b <= b'z') {
            return 26 + Int64(b - b'a')
        }
        if (b >= b'0' && b <= b'9') {
            return 52 + Int64(b - b'0')
        }
        if (b == b'+') {
            return 62
        }
        if (b == b'/') {
            return 63
        }
        -1
    }

    static func emitGroup(group: Array<Byte>, size: Int64, out: ArrayList<Byte>): Unit {
        let a = Int64(group[0]) & 0x3F
        let b = Int64(group[1]) & 0x3F
        let c = Int64(group[2]) & 0x3F
        let d = Int64(group[3]) & 0x3F
        let n = (a << 18) | (b << 12) | (c << 6) | d
        out.add(UInt8((n >> 16) & 0xFF))
        if (size < 3 || group[2] == PAD) {
            return
        }
        out.add(UInt8((n >> 8) & 0xFF))
        if (size < 4 || group[3] == PAD) {
            return
        }
        out.add(UInt8(n & 0xFF))
    }

    /**
     * 流式编码器：边写边编码，按 76 列折行。
     *
     * 跨块边界只留最多 2 个未成组的字节，不整块缓存。
     */
    public static func encoder(output: OutputStream, lineLength!: Int64 = 76): Base64Encoder {
        Base64Encoder(output, lineLength: lineLength)
    }
}

/** 流式 base64 编码器。 */
public class Base64Encoder <: OutputStream {
    private let output: OutputStream
    private let lineLength: Int64
    private var carry = Array<Byte>(2, repeat: 0)
    private var carrySize = 0
    private var line = 0
    private var lineBuffer = ArrayList<Byte>()

    init(output: OutputStream, lineLength!: Int64 = 76) {
        this.output = output
        this.lineLength = lineLength
    }

    public func write(buffer: Array<Byte>): Unit {
        var i = 0
        while (i < buffer.size) {
            if (carrySize == 2) {
                emitThree(carry[0], carry[1], buffer[i])
                carrySize = 0
                i += 1
                continue
            }
            carry[carrySize] = buffer[i]
            carrySize += 1
            i += 1
        }
    }

    /** 结束编码：补齐 padding 并刷出最后不足一行的内容。 */
    public func finish(): Unit {
        if (carrySize == 1) {
            let chars = Base64Codec.encodeUnwrapped([carry[0]])
            push(chars)
        } else if (carrySize == 2) {
            let chars = Base64Codec.encodeUnwrapped([carry[0], carry[1]])
            push(chars)
        }
        carrySize = 0
        flushLine()
    }

    private func emitThree(a: Byte, b: Byte, c: Byte): Unit {
        push(Base64Codec.encodeUnwrapped([a, b, c]))
    }

    private func push(text: String): Unit {
        for (ch in text.toArray()) {
            if (line == lineLength) {
                lineBuffer.add(b'\r')
                lineBuffer.add(b'\n')
                line = 0
            }
            lineBuffer.add(ch)
            line += 1
        }
        if (lineBuffer.size >= 8192) {
            flushLine()
        }
    }

    private func flushLine(): Unit {
        if (lineBuffer.size > 0) {
            output.write(lineBuffer.toArray())
            lineBuffer = ArrayList<Byte>()
        }
    }
}

/**
 * 流式 base64 解码器。
 *
 * 忽略空白；缺 padding 时在 EOF 按补 `=` 处理；非法字符按宽松（跳过）/严格（抛错）两态。
 */
public class Base64Decoder <: InputStream {
    private let input: InputStream
    private let strict: Bool
    private var inputBuffer = Array<Byte>(8192, repeat: 0)
    private var inputPos = 0
    private var inputLimit = 0
    private var eof = false
    private var group = Array<Byte>(4, repeat: 0)
    private var groupSize = 0
    private var padded = false
    private var finished = false
    private var pending = ArrayList<Byte>()
    private var pendingPos = 0

    init(input: InputStream, strict!: Bool = false) {
        this.input = input
        this.strict = strict
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.size == 0) {
            return 0
        }
        while (pendingPos >= pending.size && !finished) {
            pending = ArrayList<Byte>()
            pendingPos = 0
            fillPending()
        }
        var written = 0
        while (written < buffer.size && pendingPos < pending.size) {
            buffer[written] = pending[pendingPos]
            pendingPos += 1
            written += 1
        }
        written
    }

    // ---------- 内部 ----------

    private func fillPending(): Unit {
        while (true) {
            let b = nextByte()
            if (b.isNone()) {
                finishTail()
                return
            }
            let value = b.getOrThrow()
            if (value == Base64Codec.PAD) {
                padded = true
                finishTail()
                return
            }
            if (Base64Codec.isWhitespace(value)) {
                continue
            }
            if (padded && strict) {
                throw MimeException("base64 在 padding 之后仍有数据")
            }
            let v = Base64Codec.charValue(value)
            if (v < 0) {
                if (strict) {
                    throw MimeException("base64 含非法字符")
                }
                continue
            }
            group[groupSize] = UInt8(v)
            groupSize += 1
            if (groupSize == 4) {
                Base64Codec.emitGroup(group, 4, pending)
                groupSize = 0
                if (pending.size > 0) {
                    return
                }
            }
        }
    }

    private func finishTail(): Unit {
        if (groupSize == 0) {
            finished = true
            return
        }
        if (groupSize == 1) {
            if (strict) {
                throw MimeException("base64 尾部只剩 1 个字符")
            }
            groupSize = 0
            finished = true
            return
        }
        let padding = Base64Codec.PAD
        group[groupSize] = padding
        groupSize += 1
        while (groupSize < 4) {
            group[groupSize] = padding
            groupSize += 1
        }
        Base64Codec.emitGroup(group, 4, pending)
        groupSize = 0
        finished = true
    }

    private func nextByte(): ?Byte {
        if (inputPos >= inputLimit) {
            if (eof) {
                return None
            }
            let tmp = Array<Byte>(inputBuffer.size, repeat: 0)
            let n = input.read(tmp)
            if (n <= 0) {
                eof = true
                return None
            }
            for (i in 0..n) {
                inputBuffer[i] = tmp[i]
            }
            inputPos = 0
            inputLimit = n
        }
        let b = inputBuffer[inputPos]
        inputPos += 1
        Some(b)
    }
}
