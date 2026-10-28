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
package fountain::f_email.imap

import std.collection.ArrayList
import fountain::f_email.model.{EncodedWord, MailProtocolException}

/**
 * 序号集合（`1:5,7,9:*`）。
 *
 * `*` 表示"最大序号/最大 UID"，可以出现在任一端的范围里；`3:*` 在 UID 语义下
 * 表示"从 3 到最大"而不是"3 到无穷"——由服务器解释，客户端只负责原样编码。
 */
public struct SequenceSet <: ToString {
    public let text: String

    public init(text: String) {
        if (text.size == 0) {
            throw MailProtocolException("序号集合不能为空")
        }
        this.text = text
    }

    public static func single(sequence: Int64): SequenceSet {
        SequenceSet(sequence.toString())
    }

    public static func range(from: Int64, to: Int64): SequenceSet {
        SequenceSet("${from}:${to}")
    }

    public static func all(): SequenceSet {
        SequenceSet("1:*")
    }

    public static func of(sequences: Array<Int64>): SequenceSet {
        var out = ""
        var first = true
        for (sequence in sequences) {
            if (!first) {
                out = out + ","
            }
            out = out + sequence.toString()
            first = false
        }
        SequenceSet(out)
    }

    public func toString(): String {
        text
    }
}

/** `BODY[...]` 方括号里的内容。 */
public struct BodySection <: ToString {
    public let spec: String

    public init(spec: String) {
        this.spec = spec
    }

    /** 整封邮件（`BODY[]`）。 */
    public static func entire(): BodySection {
        BodySection("")
    }

    public static func header(): BodySection {
        BodySection("HEADER")
    }

    public static func text(): BodySection {
        BodySection("TEXT")
    }

    /** `BODY[1.2]`：取某个 part。 */
    public static func part(partNumber: String): BodySection {
        BodySection(partNumber)
    }

    /** `BODY[HEADER.FIELDS (FROM TO)]`：只要这几行头。 */
    public static func headerFields(fields: Array<String>): BodySection {
        var out = "HEADER.FIELDS ("
        var first = true
        for (field in fields) {
            if (!first) {
                out = out + " "
            }
            out = out + field.toAsciiUpper()
            first = false
        }
        BodySection(out + ")")
    }

    public func toString(): String {
        spec
    }
}

/** 一个 FETCH 数据项。 */
public struct FetchItem <: ToString {
    public let text: String

    public init(text: String) {
        this.text = text
    }

    public static func flags(): FetchItem {
        FetchItem("FLAGS")
    }

    public static func uid(): FetchItem {
        FetchItem("UID")
    }

    public static func envelope(): FetchItem {
        FetchItem("ENVELOPE")
    }

    public static func bodyStructure(): FetchItem {
        FetchItem("BODYSTRUCTURE")
    }

    public static func internalDate(): FetchItem {
        FetchItem("INTERNALDATE")
    }

    public static func size(): FetchItem {
        FetchItem("RFC822.SIZE")
    }

    public static func modseq(): FetchItem {
        FetchItem("MODSEQ")
    }

    /**
     * `BODY[...]` / `BODY.PEEK[...]`。
     *
     * 默认用 `PEEK`：只读邮件不该因为取正文就把 `\Seen` 点亮——那会让"后台同步"变成
     * "把所有未读都读掉"。[peek]=false 只在调用方明确想置已读时使用。
     */
    public static func body(
        section!: BodySection = BodySection.entire(),
        peek!: Bool = true,
        partial!: ?(Int64, Int64) = None
    ): FetchItem {
        var text = if (peek) {
            "BODY.PEEK[${section}]"
        } else {
            "BODY[${section}]"
        }
        if (let Some((origin, length)) <- partial) {
            text = text + "<${origin}.${length}>"
        }
        FetchItem(text)
    }

    public func toString(): String {
        text
    }
}

