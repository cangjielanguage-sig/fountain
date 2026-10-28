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
import std.io.InputStream
import cangjie_tpc::charset4cj.charset.encoding.Charset

/** MIME part 的正文形态。 */
public enum PartBody {
    /** 小文本，已按 charset 解码。 */
    | Text(String)
    /** 大文本或二进制，CTE 已解码。 */
    | Data(BodySource)
    /** multipart 类型。 */
    | Parts(Multipart)
    /** `message/rfc822`。 */
    | Embedded(MailMessage)
    | Empty
}

/** multipart 容器。 */
public class Multipart {
    public let boundary: String
    public let parts: Array<MimePart>
    /** 第一个 boundary 之前的内容，保留但不解释。 */
    public let preamble: ?String
    /** 结束 boundary 之后的内容，保留但不解释。 */
    public let epilogue: ?String

    public init(
        boundary: String,
        parts!: Array<MimePart> = [],
        preamble!: ?String = None,
        epilogue!: ?String = None
    ) {
        this.boundary = boundary
        this.parts = parts
        this.preamble = preamble
        this.epilogue = epilogue
    }
}

/**
 * 一个 MIME part。
 *
 * `headers` 与 `MailMessage.headers` 是同一个对象；`contentType` / `disposition` 是解析时
 * 建立的缓存视图。**解析完成后不要再改 headers**——要改就用 builder 重建，
 * 否则缓存与原文会不一致。
 */
public class MimePart {
    public let headers: HeaderMap
    public var body: PartBody
    var contentTypeCache: ?ContentType = None
    var dispositionCache: ?ContentDisposition = None
    var charsetUsedValue: ?Charset = None
    var charsetLossyValue = false

    public init(headers!: HeaderMap = HeaderMap(), body!: PartBody = PartBody.Empty) {
        this.headers = headers
        this.body = body
    }

    public prop contentType: ContentType {
        get() {
            match (contentTypeCache) {
                case Some(value) => value
                case None =>
                    let parsed = if (let Some(raw) <- headers.get("Content-Type")) {
                        ContentType.parse(raw)
                    } else {
                        ContentType.defaultText()
                    }
                    contentTypeCache = Some(parsed)
                    parsed
            }
        }
    }

    public prop disposition: ?ContentDisposition {
        get() {
            match (dispositionCache) {
                case Some(value) => Some(value)
                case None =>
                    if (let Some(raw) <- headers.get("Content-Disposition")) {
                        let parsed = ContentDisposition.parse(raw)
                        dispositionCache = Some(parsed)
                        Some(parsed)
                    } else {
                        None<ContentDisposition>
                    }
            }
        }
    }

    /** 实际用于解码正文的字符集。 */
    public prop charsetUsed: ?Charset {
        get() {
            charsetUsedValue
        }
    }

    public prop charsetLossy: Bool {
        get() {
            charsetLossyValue
        }
    }

    /**
     * 叶子正文的文本。
     *
     * `Text` 直接返回；`Data` 会按需物化（一次性来源会被消费掉，第二次调用会抛异常）。
     */
    public func text(): ?String {
        match (body) {
            case PartBody.Text(value) => Some(value)
            case PartBody.Data(source) =>
                let bytes = readAll(source.open())
                let declared = contentType.charsetName()
                let decoded = CharsetResolver.decode(bytes, declared)
                charsetUsedValue = Some(decoded.charset)
                charsetLossyValue = decoded.lossy
                Some(decoded.text)
            case _ => None<String>
        }
    }

    /** 叶子正文的来源。 */
    public func source(): ?BodySource {
        match (body) {
            case PartBody.Data(source) => Some(source)
            case _ => None<BodySource>
        }
    }

    public func children(): Array<MimePart> {
        match (body) {
            case PartBody.Parts(multipart) => multipart.parts
            case PartBody.Embedded(message) => [message.root]
            case _ => []
        }
    }

    public func isMultipart(): Bool {
        match (body) {
            case PartBody.Parts(_) => true
            case _ => false
        }
    }

    /**
     * 是否算附件。
     *
     * `Content-Disposition: attachment` 直接算；带 `filename` 的非文本 part 也算；
     * `inline` 图片不算附件（但能通过 [children] 遍历到）。
     */
    public func isAttachment(): Bool {
        if (let Some(disp) <- disposition) {
            if (disp.isAttachment) {
                return true
            }
            if (disp.isInline) {
                return false
            }
        }
        if (!isMultipart() && !contentType.isText()) {
            return contentType.name().isSome()
        }
        false
    }

    /** 递归收集附件。 */
    public func collectAttachments(out: ArrayList<MimePart>): Unit {
        for (child in children()) {
            if (child.isAttachment()) {
                out.add(child)
            } else {
                child.collectAttachments(out)
            }
        }
    }

    internal static func readAll(input: InputStream): Array<Byte> {
        let out = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = input.read(buffer)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.add(buffer[i])
            }
        }
        out.toArray()
    }
}
