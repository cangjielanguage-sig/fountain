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
import fountain::f_random.RandomString

/**
 * 一封邮件：根 [MimePart] 的薄包装。
 *
 * `headers` 与 `root.headers` 是**同一个对象**。解析完成后不要直接改 headers——
 * 要改就用 builder 重建，否则 `contentType` / `disposition` 缓存与原文会不一致。
 */
public class MailMessage {
    public let root: MimePart

    public init(root: MimePart) {
        this.root = root
    }

    public init(headers!: HeaderMap = HeaderMap(), body!: PartBody = PartBody.Empty) {
        this.root = MimePart(headers: headers, body: body)
    }

    public static func builder(): MailMessageBuilder {
        MailMessageBuilder()
    }

    public prop headers: HeaderMap {
        get() {
            root.headers
        }
    }

    public func from(): ?EmailAddress {
        if (let Some(raw) <- headers.get("From")) {
            let list = AddressList.parse(raw)
            if (!list.isEmpty()) {
                return Some(list.toArray()[0])
            }
        }
        None<EmailAddress>
    }

    public func to(): AddressList {
        addresses("To")
    }

    public func cc(): AddressList {
        addresses("Cc")
    }

    public func bcc(): AddressList {
        addresses("Bcc")
    }

    public func subject(): ?String {
        if (let Some(raw) <- headers.get("Subject")) {
            return Some(EncodedWord.decode(raw))
        }
        None<String>
    }

    public func date(): ?MailDate {
        if (let Some(raw) <- headers.get("Date")) {
            return Some(MailDate.parse(raw))
        }
        None<MailDate>
    }

    public func messageId(): ?String {
        headers.get("Message-ID")
    }

    public func contentType(): ContentType {
        root.contentType
    }

    /**
     * 取纯文本正文。
     *
     * `multipart/alternative` 取第一个 `text/plain`；`multipart/mixed` 在非附件 part 里递归找；
     * 找不到返回 `None`——**不会**拿 HTML 顶替。
     */
    public func text(): ?String {
        findBody(root, false)
    }

    /** 取 HTML 正文；找不到返回 `None`。 */
    public func html(): ?String {
        findBody(root, true)
    }

    public func attachments(): Array<MimePart> {
        let out = ArrayList<MimePart>()
        if (!root.isAttachment()) {
            root.collectAttachments(out)
        }
        out.toArray()
    }

    private func addresses(name: String): AddressList {
        if (let Some(raw) <- headers.get(name)) {
            return AddressList.parse(raw)
        }
        AddressList()
    }

    private static func findBody(part: MimePart, wantHtml: Bool): ?String {
        if (part.isAttachment()) {
            return None<String>
        }
        match (part.body) {
            case PartBody.Text(_) =>
                if (typeMatches(part.contentType, wantHtml)) {
                    return part.text()
                }
                None<String>
            case PartBody.Data(_) =>
                if (typeMatches(part.contentType, wantHtml)) {
                    return part.text()
                }
                None<String>
            case PartBody.Parts(multipart) =>
                // 先在同一层找直接匹配的叶子（alternative 的语义），再递归
                for (child in multipart.parts) {
                    if (!child.isAttachment() && typeMatches(child.contentType, wantHtml)) {
                        if (let Some(found) <- findBody(child, wantHtml)) {
                            return Some(found)
                        }
                    }
                }
                for (child in multipart.parts) {
                    if (!child.isAttachment()) {
                        if (let Some(found) <- findBody(child, wantHtml)) {
                            return Some(found)
                        }
                    }
                }
                None<String>
            case PartBody.Embedded(message) => findBody(message.root, wantHtml)
            case PartBody.Empty => None<String>
        }
    }

    private static func typeMatches(contentType: ContentType, wantHtml: Bool): Bool {
        if (!contentType.isText()) {
            return false
        }
        if (wantHtml) {
            contentType.subtype == "html"
        } else {
            contentType.subtype == "plain"
        }
    }
}

/**
 * 消息构造器。
 *
 * `text` + `html` 同时存在时自动生成 `multipart/alternative`；有附件时外层再包 `multipart/mixed`。
 */
