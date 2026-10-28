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
import std.fs.{File, OpenMode}
import std.io.InputStream
import cangjie_tpc::charset4cj.charset.Charsets
import fountain::f_email.model.*

/** `walk` 在回调里表达的意图。 */
public enum MimeAction <: ToString {
    | Continue
    /** 跳过当前 part 的正文与子树，但仍回调 `onPartEnd`。 */
    | SkipPart
    /** 终止整个解析。 */
    | Stop

    public func toString(): String {
        match (this) {
            case Continue => "Continue"
            case SkipPart => "SkipPart"
            case Stop => "Stop"
        }
    }
}

/** 流式访问器。`path` 形如 `1.2`，根 part 为空串。 */
public interface MimeVisitor {
    func onPartStart(path: String, headers: HeaderMap): MimeAction
    /** 已做 CTE 解码、**未做字符集解码**的正文块。 */
    func onBodyData(path: String, data: Array<Byte>): MimeAction
    func onPartEnd(path: String): MimeAction
}

private class StopWalk <: Exception {
    init() {
        super("walk stopped")
    }
}

/**
 * MIME 解析器。
 *
 * 边界用字节级滚动窗口扫描（见 [PartStream]），叶子正文按 CTE 流式解码：
 * 小的进内存、大的落临时文件。`multipart` 递归，`message/rfc822` 解析为 `Embedded`。
 */
public class MimeParser {
    public static func parse(
        input: InputStream,
        options!: MimeParseOptions = MimeParseOptions()
    ): MailMessage {
        let state = ParseState(options)
        MailMessage(parseEntity(input, options, state, 0, "", false))
    }

    /**
     * 不建树的分块回调。
     *
     * 与 `parse` 共用同一套解析结果（因此 `SkipPart` 的语义是"不再回调"而不是"不再读取"），
     * 调用方关心的正文块仍然只按块交付，不会出现整封邮件字符串。
     */
    public static func walk(
        input: InputStream,
        visitor: MimeVisitor,
        options!: MimeParseOptions = MimeParseOptions()
    ): Unit {
        let message = parse(input, options: options)
        try {
            replay(message.root, "", visitor)
        } catch (_: StopWalk) {
            // 正常终止
        }
    }

    // ---------- 解析 ----------

    private static func parseEntity(
        input: InputStream,
        options: MimeParseOptions,
        state: ParseState,
        depth: Int64,
        path: String,
        defaultToRfc822: Bool
    ): MimePart {
        if (depth > options.maxDepth) {
            throw MailLimitException(LimitKind.Depth, options.maxDepth, depth)
        }
        state.parts += 1
        if (state.parts > options.maxParts) {
            throw MailLimitException(LimitKind.Parts, options.maxParts, state.parts)
        }
        let source = ByteSource(input)
        let headers = readHeaders(source, options)
        let part = MimePart(headers: headers)
        // multipart/digest 的子 part 缺 Content-Type 时默认 message/rfc822（RFC 2046）
        if (defaultToRfc822 && !headers.contains("Content-Type")) {
            let inner = parseEntity(source, options, state, depth + 1, path, false)
            part.body = PartBody.Embedded(MailMessage(inner))
            return part
        }
        let contentType = part.contentType

        if (contentType.isMultipart()) {
            let boundary = contentType.boundary()
            if (boundary.isNone() || !validBoundary(boundary.getOrThrow())) {
                // 非法 boundary：按普通正文处理，不猜
                part.body = readLeaf(source, part, options, contentType)
                return part
            }
            let scanner = MultipartScanner(source, boundary.getOrThrow())
            let isDigest = contentType.subtype == "digest"
            scanner.skipToFirstBoundary()
            let children = ArrayList<MimePart>()
            var index = 0
            while (!scanner.closed) {
                let stream = scanner.nextPart()
                let childPath = if (path.size == 0) {
                    "${index + 1}"
                } else {
                    "${path}.${index + 1}"
                }
                children.add(parseEntity(stream, options, state, depth + 1, childPath, isDigest))
                drain(stream)
                if (options.strict && !stream.sawBoundary) {
                    throw MimeException("multipart 缺少结束 boundary：${path}")
                }
                if (stream.closing || !stream.sawBoundary) {
                    // 没有结束 boundary：宽松模式把剩余字节当最后一个 part
                    scanner.closed = true
                }
                index += 1
            }
            part.body = PartBody.Parts(
                Multipart(
                    boundary.getOrThrow(),
                    parts: children.toArray(),
                    preamble: scanner.preamble
                )
            )
            return part
        }

        if (contentType.mediaType == "message/rfc822") {
            let inner = parseEntity(source, options, state, depth + 1, path, false)
            part.body = PartBody.Embedded(MailMessage(inner))
            return part
        }

        part.body = readLeaf(source, part, options, contentType)
        part
    }

