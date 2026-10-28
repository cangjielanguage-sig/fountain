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
import std.io.{InputStream, OutputStream}
import cangjie_tpc::charset4cj.charset.Charsets
import fountain::f_email.model.*

/**
 * MIME 生成器：流式写出，`bytesWritten()` 供 SMTP 的 `SIZE=` 使用。
 *
 * 顺序不能反：先决定编码并补上 `Content-Transfer-Encoding`，再写头部，最后写正文。
 * 反过来写会在头部已经落盘后才发现需要换编码。
 *
 * `Bcc` **原样写出**——这是通用序列化器（保存草稿要用）；发送路径的剥离由 `SmtpClient` 负责。
 */
public class MimeWriter {
    private let output: OutputStream
    private let options: MimeWriteOptions
    private var written: Int64 = 0

    public init(output: OutputStream, options!: MimeWriteOptions = MimeWriteOptions()) {
        this.output = output
        this.options = options
    }

    public func write(message: MailMessage): Unit {
        writePart(message.root)
    }

    public func bytesWritten(): Int64 {
        written
    }

    public func flush(): Unit {
        // 底层是裸 socket / 内存流，无需额外 flush；保留接口与设计一致。
    }

    // ---------- part ----------

    private func writePart(part: MimePart): Unit {
        match (part.body) {
            case PartBody.Parts(multipart) =>
                writeHeaders(part.headers)
                writeMultipart(multipart)
            case PartBody.Embedded(message) =>
                writeHeaders(part.headers)
                writePart(message.root)
            case PartBody.Text(content) =>
                let bytes = CharsetResolver.encode(content, part.contentType.charset() ?? Charsets.UTF8)
                writeLeaf(part, bytes, part.contentType.isText())
            case PartBody.Data(source) =>
                writeLeafStream(part, source, part.contentType.isText())
            case PartBody.Empty =>
                writeHeaders(part.headers)
        }
    }

    private func writeMultipart(multipart: Multipart): Unit {
        for (child in multipart.parts) {
            emit("--${multipart.boundary}\r\n".toArray())
            writePart(child)
            emit("\r\n".toArray())
        }
        emit("--${multipart.boundary}--\r\n".toArray())
    }

    private func writeLeaf(part: MimePart, bytes: Array<Byte>, isText: Bool): Unit {
        let encoding = chooseEncoding(bytes, isText)
        writeHeaders(withTransferEncoding(part.headers, encoding))
        writeEncoded(bytes, encoding)
    }

    private func writeLeafStream(part: MimePart, source: BodySource, isText: Bool): Unit {
        let input = source.open()
        let sampleBuffer = Array<Byte>(65536, repeat: 0)
        let sampleSize = readUpTo(input, sampleBuffer)
        let sample = if (sampleSize == sampleBuffer.size) {
            sampleBuffer
        } else {
            sampleBuffer[0..sampleSize]
        }
        let encoding = chooseEncoding(sample, isText)
        writeHeaders(withTransferEncoding(part.headers, encoding))
        let encoded = openEncoder(encoding)
        encoded.write(sample)
        let rest = Array<Byte>(65536, repeat: 0)
        while (true) {
            let n = input.read(rest)
            if (n <= 0) {
                break
            }
            encoded.write(rest[0..n])
        }
        closeEncoder(encoded, encoding)
    }

    private func readUpTo(input: InputStream, buffer: Array<Byte>): Int64 {
        var total = 0
        while (total < buffer.size) {
            let n = input.read(buffer[total..buffer.size])
            if (n <= 0) {
                break
            }
            total += n
        }
        total
    }

    // ---------- 编码选择 ----------

    private func chooseEncoding(sample: Array<Byte>, isText: Bool): TransferEncoding {
        if (let Some(forced) <- options.forceEncoding) {
            if (forced.toString() == "7bit" && !isSevenBitSafe(sample)) {
                throw MimeException("forceEncoding=7bit 但正文含 8 位字节或单行超过 998 octets")
            }
            if (forced.toString() == "8bit" && !isText) {
                throw MimeException("forceEncoding=8bit 只能用于文本正文")
            }
            return forced
        }
        if (isSevenBitSafe(sample)) {
            return TransferEncoding.SevenBit
        }
        if (isText) {
            if (options.allow8Bit) {
                return TransferEncoding.EightBit
            }
            var nonAscii = 0
            for (b in sample) {
                if (b > 126) {
                    nonAscii += 1
                }
            }
            if (sample.size == 0 || nonAscii * 5 < sample.size) {
                return TransferEncoding.QuotedPrintable
            }
        }
        TransferEncoding.Base64
    }

    private func isSevenBitSafe(bytes: Array<Byte>): Bool {
        var lineLength = 0
        for (b in bytes) {
            if (b > 126 || (b < 32 && b != b'\r' && b != b'\n' && b != b'\t')) {
                return false
            }
            if (b == b'\n') {
                lineLength = 0
            } else {
                lineLength += 1
                if (lineLength > 998) {
                    return false
                }
            }
        }
        true
    }

    private func withTransferEncoding(headers: HeaderMap, encoding: TransferEncoding): HeaderMap {
        if (!headers.contains("Content-Transfer-Encoding")) {
            headers.set("Content-Transfer-Encoding", encoding.toString())
        }
        headers
    }

    private func writeEncoded(bytes: Array<Byte>, encoding: TransferEncoding): Unit {
        match (encoding) {
            case TransferEncoding.Base64 =>
                emitRaw(Base64Codec.encode(bytes, lineLength: options.bodyLineLength).toArray())
            case TransferEncoding.QuotedPrintable =>
                emitRaw(QuotedPrintable.encode(bytes, lineLength: options.bodyLineLength).toArray())
            case _ =>
                emitRaw(normalizeCrlf(bytes))
        }
    }