public class MailMessageBuilder {
    private let headerMap = HeaderMap()
    private var textBody: ?String = None
    private var textCharset: Charset = Charsets.UTF8
    private var htmlBody: ?String = None
    private var htmlCharset: Charset = Charsets.UTF8
    private let attachmentList = ArrayList<(String, String, BodySource)>()

    public init() {}

    public func from(address: String): This {
        headerMap.set("From", EmailAddress.parse(address).toString())
        this
    }

    public func to(address: String): This {
        appendAddress("To", address)
        this
    }

    public func cc(address: String): This {
        appendAddress("Cc", address)
        this
    }

    public func bcc(address: String): This {
        appendAddress("Bcc", address)
        this
    }

    public func subject(text: String): This {
        headerMap.set("Subject", text)
        this
    }

    public func date(date: MailDate): This {
        headerMap.set("Date", date.toString())
        this
    }

    public func header(name: String, value: String): This {
        headerMap.set(name, value)
        this
    }

    public func text(content: String, charset!: Charset = Charsets.UTF8): This {
        this.textBody = Some(content)
        this.textCharset = charset
        this
    }

    public func html(content: String, charset!: Charset = Charsets.UTF8): This {
        this.htmlBody = Some(content)
        this.htmlCharset = charset
        this
    }

    /** 附件名只用于 `Content-Disposition`，不参与任何临时文件路径。 */
    public func attach(
        filename: String,
        source: BodySource,
        mediaType!: String = "application/octet-stream"
    ): This {
        attachmentList.add((filename, mediaType, source))
        this
    }

    public func build(): MailMessage {
        let leaves = ArrayList<MimePart>()
        if (let Some(content) <- textBody) {
            leaves.add(textPart(content, "plain", textCharset))
        }
        if (let Some(content) <- htmlBody) {
            leaves.add(textPart(content, "html", htmlCharset))
        }

        var body = PartBody.Empty
        var currentType = ""
        if (leaves.size == 1) {
            body = leaves[0].body
            currentType = leaves[0].headers.get("Content-Type") ?? "text/plain; charset=utf-8"
        } else if (leaves.size > 1) {
            let boundary = newBoundary()
            currentType = "multipart/alternative; boundary=\"${boundary}\""
            body = PartBody.Parts(Multipart(boundary, parts: leaves.toArray()))
        }

        if (attachmentList.size > 0) {
            let boundary = newBoundary()
            let mixedParts = ArrayList<MimePart>()
            if (currentType.size > 0) {
                let mainHeaders = HeaderMap()
                mainHeaders.set("Content-Type", currentType)
                mixedParts.add(MimePart(headers: mainHeaders, body: body))
            }
            for ((filename, mediaType, source) in attachmentList) {
                let params = MimeParameters()
                params.add("filename", filename)
                let headers = HeaderMap()
                headers.set("Content-Type", "${mediaType};${params.toHeaderValue()}")
                headers.set("Content-Disposition", "attachment;${params.toHeaderValue()}")
                mixedParts.add(MimePart(headers: headers, body: PartBody.Data(source)))
            }
            currentType = "multipart/mixed; boundary=\"${boundary}\""
            body = PartBody.Parts(Multipart(boundary, parts: mixedParts.toArray()))
        }

        if (currentType.size > 0) {
            headerMap.set("Content-Type", currentType)
        }
        if (!headerMap.contains("MIME-Version")) {
            headerMap.set("MIME-Version", "1.0")
        }
        MailMessage(MimePart(headers: headerMap, body: body))
    }

    private func appendAddress(name: String, address: String): Unit {
        let parsed = EmailAddress.parse(address).toString()
        if (let Some(existing) <- headerMap.get(name)) {
            headerMap.set(name, "${existing}, ${parsed}")
        } else {
            headerMap.set(name, parsed)
        }
    }

    private func textPart(content: String, subtype: String, charset: Charset): MimePart {
        let headers = HeaderMap()
        headers.set("Content-Type", "text/${subtype}; charset=${charset.toString().toAsciiLower()}")
        MimePart(headers: headers, body: PartBody.Text(content))
    }

    /** 流式生成无法预读全文，32 位随机 + 固定前缀的碰撞概率可以忽略。 */
    private func newBoundary(): String {
        "=_fountain_${RandomString().randomLowerHex(32)}"
    }

}
