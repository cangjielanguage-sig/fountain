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
 * quoted-printable 编解码（RFC 2045 §6.7）。
 *
 * 三个容易写错的点，这里都按状态机处理：
 *
 * 1. **跨块残留**：`=4` 被块边界切开时不能当成非法序列，必须留到下一块；
 * 2. **行尾空格/制表符**必须编码成 `=20` / `=09`，否则会在传输中被剥掉；
 * 3. **软换行 `=\r\n` 不能落在 `=XX` 中间**——生成时先算好再换行，解码时整体回退。
 */
public class QuotedPrintable {
    public static let HEX = "0123456789ABCDEF"

    public static func encode(bytes: Array<Byte>, lineLength!: Int64 = 76): String {
        let out = CollectingOutput()
        let encoder = QuotedPrintableEncoder(out, lineLength: lineLength)
        encoder.write(bytes)
        encoder.finish()
        out.text()
    }

    public static func decode(text: String, strict!: Bool = false): Array<Byte> {
        let input = ArrayInput(text.toArray())
        let decoder = QuotedPrintableDecoder(input, strict: strict)
        let out = ArrayList<Byte>()
        let buf = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = decoder.read(buf)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.add(buf[i])
            }
        }
        out.toArray()
    }

    static func hexValue(b: Byte): Int64 {
        if (b >= b'0' && b <= b'9') {
            return Int64(b - b'0')
        }
        if (b >= b'A' && b <= b'F') {
            return 10 + Int64(b - b'A')
        }
        if (b >= b'a' && b <= b'f') {
            return 10 + Int64(b - b'a')
        }
        -1
    }
}

/** 流式 QP 编码器。 */
public class QuotedPrintableEncoder <: OutputStream {
    private let output: OutputStream
    private let lineLength: Int64
    private var lineLen = 0
    private var pendingCr = false
    private var pendingSpaces = ArrayList<Byte>()
    private var buffer = ArrayList<Byte>()

    init(output: OutputStream, lineLength!: Int64 = 76) {
        this.output = output
        this.lineLength = lineLength
    }

    public func write(bytes: Array<Byte>): Unit {
        for (b in bytes) {
            if (pendingCr) {
                pendingCr = false
                endOfLine()
                if (b == b'\n') {
                    continue
                }
            }
            if (b == b'\r') {
                pendingCr = true
                continue
            }
            if (b == b'\n') {
                endOfLine()
                continue
            }
            if (b == b' ' || b == b'\t') {
                pendingSpaces.add(b)
                continue
            }
            flushSpaces(false)
            writeToken(b)
        }
        flushIfLarge()
    }

    public func finish(): Unit {
        if (pendingCr) {
            pendingCr = false
            endOfLine()
        }
        // 正文末尾的空格/制表符必须编码，否则会被传输层剥掉
        flushSpaces(true)
        if (buffer.size > 0) {
            output.write(buffer.toArray())
            buffer = ArrayList<Byte>()
        }
    }

    // ---------- 内部 ----------

    private func endOfLine(): Unit {
        flushSpaces(true)
        buffer.add(b'\r')
        buffer.add(b'\n')
        lineLen = 0
        flushIfLarge()
    }

    /** 把延迟的空格写出去：`encode=true` 时按 `=20` / `=09` 编码。 */
    private func flushSpaces(encode: Bool): Unit {
        for (b in pendingSpaces) {
            if (encode) {
                writeEncoded(b)
            } else {
                emitOne(b)
            }
        }
        pendingSpaces = ArrayList<Byte>()
    }

    private func writeToken(b: Byte): Unit {
        if (b == b'=' || Int64(b) > 126 || Int64(b) < 32 || Int64(b) == 127) {
            writeEncoded(b)
            return
        }
        emitOne(b)
    }

    private func writeEncoded(b: Byte): Unit {
        if (lineLen + 3 > 75) {
            softBreak()
        }
        let hi = Int64(b) >> 4
        let lo = Int64(b) & 0x0F
        buffer.add(b'=')
        buffer.add(QuotedPrintable.HEX[hi])
        buffer.add(QuotedPrintable.HEX[lo])
        lineLen += 3
    }