/** `ENVELOPE` 里的一个地址（`("名字" NIL "mailbox" "host")`）。 */
public struct ImapAddress <: ToString {
    public let name: ?String
    public let adl: ?String
    public let mailbox: ?String
    public let host: ?String

    public init(name!: ?String = None, adl!: ?String = None, mailbox!: ?String = None, host!: ?String = None) {
        this.name = name
        this.adl = adl
        this.mailbox = mailbox
        this.host = host
    }

    /** `Name <user@host>` 形式；缺项时尽量还原，不抛异常。 */
    public func toString(): String {
        let mb = mailbox ?? ""
        let h = host ?? ""
        let addr = if (h.size > 0) {
            "${mb}@${h}"
        } else {
            mb
        }
        match (name) {
            case Some(value) => if (value.size > 0) {
                "\"${value}\" <${addr}>"
            } else {
                addr
            }
            case None => addr
        }
    }

    /** 解析响应里的地址列表（`NIL` 表示没有）。 */
    static func parseList(value: ImapValue): Array<ImapAddress> {
        let out = ArrayList<ImapAddress>()
        match (value) {
            case List(entries) =>
                // 两个形状都要接受：`((...)(...))`（正常）与 `(...)`（个别服务器）。
                // 组语法的边界是两个 NIL 元素，直接跳过即可。
                var flat = entries.size > 0
                for (entry in entries) {
                    match (entry) {
                        case List(_) => flat = false
                        case _ => ()
                    }
                }
                if (flat) {
                    if (entries.size >= 4) {
                        out.add(parseOne(entries, 0))
                    }
                } else {
                    for (entry in entries) {
                        match (entry) {
                            case List(parts) =>
                                if (parts.size >= 4) {
                                    out.add(parseOne(parts, 0))
                                }
                            case _ => ()
                        }
                    }
                }
            case _ => ()
        }
        out.toArray()
    }

    private static func parseOne(entries: Array<ImapValue>, index: Int64): ImapAddress {
        ImapAddress(
            name: stringOrNone(entries[index]),
            adl: stringOrNone(entries[index + 1]),
            mailbox: stringOrNone(entries[index + 2]),
            host: stringOrNone(entries[index + 3])
        )
    }
}

/** 解析后的 `ENVELOPE`。 */
public struct ImapEnvelope {
    public let date: ?String
    public let subject: ?String
    public let from: Array<ImapAddress>
    public let sender: Array<ImapAddress>
    public let replyTo: Array<ImapAddress>
    public let to: Array<ImapAddress>
    public let cc: Array<ImapAddress>
    public let bcc: Array<ImapAddress>
    public let inReplyTo: ?String
    public let messageId: ?String

    public init(
        date!: ?String = None,
        subject!: ?String = None,
        from!: Array<ImapAddress> = [],
        sender!: Array<ImapAddress> = [],
        replyTo!: Array<ImapAddress> = [],
        to!: Array<ImapAddress> = [],
        cc!: Array<ImapAddress> = [],
        bcc!: Array<ImapAddress> = [],
        inReplyTo!: ?String = None,
        messageId!: ?String = None
    ) {
        this.date = date
        this.subject = subject
        this.from = from
        this.sender = sender
        this.replyTo = replyTo
        this.to = to
        this.cc = cc
        this.bcc = bcc
        this.inReplyTo = inReplyTo
        this.messageId = messageId
    }

    /**
     * 从 `ENVELOPE` 的列表解析。
     *
     * 顺序固定十项：date subject from sender reply-to to cc bcc in-reply-to message-id。
     * subject 走 RFC 2047 解码（服务器常把 encoded-word 原样留在 ENVELOPE 里）；
     * date 保留原文——它是 `INTERNALDATE` 之外的"发信人声明时间"，格式由发信端决定。
     */
    public static func parse(value: ImapValue): ImapEnvelope {
        let items = value.items()
        if (items.size < 10) {
            throw MailProtocolException("ENVELOPE 少于 10 项：${items.size}")
        }
        let rawSubject = stringOrNone(items[1])
        let subject = match (rawSubject) {
            case Some(text) => Some(EncodedWord.decode(text))
            case None => None<String>
        }
        ImapEnvelope(
            date: stringOrNone(items[0]),
            subject: subject,
            from: ImapAddress.parseList(items[2]),
            sender: ImapAddress.parseList(items[3]),
            replyTo: ImapAddress.parseList(items[4]),
            to: ImapAddress.parseList(items[5]),
            cc: ImapAddress.parseList(items[6]),
            bcc: ImapAddress.parseList(items[7]),
            inReplyTo: stringOrNone(items[8]),
            messageId: stringOrNone(items[9])
        )
    }
}

