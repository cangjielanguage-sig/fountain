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
package fountain::f_email.mime

import std.collection.ArrayList
import std.io.InputStream
import fountain::f_email.model.{LimitKind, MailLimitException}

/**
 * 带 peek 的字节源。
 *
 * multipart 的边界判定需要向前看 `2 + boundary.length` 个字节，
 * 但**不能**把整段正文读进内存——附件的行可能很长，也可能是二进制。
 */
class ByteSource <: InputStream {
    private let input: InputStream
    private var buffer = Array<Byte>(65536, repeat: 0)
    private var pos = 0
    private var limit = 0
    private var eof = false

    init(input: InputStream) {
        this.input = input
    }

    /** 保证从 `pos` 起至少 `n` 个字节可读。 */
    func ensure(n: Int64): Bool {
        if (limit - pos >= n) {
            return true
        }
        if (n > buffer.size) {
            let bigger = Array<Byte>(n * 2, repeat: 0)
            for (i in 0..(limit - pos)) {
                bigger[i] = buffer[pos + i]
            }
            buffer = bigger
            limit = limit - pos
            pos = 0
        } else if (pos > 0) {
            let remaining = limit - pos
            for (i in 0..remaining) {
                buffer[i] = buffer[pos + i]
            }
            pos = 0
            limit = remaining
        }
        while (limit < n && !eof) {
            let tmp = Array<Byte>(buffer.size - limit, repeat: 0)
            let k = input.read(tmp)
            if (k <= 0) {
                eof = true
                break
            }
            for (i in 0..k) {
                buffer[limit + i] = tmp[i]
            }
            limit += k
        }
        limit >= n
    }

    func peekAt(offset: Int64): ?Byte {
        if (!ensure(offset + 1)) {
            return None
        }
        Some(buffer[pos + offset])
    }

    func readByte(): ?Byte {
        if (!ensure(1)) {
            return None
        }
        let b = buffer[pos]
        pos += 1
        Some(b)
    }

    public func read(target: Array<Byte>): Int64 {
        if (target.size == 0) {
            return 0
        }
        if (!ensure(1)) {
            return 0
        }
        let available = limit - pos
        let take = if (available < target.size) {
            available
        } else {
            target.size
        }
        for (i in 0..take) {
            target[i] = buffer[pos + i]
        }
        pos += take
        take
    }

    /** 读一行（去 CRLF）；超过 `maxLen` 抛 `MailLimitException(Header)`。 */
    func readLine(maxLen: Int64): ?Array<Byte> {
        let out = ArrayList<Byte>()
        while (true) {
            let b = readByte()
            if (let Some(value) <- b) {
                if (value == b'\n') {
                    if (out.size > 0 && out[out.size - 1] == b'\r') {
                        out.remove(out.size - 1 .. out.size)
                    }
                    return Some(out.toArray())
                }
                out.add(value)
                if (out.size > maxLen) {
                    throw MailLimitException(LimitKind.Header, maxLen, out.size)
                }
            } else {
                if (out.size == 0) {
                    return None
                }
                return Some(out.toArray())
            }
        }
        return None
    }
}

/**
 * 单个 part 的正文流：读到下一个 `CRLF + "--" + boundary` 为止。
 *
 * 行尾的 CRLF 属于边界而不是正文，因此最后一个换行要**延迟输出**：
 * 只有确认下一行不是边界时才把它吐出去。
 */
class PartStream <: InputStream {
    private let source: ByteSource
    private let boundary: Array<Byte>
    private var atLineStart = true
    private var done = false
    private var pending = ArrayList<Byte>()
    var closing = false
    var sawBoundary = false

    init(source: ByteSource, boundary: String) {
        this.source = source
        this.boundary = boundary.toArray()
    }