    private static func readLeaf(
        source: InputStream,
        part: MimePart,
        options: MimeParseOptions,
        contentType: ContentType
    ): PartBody {
        let encoding = TransferEncoding.parse(part.headers.get("Content-Transfer-Encoding"))
        let decodedStream = TransferDecoder.stream(source, encoding, strict: options.strict)
        let decoded = readAll(decodedStream, options.maxBodyBytes)
        let charsetName = contentType.charsetName()
        if (contentType.isText() && decoded.size <= options.inlineTextLimit) {
            let text = CharsetResolver.decode(
                decoded,
                charsetName,
                options: CharsetOptions(strict: options.strict),
                defaultCharset: options.defaultCharset
            )
            part.markCharset(Some(text.charset), text.lossy)
            return PartBody.Text(text.text)
        }
        if (decoded.size > options.spoolThreshold) {
            return PartBody.Data(spoolBytes(decoded, options))
        }
        PartBody.Data(MemoryBodySource(decoded))
    }

    private static func spoolBytes(bytes: Array<Byte>, options: MimeParseOptions): BodySource {
        let path = Spool.createFile(spoolDir: options.spoolDir)
        let file = File(path, OpenMode.Write)
        try {
            file.write(bytes)
        } finally {
            file.close()
        }
        FileBodySource(path, owned: true)
    }

    private static func readHeaders(source: ByteSource, options: MimeParseOptions): HeaderMap {
        let headers = HeaderMap()
        var total: Int64 = 0
        var name = ""
        var value = ""
        var hasPending = false
        while (true) {
            let line = source.readLine(options.maxHeaderLine)
            if (line.isNone()) {
                break
            }
            let bytes = line.getOrThrow()
            if (bytes.size == 0) {
                break
            }
            total += bytes.size
            if (total > options.maxHeaderBytes) {
                throw MailLimitException(LimitKind.Header, options.maxHeaderBytes, total)
            }
            if (bytes[0] == b' ' || bytes[0] == b'\t') {
                if (!hasPending) {
                    throw MimeException("头部以空白开头（缺少字段名）")
                }
                value = value + " " + bytesToString(bytes).trimAscii()
                continue
            }
            if (hasPending) {
                headers.add(name, value)
            }
            let text = bytesToString(bytes)
            let colon = text.indexOf(":") ?? -1
            if (colon < 0) {
                throw MimeException("头部缺少冒号：${text}")
            }
            name = text[0..colon].trimAscii()
            value = text[(colon + 1)..].trimAscii()
            hasPending = true
        }
        if (hasPending) {
            headers.add(name, value)
        }
        headers
    }

    private static func validBoundary(boundary: String): Bool {
        let size = boundary.toArray().size
        size >= 1 && size <= 70
    }

    private static func readAll(input: InputStream, maxBytes: Int64): Array<Byte> {
        let out = ArrayList<Byte>()
        let buffer = Array<Byte>(65536, repeat: 0)
        while (true) {
            let n = input.read(buffer)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.add(buffer[i])
            }
            if (maxBytes > 0 && out.size > maxBytes) {
                throw MailLimitException(LimitKind.Body, maxBytes, out.size)
            }
        }
        out.toArray()
    }

    private static func drain(input: InputStream): Unit {
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = input.read(buffer)
            if (n <= 0) {
                break
            }
        }
    }

    static func bytesToString(bytes: Array<Byte>): String {
        try {
            String.fromUtf8(bytes)
        } catch (_: Exception) {
            let runes = Array<Rune>(bytes.size, repeat: r'\0')
            for (i in 0..bytes.size) {
                runes[i] = Rune(UInt32(bytes[i]))
            }
            String(runes)
        }
    }

    // ---------- walk ----------

    private static func replay(part: MimePart, path: String, visitor: MimeVisitor): Unit {
        let action = visitor.onPartStart(path, part.headers)
        if (action.toString() == "Stop") {
            throw StopWalk()
        }
        if (action.toString() != "SkipPart") {
            match (part.body) {
                case PartBody.Text(content) =>
                    let bytes = CharsetResolver.encode(content, part.contentType.charset() ?? Charsets.UTF8)
                    chunked(path, bytes, visitor)
                case PartBody.Data(source) =>
                    let input = source.open()
                    let buffer = Array<Byte>(65536, repeat: 0)
                    while (true) {
                        let n = input.read(buffer)
                        if (n <= 0) {
                            break
                        }
                        if (visitor.onBodyData(path, buffer[0..n]).toString() == "Stop") {
                            throw StopWalk()
                        }
                    }
                case PartBody.Parts(multipart) =>
                    var index = 0
                    for (child in multipart.parts) {
                        let childPath = if (path.size == 0) {
                            "${index + 1}"
                        } else {
                            "${path}.${index + 1}"
                        }
                        replay(child, childPath, visitor)
                        index += 1
                    }
                case PartBody.Embedded(message) => replay(message.root, path, visitor)
                case PartBody.Empty => ()
            }
        }
        if (visitor.onPartEnd(path).toString() == "Stop") {
            throw StopWalk()
        }
    }

    private static func chunked(path: String, bytes: Array<Byte>, visitor: MimeVisitor): Unit {
        var offset = 0
        while (offset < bytes.size) {
            let end = if (offset + 65536 < bytes.size) {
                offset + 65536
            } else {
                bytes.size
            }
            if (visitor.onBodyData(path, bytes[offset..end]).toString() == "Stop") {
                throw StopWalk()
            }
            offset = end
        }
    }
}

private class ParseState {
    var parts: Int64 = 0

    init(options: MimeParseOptions) {
        // options 目前不需要缓存；保留构造参数便于以后扩展
        if (options.maxParts <= 0) {
            throw MimeException("maxParts 必须为正数")
        }
    }
}