/** 单 part 的 `BODYSTRUCTURE`。 */
public struct LeafBody {
    public let mediaType: String
    public let mediaSubtype: String
    public let params: Array<(String, String)>
    public let id: ?String
    public let description: ?String
    public let encoding: String
    public let size: Int64
    public let lines: ?Int64
    public let md5: ?String
    public let disposition: ?(String, Array<(String, String)>)

    public init(
        mediaType: String,
        mediaSubtype: String,
        params!: Array<(String, String)> = [],
        id!: ?String = None,
        description!: ?String = None,
        encoding!: String = "7BIT",
        size!: Int64 = 0,
        lines!: ?Int64 = None,
        md5!: ?String = None,
        disposition!: ?(String, Array<(String, String)>) = None
    ) {
        this.mediaType = mediaType
        this.mediaSubtype = mediaSubtype
        this.params = params
        this.id = id
        this.description = description
        this.encoding = encoding
        this.size = size
        this.lines = lines
        this.md5 = md5
        this.disposition = disposition
    }

    public func contentType(): String {
        "${mediaType}/${mediaSubtype}"
    }

    public func param(name: String): ?String {
        let wanted = name.toAsciiUpper()
        for ((key, value) in params) {
            if (key.toAsciiUpper() == wanted) {
                return Some(value)
            }
        }
        None<String>
    }

    public func filename(): ?String {
        match (disposition) {
            case Some(pair) =>
                let (_, params) = pair
                for ((key, value) in params) {
                    if (key.toAsciiUpper() == "FILENAME") {
                        return Some(value)
                    }
                }
                None<String>
            case None => param("NAME")
        }
    }

    public func isAttachment(): Bool {
        match (disposition) {
            case Some(pair) =>
                let (kind, _) = pair
                kind.toAsciiUpper() == "ATTACHMENT"
            case None => false
        }
    }
}

/** multipart 类型的 `BODYSTRUCTURE`。 */
public struct MultiBody {
    public let mediaSubtype: String
    public let parts: Array<BodyStructure>
    public let params: Array<(String, String)>
    public let disposition: ?(String, Array<(String, String)>)

    public init(
        mediaSubtype: String,
        parts: Array<BodyStructure>,
        params!: Array<(String, String)> = [],
        disposition!: ?(String, Array<(String, String)>) = None
    ) {
        this.mediaSubtype = mediaSubtype
        this.parts = parts
        this.params = params
        this.disposition = disposition
    }

    public func contentType(): String {
        "MULTIPART/${mediaSubtype}"
    }

    public func param(name: String): ?String {
        let wanted = name.toAsciiUpper()
        for ((key, value) in params) {
            if (key.toAsciiUpper() == wanted) {
                return Some(value)
            }
        }
        None<String>
    }
}

/** `BODYSTRUCTURE` 的两态：叶子或容器。 */
public enum BodyStructure {
    | Leaf(LeafBody)
    | Multi(MultiBody)

    public func isMultipart(): Bool {
        match (this) {
            case Multi(_) => true
            case _ => false
        }
    }

    /** 叶子 part 的数量（多部分递归统计）。 */
    public func leafCount(): Int64 {
        match (this) {
            case Leaf(_) => 1
            case Multi(body) =>
                var total: Int64 = 0
                for (part in body.parts) {
                    total += part.leafCount()
                }
                total
        }
    }