    public func read(target: Array<Byte>): Int64 {
        if (target.size == 0) {
            return 0
        }
        var out = 0
        while (out < target.size && !done) {
            if (atLineStart && atBoundary()) {
                consumeBoundary()
                done = true
                pending = ArrayList<Byte>()
                break
            }
            let b = source.readByte()
            if (b.isNone()) {
                flushPending(target, out)
                done = true
                break
            }
            let value = b.getOrThrow()
            if (value == b'\r') {
                pending.add(value)
                continue
            }
            if (value == b'\n') {
                pending.add(value)
                atLineStart = true
                continue
            }
            out += flushPending(target, out)
            atLineStart = false
            if (out < target.size) {
                target[out] = value
                out += 1
            } else {
                // 目标已满：把该字节留在 pending 里下次输出
                pending.add(value)
                break
            }
        }
        if (out == 0 && done && pending.size > 0) {
            out += flushPending(target, out)
        }
        out
    }

    private func flushPending(target: Array<Byte>, out: Int64): Int64 {
        var written = 0
        var i = 0
        while (i < pending.size && out + written < target.size) {
            target[out + written] = pending[i]
            written += 1
            i += 1
        }
        if (i >= pending.size) {
            pending = ArrayList<Byte>()
        } else {
            let rest = ArrayList<Byte>()
            while (i < pending.size) {
                rest.add(pending[i])
                i += 1
            }
            pending = rest
        }
        written
    }

    private func atBoundary(): Bool {
        if (let Some(first) <- source.peekAt(0)) {
            if (first != b'-') {
                return false
            }
        } else {
            return false
        }
        if (!source.ensure(2 + boundary.size)) {
            return false
        }
        if (source.peekAt(1) != Some(b'-')) {
            return false
        }
        for (i in 0..boundary.size) {
            if (source.peekAt(2 + i) != Some(boundary[i])) {
                return false
            }
        }
        // boundary 后面必须是行尾、"--" 或空白；否则只是前缀相同的另一个 boundary
        if (let Some(next) <- source.peekAt(2 + boundary.size)) {
            next == b'\r' || next == b'\n' || next == b'-' || next == b' ' || next == b'\t'
        } else {
            true
        }
    }

    private func consumeBoundary(): Unit {
        sawBoundary = true
        // "--" + boundary
        for (_ in 0..(2 + boundary.size)) {
            source.readByte()
        }
        // 可选的后缀 "--" 表示结束
        if (source.peekAt(0) == Some(b'-') && source.peekAt(1) == Some(b'-')) {
            source.readByte()
            source.readByte()
            closing = true
        }
        // 吃掉本行剩余（允许尾随空白）
        while (true) {
            let b = source.readByte()
            if (b.isNone() || b.getOrThrow() == b'\n') {
                break
            }
        }
    }
}

/** multipart 结构游标：跳过 preamble，逐个交出 part 流。 */
class MultipartScanner {
    private let source: ByteSource
    private let boundary: String
    var closed = false
    var preamble: ?String = None

    init(source: ByteSource, boundary: String) {
        this.source = source
        this.boundary = boundary
    }

    /** 读到第一个 `--boundary` 行；`--boundary--` 表示空 multipart。 */
    func skipToFirstBoundary(): Unit {
        let preambleLines = ArrayList<String>()
        while (true) {
            let line = source.readLine(8192)
            if (line.isNone()) {
                closed = true
                preamble = Some(joinLines(preambleLines.toArray()))
                return
            }
            let text = String.fromUtf8(line.getOrThrow())
            if (text == "--${boundary}") {
                preamble = if (preambleLines.size == 0) {
                    None<String>
                } else {
                    Some(joinLines(preambleLines.toArray()))
                }
                return
            }
            if (text == "--${boundary}--") {
                closed = true
                preamble = if (preambleLines.size == 0) {
                    None<String>
                } else {
                    Some(joinLines(preambleLines.toArray()))
                }
                return
            }
            preambleLines.add(text)
        }
    }

    /** 下一个 part 的字节流；调用方解析完后必须把流读空，再看 [PartStream.closing]。 */
    func nextPart(): PartStream {
        PartStream(source, boundary)
    }
}

func joinLines(lines: Array<String>): String {
    var out = ""
    for (item in lines) {
        out = out + item + "\n"
    }
    out
}