    private func emitOne(b: Byte): Unit {
        if (lineLen + 1 > 75) {
            softBreak()
        }
        buffer.add(b)
        lineLen += 1
    }

    private func softBreak(): Unit {
        buffer.add(b'=')
        buffer.add(b'\r')
        buffer.add(b'\n')
        lineLen = 0
    }

    private func flushIfLarge(): Unit {
        if (buffer.size >= 8192) {
            output.write(buffer.toArray())
            buffer = ArrayList<Byte>()
        }
    }
}

/** 流式 QP 解码器。 */
public class QuotedPrintableDecoder <: InputStream {
    private let input: InputStream
    private let strict: Bool
    private var inBuffer = Array<Byte>(8192, repeat: 0)
    private var inPos = 0
    private var inLimit = 0
    private var eof = false
    private var pending = ArrayList<Byte>()
    private var pendingPos = 0
    private var finished = false

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
            decodeSome()
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

    private func decodeSome(): Unit {
        while (pending.size == 0) {
            let b = next()
            if (b.isNone()) {
                finished = true
                return
            }
            let value = b.getOrThrow()
            if (value != b'=') {
                pending.add(value)
                return
            }
            let first = next()
            if (first.isNone()) {
                // 末尾孤立的 '='：宽松原样保留
                if (strict) {
                    throw MimeException("quoted-printable 以孤立的 '=' 结束")
                }
                pending.add(b'=')
                finished = true
                return
            }
            let f = first.getOrThrow()
            if (f == b'\n') {
                // 裸 LF 软换行
                continue
            }
            if (f == b'\r') {
                let second = next()
                if (second.isSome() && second.getOrThrow() == b'\n') {
                    continue
                }
                if (strict) {
                    throw MimeException("quoted-printable 的软换行不是 CRLF")
                }
                pending.add(b'=')
                pending.add(b'\r')
                if (let Some(s) <- second) {
                    pending.add(s)
                }
                return
            }
            let hi = QuotedPrintable.hexValue(f)
            if (hi < 0) {
                if (strict) {
                    throw MimeException("quoted-printable 含非法转义")
                }
                pending.add(b'=')
                pending.add(f)
                return
            }
            let second = next()
            if (second.isNone()) {
                if (strict) {
                    throw MimeException("quoted-printable 转义被截断")
                }
                pending.add(b'=')
                pending.add(f)
                finished = true
                return
            }
            let lo = QuotedPrintable.hexValue(second.getOrThrow())
            if (lo < 0) {
                if (strict) {
                    throw MimeException("quoted-printable 含非法转义")
                }
                pending.add(b'=')
                pending.add(f)
                pending.add(second.getOrThrow())
                return
            }
            pending.add(UInt8((hi << 4) | lo))
            return
        }
    }

    private func next(): ?Byte {
        while (inPos >= inLimit) {
            if (eof) {
                return None
            }
            let tmp = Array<Byte>(inBuffer.size, repeat: 0)
            let n = input.read(tmp)
            if (n <= 0) {
                eof = true
                return None
            }
            for (i in 0..n) {
                inBuffer[i] = tmp[i]
            }
            inPos = 0
            inLimit = n
        }
        let b = inBuffer[inPos]
        inPos += 1
        Some(b)
    }
}

// ---------- 本地小工具（避免测试再引 std.io 的实现） ----------

class CollectingOutput <: OutputStream {
    private let buffer = ArrayList<Byte>()

    public func write(bytes: Array<Byte>): Unit {
        for (b in bytes) {
            buffer.add(b)
        }
    }

    func text(): String {
        String.fromUtf8(buffer.toArray())
    }
}

class ArrayInput <: InputStream {
    private let bytes: Array<Byte>
    private var pos = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= bytes.size) {
            return 0
        }
        var take = bytes.size - pos
        if (take > buffer.size) {
            take = buffer.size
        }
        for (i in 0..take) {
            buffer[i] = bytes[pos + i]
        }
        pos += take
        take
    }
}