    public func contentType(): String {
        match (this) {
            case Leaf(body) => body.contentType()
            case Multi(body) => body.contentType()
        }
    }

    public static func parse(value: ImapValue): BodyStructure {
        let items = value.items()
        if (items.size == 0) {
            throw MailProtocolException("BODYSTRUCTURE 为空")
        }
        // 第一项是列表 ⇒ multipart
        match (items[0]) {
            case List(_) =>
                let parts = ArrayList<BodyStructure>()
                var index = 0
                while (index < items.size) {
                    match (items[index]) {
                        case List(_) =>
                            parts.add(parse(items[index]))
                            index += 1
                        case _ => break
                    }
                }
                let subtype = if (index < items.size) {
                    items[index].text().toAsciiUpper()
                } else {
                    "MIXED"
                }
                index += 1
                let params: Array<(String, String)> = if (index < items.size) {
                    parseParams(items[index])
                } else {
                    []
                }
                let disposition = findDisposition(items, index)
                BodyStructure.Multi(MultiBody(subtype, parts.toArray(), params: params, disposition: disposition))
            case _ =>
                let mediaType = items[0].text().toAsciiUpper()
                let subtype = if (items.size > 1) {
                    items[1].text().toAsciiUpper()
                } else {
                    ""
                }
                let params: Array<(String, String)> = if (items.size > 2) {
                    parseParams(items[2])
                } else {
                    []
                }
                let id = if (items.size > 3) {
                    stringOrNone(items[3])
                } else {
                    None<String>
                }
                let description = if (items.size > 4) {
                    stringOrNone(items[4])
                } else {
                    None<String>
                }
                let encoding = if (items.size > 5) {
                    items[5].text().toAsciiUpper()
                } else {
                    "7BIT"
                }
                let size = if (items.size > 6) {
                    items[6].number() ?? 0
                } else {
                    0
                }
                // TEXT/* 在 size 之后多一个行数，因此 md5 / disposition 各后移一位
                var lines: ?Int64 = None
                var cursor = 7
                if (mediaType == "TEXT") {
                    if (items.size > 7) {
                        lines = items[7].number()
                    }
                    cursor = 8
                }
                let md5 = if (items.size > cursor) {
                    stringOrNone(items[cursor])
                } else {
                    None<String>
                }
                BodyStructure.Leaf(
                    LeafBody(
                        mediaType,
                        subtype,
                        params: params,
                        id: id,
                        description: description,
                        encoding: encoding,
                        size: size,
                        lines: lines,
                        md5: md5,
                        disposition: findDisposition(items, cursor + 1)
                    )
                )
        }
    }
}

/** 一个 FETCH 结果（正文在内存里）。 */
public struct FetchResult {
    public let sequence: Int64
    public let uid: ?Int64
    public let flags: Array<String>
    public let internalDate: ?String
    public let size: ?Int64
    public let modseq: ?Int64
    public let envelope: ?ImapEnvelope
    public let bodyStructure: ?BodyStructure
    public let body: ?Array<Byte>
    /** 正文对应的响应键（`BODY[]` / `BODY[HEADER.FIELDS (FROM TO)]`）。 */
    public let section: ?String
    /** 部分获取时的起始偏移（响应键里的 `<0>`）。 */
    public let origin: ?Int64

    public init(
        sequence: Int64,
        uid!: ?Int64 = None,
        flags!: Array<String> = [],
        internalDate!: ?String = None,
        size!: ?Int64 = None,
        modseq!: ?Int64 = None,
        envelope!: ?ImapEnvelope = None,
        bodyStructure!: ?BodyStructure = None,
        body!: ?Array<Byte> = None,
        section!: ?String = None,
        origin!: ?Int64 = None
    ) {
        this.sequence = sequence
        this.uid = uid
        this.flags = flags
        this.internalDate = internalDate
        this.size = size
        this.modseq = modseq
        this.envelope = envelope
        this.bodyStructure = bodyStructure
        this.body = body
        this.section = section
        this.origin = origin
    }