    private func openEncoder(encoding: TransferEncoding): OutputStream {
        match (encoding) {
            case TransferEncoding.Base64 => Base64Codec.encoder(CountingOutput(this), lineLength: options.bodyLineLength)
            case TransferEncoding.QuotedPrintable => QuotedPrintable.encoder(CountingOutput(this), lineLength: options.bodyLineLength)
            case _ => CrlfNormalizingOutput(CountingOutput(this))
        }
    }

    private func closeEncoder(stream: OutputStream, encoding: TransferEncoding): Unit {
        match (encoding) {
            case TransferEncoding.Base64 =>
                if (let Some(encoder) <- (stream as Base64Encoder)) {
                    encoder.finish()
                }
            case TransferEncoding.QuotedPrintable =>
                if (let Some(encoder) <- (stream as QuotedPrintableEncoder)) {
                    encoder.finish()
                }
            case _ => ()
        }
    }

    private func normalizeCrlf(bytes: Array<Byte>): Array<Byte> {
        let out = ArrayList<Byte>()
        var pendingCr = false
        for (b in bytes) {
            if (pendingCr) {
                pendingCr = false
                out.add(b'\r')
                out.add(b'\n')
                if (b == b'\n') {
                    continue
                }
            }
            if (b == b'\r') {
                pendingCr = true
                continue
            }
            if (b == b'\n') {
                out.add(b'\r')
                out.add(b'\n')
                continue
            }
            out.add(b)
        }
        if (pendingCr) {
            out.add(b'\r')
            out.add(b'\n')
        }
        out.toArray()
    }

    // ---------- 头部 ----------

    private func writeHeaders(headers: HeaderMap): Unit {
        for ((name, value) in headers.entries()) {
            var text = value
            if (!options.utf8Headers && EncodedWord.needsEncoding(text) &&
                !name.toAsciiLower().startsWith("content-")) {
                text = EncodedWord.encode(text)
            }
            foldHeader(name, text)
        }
        emit([b'\r', b'\n'])
    }

    private func foldHeader(name: String, value: String): Unit {
        let head = "${name}: ".toArray()
        var current = ArrayList<Byte>()
        for (b in head) {
            current.add(b)
        }
        var lastBreak: Int64 = -1
        var inQuote = false
        var escaped = false
        let bytes = value.toArray()
        var i = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (escaped) {
                current.add(b)
                escaped = false
                i += 1
                continue
            }
            if (b == b'\\' && inQuote) {
                current.add(b)
                escaped = true
                i += 1
                continue
            }
            if (b == b'"') {
                inQuote = !inQuote
            }
            // 已带显式折行（encoded-word 之间）时直接换行，不再二次折
            if (b == b'\r' && i + 1 < bytes.size && bytes[i + 1] == b'\n') {
                current.add(b'\r')
                current.add(b'\n')
                i += 2
                lastBreak = -1
                continue
            }
            current.add(b)
            if (b == b' ' && !inQuote) {
                lastBreak = current.size - 1
            }
            if (current.size > options.maxLineLength) {
                if (lastBreak <= 0) {
                    lastBreak = options.maxLineLength
                }
                let separator: Int64 = if (current[lastBreak] == b' ') {
                    1
                } else {
                    0
                }
                let before = Array<Byte>(lastBreak, repeat: 0)
                for (k in 0..lastBreak) {
                    before[k] = current[k]
                }
                let afterSize = current.size - lastBreak - separator
                let after = ArrayList<Byte>()
                after.add(b' ')
                for (k in 0..afterSize) {
                    after.add(current[lastBreak + separator + k])
                }
                let lineBytes = Array<Byte>(lastBreak + 2, repeat: 0)
                for (k in 0..lastBreak) {
                    lineBytes[k] = before[k]
                }
                lineBytes[lastBreak] = b'\r'
                lineBytes[lastBreak + 1] = b'\n'
                emit(lineBytes)
                current = after
                lastBreak = -1
                var j = current.size - 1
                while (j > 0) {
                    if (current[j] == b' ') {
                        lastBreak = j
                        break
                    }
                    j -= 1
                }
            }
            i += 1
        }
        current.add(b'\r')
        current.add(b'\n')
        emit(current.toArray())
    }

    // ---------- 输出 ----------

    private func emit(bytes: Array<Byte>): Unit {
        emitRaw(bytes)
    }

    func emitRaw(bytes: Array<Byte>): Unit {
        if (bytes.size == 0) {
            return
        }
        written += bytes.size
        if (options.maxBytes > 0 && written > options.maxBytes) {
            throw MailLimitException(LimitKind.Size, options.maxBytes, written)
        }
        output.write(bytes)
    }
}

/** 把写入计数回传给 [MimeWriter]。 */
class CountingOutput <: OutputStream {
    private let writer: MimeWriter

    init(writer: MimeWriter) {
        this.writer = writer
    }

    public func write(bytes: Array<Byte>): Unit {
        writer.emitRaw(bytes)
    }
}

/** 7bit/8bit 文本的换行归一。 */
class CrlfNormalizingOutput <: OutputStream {
    private let output: OutputStream
    private var pendingCr = false

    init(output: OutputStream) {
        this.output = output
    }

    public func write(bytes: Array<Byte>): Unit {
        let out = ArrayList<Byte>()
        for (b in bytes) {
            if (pendingCr) {
                pendingCr = false
                out.add(b'\r')
                out.add(b'\n')
                if (b == b'\n') {
                    continue
                }
            }
            if (b == b'\r') {
                pendingCr = true
                continue
            }
            if (b == b'\n') {
                out.add(b'\r')
                out.add(b'\n')
                continue
            }
            out.add(b)
        }
        output.write(out.toArray())
    }
}