    public func meta(): FetchMeta {
        FetchMeta(
            sequence,
            uid: uid,
            flags: flags,
            internalDate: internalDate,
            size: size,
            modseq: modseq,
            envelope: envelope,
            bodyStructure: bodyStructure,
            section: section,
            origin: origin
        )
    }
}

/** 不带正文的 FETCH 结果：流式取正文时先交元信息，再交字节块。 */
public struct FetchMeta {
    public let sequence: Int64
    public let uid: ?Int64
    public let flags: Array<String>
    public let internalDate: ?String
    public let size: ?Int64
    public let modseq: ?Int64
    public let envelope: ?ImapEnvelope
    public let bodyStructure: ?BodyStructure
    public let section: ?String
    public let origin: ?Int64

    public init(
        sequence: Int64,
        uid!: ?Int64 = None,
        flags!: Array<String> = [],
        internalDate!: ?String = None,
        size!: ?Int64 = None,
        modseq!: ?Int64 = None,
        envelope!: ?ImapEnvelope = None,
        bodyStructure!: ?BodyStructure = None,
        section!: ?String = None,
        origin!: ?Int64 = None
    ) {
        this.sequence = sequence
        this.uid = uid
        this.flags = flags
        this.internalDate = internalDate
        this.size = size
        this.modseq = modseq
        this.envelope = envelope
        this.bodyStructure = bodyStructure
        this.section = section
        this.origin = origin
    }
}

/**
 * `FETCH` 的流式接收器：正文按块交付，内存占用与邮件大小无关。
 *
 * 顺序约定：同一个响应的若干 [onBodyChunk] 全部到齐后，再回调一次 [onComplete]。
 * 反过来做需要先把正文缓存下来才能凑齐元信息，那就失去流式的意义了。
 */
public interface FetchSink {
    func onBodyChunk(chunk: Array<Byte>): Unit
    /** 该响应结束：元信息（UID / FLAGS / ENVELOPE / BODYSTRUCTURE …）此时已完整。 */
    func onComplete(meta: FetchMeta): Unit
}

/** `COPY` 的 `[COPYUID]` 结果。 */
public struct CopyResult {
    public let uidValidity: ?Int64
    public let sourceUids: ?SequenceSet
    public let destUids: ?SequenceSet

    public init(
        uidValidity!: ?Int64 = None,
        sourceUids!: ?SequenceSet = None,
        destUids!: ?SequenceSet = None
    ) {
        this.uidValidity = uidValidity
        this.sourceUids = sourceUids
        this.destUids = destUids
    }
}

/** `APPEND` 的 `[APPENDUID]` 结果。 */
public struct AppendResult {
    public let uidValidity: ?Int64
    public let uid: ?Int64

    public init(uidValidity!: ?Int64 = None, uid!: ?Int64 = None) {
        this.uidValidity = uidValidity
        this.uid = uid
    }
}

/** 邮箱的 `STATUS` 结果。 */
public struct MailboxStatus {
    public let mailbox: String
    public let messages: ?Int64
    public let recent: ?Int64
    public let unseen: ?Int64
    public let uidNext: ?Int64
    public let uidValidity: ?Int64
    public let highestModSeq: ?Int64

    public init(
        mailbox: String,
        messages!: ?Int64 = None,
        recent!: ?Int64 = None,
        unseen!: ?Int64 = None,
        uidNext!: ?Int64 = None,
        uidValidity!: ?Int64 = None,
        highestModSeq!: ?Int64 = None
    ) {
        this.mailbox = mailbox
        this.messages = messages
        this.recent = recent
        this.unseen = unseen
        this.uidNext = uidNext
        this.uidValidity = uidValidity
        this.highestModSeq = highestModSeq
    }
}

/** `LIST` / `LSUB` 的一行。 */
public struct MailboxInfo {
    public let name: String
    public let delimiter: ?String
    public let attributes: Array<String>

    public init(name: String, delimiter!: ?String = None, attributes!: Array<String> = []) {
        this.name = name
        this.delimiter = delimiter
        this.attributes = attributes
    }

    public func hasAttribute(name: String): Bool {
        let wanted = name.toAsciiUpper()
        for (attribute in attributes) {
            if (attribute.toAsciiUpper() == wanted) {
                return true
            }
        }
        false
    }
}

/** `INTERNALDATE`（`dd-Mon-yyyy HH:mm:ss +zzzz`）。 */
public struct ImapDate {
    public let raw: String
    public let day: ?Int64
    public let month: ?String
    public let year: ?Int64
    public let hour: ?Int64
    public let minute: ?Int64
    public let second: ?Int64
    public let zone: ?String

    public init(
        raw: String,
        day!: ?Int64 = None,
        month!: ?String = None,
        year!: ?Int64 = None,
        hour!: ?Int64 = None,
        minute!: ?Int64 = None,
        second!: ?Int64 = None,
        zone!: ?String = None
    ) {
        this.raw = raw
        this.day = day
        this.month = month
        this.year = year
        this.hour = hour
        this.minute = minute
        this.second = second
        this.zone = zone
    }

    /** 宽容解析：格式不对的项留 `None`，不抛异常（服务器时区写法五花八门）。 */
    public static func parse(raw: String): ImapDate {
        var text = raw.trimAscii()
        if (text.size >= 2 && text[0..1] == "\"" && text[(text.size - 1)..] == "\"") {
            text = text[1..(text.size - 1)]
        }
        let parts = text.split(" ", removeEmpty: true)
        if (parts.size < 2) {
            return ImapDate(raw)
        }
        let datePart = parts[0].split("-")
        let timePart = parts[1].split(":")
        var day: ?Int64 = None
        var month: ?String = None
        var year: ?Int64 = None
        if (datePart.size == 3) {
            day = ImapParser.parseNumber(datePart[0])
            month = Some(datePart[1].toAsciiUpper())
            year = ImapParser.parseNumber(datePart[2])
        }
        var hour: ?Int64 = None
        var minute: ?Int64 = None
        var second: ?Int64 = None
        if (timePart.size == 3) {
            hour = ImapParser.parseNumber(timePart[0])
            minute = ImapParser.parseNumber(timePart[1])
            second = ImapParser.parseNumber(timePart[2])
        }
        let zone = if (parts.size > 2) {
            Some(parts[2])
        } else {
            None<String>
        }
        ImapDate(raw, day: day, month: month, year: year, hour: hour, minute: minute, second: second, zone: zone)
    }
}

// ---------- 共用小工具 ----------

func stringOrNone(value: ImapValue): ?String {
    match (value) {
        case Nil => None<String>
        case _ =>
            let text = value.text()
            if (text.size == 0) {
                None<String>
            } else {
                Some(text)
            }
    }
}

func parseParams(value: ImapValue): Array<(String, String)> {
    let out = ArrayList<(String, String)>()
    let items = value.items()
    var index = 0
    while (index + 1 < items.size) {
        let key = items[index].text()
        let text = items[index + 1].text()
        if (key.size > 0) {
            out.add((key, text))
        }
        index += 2
    }
    out.toArray()
}

func findDisposition(items: Array<ImapValue>, from: Int64): ?(String, Array<(String, String)>) {
    var index = from
    while (index < items.size) {
        match (items[index]) {
            case List(entries) =>
                if (entries.size >= 1) {
                    let kind = entries[0].text().toAsciiUpper()
                    if (kind == "ATTACHMENT" || kind == "INLINE") {
                        let params: Array<(String, String)> = if (entries.size > 1) {
                            parseParams(entries[1])
                        } else {
                            []
                        }
                        return Some((kind, params))
                    }
                }
            case _ => ()
        }
        index += 1
    }
    None<(String, Array<(String, String)>)>
}
