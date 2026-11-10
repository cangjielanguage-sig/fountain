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
package fountain::f_email

import std.collection.ArrayList
import std.fs.{Directory, File, Path, exists}
import std.io.InputStream
import cangjie_tpc::charset4cj.charset.Charsets
import fountain::f_email.model.*
import fountain::f_email.transport.*
import fountain::f_email.imap.*
import fountain::f_email.pop3.*
import fountain::f_email.smtp.*

/**
 * 收件协议。
 *
 * `Imap` 能列目录、按 UID 精确定位、只看正文不置已读；`Pop3` 兼容面更广，
 * 但只有"第几封"这一种标识，且删除要 `QUIT` 才提交。
 */
public enum ReceiveProtocol <: ToString {
    | Imap
    | Pop3

    public func toString(): String {
        match (this) {
            case Imap => "IMAP"
            case Pop3 => "POP3"
        }
    }
}

/**
 * 一封邮件在"列表"里的摘要：标题、发件人、接收时间与大小。
 *
 * [id] 在 IMAP 下是 UID（跨会话稳定），在 POP3 下是邮件序号（仅本次会话有效）。
 * [sequence] 在 IMAP 下是当前邮箱里的序号（会随 `EXPUNGE` 移动），POP3 下与 [id] 相同。
 * 后续 [Email.fetch] / [Email.body] / [Email.delete] 都直接用这个摘要定位，不需要调用方记序号。
 */
public struct MailSummary {
    public let id: Int64
    public let sequence: Int64
    public let mailbox: String
    public let subject: String
    public let from: String
    public let date: ?MailDate
    public let receivedAt: ?MailDate
    public let size: ?Int64
    public let flags: Array<String>

    public init(
        id: Int64,
        sequence!: Int64,
        mailbox!: String,
        subject!: String = "",
        from!: String = "",
        date!: ?MailDate = None,
        receivedAt!: ?MailDate = None,
        size!: ?Int64 = None,
        flags!: Array<String> = []
    ) {
        this.id = id
        this.sequence = sequence
        this.mailbox = mailbox
        this.subject = subject
        this.from = from
        this.date = date
        this.receivedAt = receivedAt
        this.size = size
        this.flags = flags
    }

    /** 未读：不带 `\Seen`。POP3 没有 flag，恒为 `false`。 */
    public func isUnread(): Bool {
        !flags.contains("\\Seen")
    }
}

/**
 * 附件。
 *
 * 二进制附件走 [BodySource] 流式读，不会为了报大小先整块进内存；
 * 纯文本附件在解析阶段已经变成 `String`，这里按声明的字符集重新编码取字节。
 */
public class MailAttachment {
    private let part: MimePart
    public let filename: String
    public let mediaType: String

    public init(part: MimePart) {
        this.part = part
        var name = "attachment.bin"
        match (part.disposition) {
            case Some(disposition) =>
                if (let Some(value) <- disposition.filename()) {
                    name = value
                }
            case None => ()
        }
        if (name == "attachment.bin") {
            if (let Some(value) <- part.contentType.name()) {
                name = value
            }
        }
        this.filename = name
        this.mediaType = part.contentType.mediaType
    }

    /** 附件字节数；未知时为 `-1`。 */
    public prop size: Int64 {
        get() {
            match (part.source()) {
                case Some(source) => source.size
                case None => rawText().toArray().size
            }
        }
    }

    /** 打开字节流。二进制附件每次调用都是新流（一次性来源除外）。 */
    public func open(): InputStream {
        match (part.source()) {
            case Some(source) => source.open()
            case None => MemoryBodySource(rawText().toArray()).open()
        }
    }

    /** 一次性读完全部字节。大附件请用 [open]。 */
    public func read(): Array<Byte> {
        let input = open()
        let out = ArrayList<Byte>()
        let buffer = Array<Byte>(64 * 1024, repeat: 0)
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

    /** 落盘；父目录不存在时自动创建。 */
    public func saveTo(path: Path): Unit {
        let dir = path.parent
        if (dir.toString().size > 0 && !exists(dir)) {
            Directory.create(dir, recursive: true)
        }
        let file = File.create(path)
        try {
            let input = open()
            let buffer = Array<Byte>(64 * 1024, repeat: 0)
            while (true) {
                let n = input.read(buffer)
                if (n <= 0) {
                    break
                }
                let chunk = Array<Byte>(n, repeat: 0)
                for (i in 0..n) {
                    chunk[i] = buffer[i]
                }
                file.write(chunk)
            }
        } finally {
            file.close()
        }
    }

    private func rawText(): String {
        part.text() ?? ""
    }
}

/** 正文与附件。 */
public class MailBody {
    public let text: ?String
    public let html: ?String
    public let attachments: Array<MailAttachment>

    public init(text: ?String, html: ?String, attachments: Array<MailAttachment>) {
        this.text = text
        this.html = html
        this.attachments = attachments
    }
}

/**
 * 统一门面：一个类里管理 SMTP / IMAP / POP3。
 *
 * 三条约定：
 *
 * 1. **懒连接**：`build()` 不建立任何连接；第一次 `send` 才连 SMTP，第一次
 *    `list` / `fetch` / `delete` 才连收件协议。只发信不需要 IMAP 可达，反之亦然。
 * 2. **定位用摘要**：[list] 返回 [MailSummary]，之后的读正文、取附件、删除都传摘要，
 *    调用方不用记 IMAP 序号或 POP3 编号，也不会因为 `EXPUNGE` 导致序号移动而删错信。
 * 3. **只读语义可保**：IMAP 的 `EXAMINE` / `BODY.PEEK[]` 不会把邮件标成已读；删除是独立动作，
 *    必须显式调用 [delete]。
 */
public class Email <: Resource {
    private let config: EmailConfig
    private var smtpValue: ?SmtpClient = None
    private var imapValue: ?ImapClient = None
    private var pop3Value: ?Pop3Client = None
    private var currentMailbox: String = "INBOX"
    private var selectedMailbox: ?String = None
    private var selectedReadOnly = false
    private var closedFlag = false

    init(config: EmailConfig) {
        this.config = config
    }

    public static func builder(): EmailBuilder {
        EmailBuilder()
    }

    /** 用默认发件人与正文发送。 */
    public func send(message: MailMessage): SendReport {
        ensureOpen()
        smtpClient().send(message)
    }

    /** 显式信封发送（`MAIL FROM` / `RCPT TO` 与头部分离）。 */
    public func send(envelope: Envelope, message: MailMessage): SendReport {
        ensureOpen()
        smtpClient().send(envelope, message)
    }

    /** 列举当前邮箱最近 [limit] 封；`limit <= 0` 表示全部。 */
    public func list(limit!: Int64 = 20): Array<MailSummary> {
        list(currentMailbox, limit: limit)
    }

    /** 列举指定邮箱最近 [limit] 封。POP3 没有邮箱概念，忽略名称。 */
    public func list(mailbox: String, limit!: Int64 = 20): Array<MailSummary> {
        ensureOpen()
        let limitValue = if (limit <= 0) {
            0
        } else {
            limit
        }
        match (config.protocol) {
            case ReceiveProtocol.Imap =>
                let imap = imapClient()
                ensureMailbox(imap, mailbox)
                currentMailbox = mailbox
                let total = imap.messages
                if (total <= 0) {
                    return []
                }
                let from = if (limitValue > 0 && total > limitValue) {
                    total - limitValue + 1
                } else {
                    1
                }
                let items = imap.fetch(
                    SequenceSet.range(from, total),
                    [
                        FetchItem.uid(),
                        FetchItem.flags(),
                        FetchItem.envelope(),
                        FetchItem.internalDate(),
                        FetchItem.size()
                    ]
                )
                let out = ArrayList<MailSummary>()
                for (item in items) {
                    let uid = match (item.uid) {
                        case Some(value) => value
                        case None => item.sequence
                    }
                    var subject = ""
                    var fromText = ""
                    var date: ?MailDate = None
                    match (item.envelope) {
                        case Some(envelope) =>
                            subject = envelope.subject ?? ""
                            if (envelope.from.size > 0) {
                                fromText = envelope.from[0].toString()
                            }
                            match (envelope.date) {
                                case Some(raw) => date = Some(MailDate.parse(raw))
                                case None => ()
                            }
                        case None => ()
                    }
                    out.add(
                        MailSummary(
                            uid,
                            sequence: item.sequence,
                            mailbox: mailbox,
                            subject: subject,
                            from: fromText,
                            date: date,
                            receivedAt: imapDate(item.internalDate),
                            size: item.size,
                            flags: item.flags
                        )
                    )
                }
                return out.toArray()
            case ReceiveProtocol.Pop3 =>
                let pop3 = pop3Client()
                let infos = pop3.list()
                let start = if (limitValue > 0 && infos.size > limitValue) {
                    infos.size - limitValue
                } else {
                    0
                }
                let out = ArrayList<MailSummary>()
                var index = start
                while (index < infos.size) {
                    let info = infos[index]
                    let header = pop3.topMessage(info.number, 0)
                    out.add(
                        MailSummary(
                            info.number,
                            sequence: info.number,
                            mailbox: "INBOX",
                            subject: header.subject() ?? "",
                            from: header.from()?.toString() ?? "",
                            date: header.date(),
                            receivedAt: None<MailDate>,
                            size: Some(info.size),
                            flags: []
                        )
                    )
                    index += 1
                }
                return out.toArray()
        }
    }

    /** 取整封邮件（正文 + 附件都已解码，附件超阈值时落临时文件）。 */
    public func fetch(mail: MailSummary): MailMessage {
        ensureOpen()
        match (config.protocol) {
            case ReceiveProtocol.Imap =>
                let imap = imapClient()
                ensureMailbox(imap, mail.mailbox)
                currentMailbox = mail.mailbox
                let messages = imap.uidFetchMessage(SequenceSet.single(mail.id))
                if (messages.size == 0) {
                    throw MailProtocolException("邮件不存在：uid=${mail.id}")
                }
                return messages[0]
            case ReceiveProtocol.Pop3 =>
                return pop3Client().retrMessage(mail.sequence)
        }
    }

    /** 读正文与附件列表（文本已按字符集解码）。 */
    public func body(mail: MailSummary): MailBody {
        let message = fetch(mail)
        let attachments = ArrayList<MailAttachment>()
        for (part in message.attachments()) {
            attachments.add(MailAttachment(part))
        }
        MailBody(message.text(), message.html(), attachments.toArray())
    }

    /** 只取附件。 */
    public func attachments(mail: MailSummary): Array<MailAttachment> {
        body(mail).attachments
    }

    /** 只取纯文本正文。 */
    public func text(mail: MailSummary): ?String {
        fetch(mail).text()
    }

    /**
     * 删除指定邮件。
     *
     * IMAP：`STORE +FLAGS \Deleted` 后按 UID `EXPUNGE`，只删这一封，不影响同邮箱里
     * 其它被别的客户端标删的邮件。POP3：`DELE` 后立即 `QUIT` 提交，会话随之结束，
     * 下一次操作会自动重连。
     */
    public func delete(mail: MailSummary): Unit {
        ensureOpen()
        match (config.protocol) {
            case ReceiveProtocol.Imap =>
                let imap = imapClient()
                ensureMailbox(imap, mail.mailbox, readOnly: false)
                currentMailbox = mail.mailbox
                let located = imap.uidFetch(SequenceSet.single(mail.id), [FetchItem.uid()])
                if (located.size == 0) {
                    throw MailProtocolException("邮件不存在：uid=${mail.id}")
                }
                imap.store(SequenceSet.single(located[0].sequence), StoreOperation.Add, ["\\Deleted"])
                imap.uidExpunge(SequenceSet.single(mail.id))
            case ReceiveProtocol.Pop3 =>
                let pop3 = pop3Client()
                pop3.dele(mail.sequence)
                pop3.quit()
                pop3Value = None
        }
    }

    /** 当前收件协议。 */
    public prop protocol: ReceiveProtocol {
        get() {
            config.protocol
        }
    }

    public func close(): Unit {
        if (closedFlag) {
            return
        }
        closedFlag = true
        match (smtpValue) {
            case Some(client) =>
                try {
                    client.close()
                } catch (_: Exception) {}
                smtpValue = None
            case None => ()
        }
        match (imapValue) {
            case Some(client) =>
                try {
                    client.close()
                } catch (_: Exception) {}
                imapValue = None
            case None => ()
        }
        match (pop3Value) {
            case Some(client) =>
                try {
                    client.close()
                } catch (_: Exception) {}
                pop3Value = None
            case None => ()
        }
    }

    public func isClosed(): Bool {
        closedFlag
    }

    // ---------- 内部 ----------

    private func ensureOpen(): Unit {
        if (closedFlag) {
            throw MailIoException(IoStage.Read, "Email 已关闭")
        }
    }

    /**
     * 保证连接停在目标邮箱上。
     *
     * 读操作一律用 `EXAMINE`（只读），只有 [delete] 需要 `SELECT`（可写）；
     * 同一个邮箱同一种模式不重复发命令，切换邮箱或切换读写模式才重发。
     */
    private func ensureMailbox(imap: ImapClient, mailbox: String, readOnly!: Bool = true): Unit {
        match (selectedMailbox) {
            case Some(current) =>
                if (current == mailbox && selectedReadOnly == readOnly) {
                    return
                }
            case None => ()
        }
        if (readOnly) {
            imap.examine(mailbox)
        } else {
            imap.select(mailbox)
        }
        selectedMailbox = Some(mailbox)
        selectedReadOnly = readOnly
    }

    private func smtpClient(): SmtpClient {
        match (smtpValue) {
            case Some(client) => client
            case None =>
                let host = config.smtpHost
                if (host.isNone()) {
                    throw IllegalArgumentException("未配置 SMTP 服务器，无法发送")
                }
                let builder = SmtpClient.builder(host.getOrThrow(), port: config.smtpPort)
                    .tls(config.tlsMode)
                    .timeouts(config.timeouts)
                    .requireEncryption(config.requireEncryption)
                    .allowPlaintextAuth(config.allowPlaintextAuth)
                if (let Some(factory) <- config.smtpTransport) {
                    builder.transport(factory)
                }
                if (let Some(user) <- config.user) {
                    builder.auth(SmtpAuthMechanism.Login, user, config.secret.getOrThrow())
                }
                let built = builder.build()
                smtpValue = Some(built)
                built
        }
    }

    private func imapClient(): ImapClient {
        match (imapValue) {
            case Some(client) => client
            case None =>
                let host = config.imapHost
                if (host.isNone()) {
                    throw IllegalArgumentException("未配置 IMAP 服务器")
                }
                let builder = ImapClient.builder(host.getOrThrow(), port: config.imapPort)
                    .tls(config.tlsMode)
                    .timeouts(config.timeouts)
                    .requireEncryption(config.requireEncryption)
                    .allowPlaintextAuth(config.allowPlaintextAuth)
                if (let Some(factory) <- config.imapTransport) {
                    builder.transport(factory)
                }
                let built = builder.build()
                let user = config.user
                if (user.isNone()) {
                    throw IllegalArgumentException("未配置账号，无法登录 IMAP")
                }
                built.login(user.getOrThrow(), config.secret.getOrThrow())
                imapValue = Some(built)
                built
        }
    }

    private func pop3Client(): Pop3Client {
        match (pop3Value) {
            case Some(client) => client
            case None =>
                let host = config.pop3Host
                if (host.isNone()) {
                    throw IllegalArgumentException("未配置 POP3 服务器")
                }
                let builder = Pop3Client.builder(host.getOrThrow(), port: config.pop3Port)
                    .tls(config.tlsMode)
                    .timeouts(config.timeouts)
                    .requireEncryption(config.requireEncryption)
                    .allowPlaintextAuth(config.allowPlaintextAuth)
                if (let Some(factory) <- config.pop3Transport) {
                    builder.transport(factory)
                }
                let built = builder.build()
                let user = config.user
                if (user.isNone()) {
                    throw IllegalArgumentException("未配置账号，无法登录 POP3")
                }
                built.login(user.getOrThrow(), config.secret.getOrThrow())
                pop3Value = Some(built)
                built
        }
    }

    private func imapDate(raw: ?String): ?MailDate {
        match (raw) {
            case Some(text) =>
                let parsed = ImapDate.parse(text)
                match ((parsed.day, parsed.month, parsed.year)) {
                    case (Some(day), Some(month), Some(year)) =>
                        let hour = parsed.hour ?? 0
                        let minute = parsed.minute ?? 0
                        let second = parsed.second ?? 0
                        let zone = parsed.zone ?? "+0000"
                        let normalized = "${day} ${month} ${year} ${pad2(hour)}:${pad2(minute)}:${pad2(second)} ${zone}"
                        return Some(MailDate.parse(normalized))
                    case _ => return None<MailDate>
                }
            case None => None<MailDate>
        }
    }

    private func pad2(value: Int64): String {
        if (value < 10) {
            return "0${value}"
        }
        "${value}"
    }
}

/** `Email` 的不可变配置；由 [EmailBuilder] 组装。 */
class EmailConfig {
    let smtpHost: ?String
    let smtpPort: UInt16
    let imapHost: ?String
    let imapPort: UInt16
    let pop3Host: ?String
    let pop3Port: UInt16
    let tlsMode: TlsMode
    let user: ?String
    let secret: ?Secret
    let protocol: ReceiveProtocol
    let timeouts: MailTimeouts
    let allowPlaintextAuth: Bool
    let requireEncryption: Bool
    let smtpTransport: ?TransportFactory
    let imapTransport: ?TransportFactory
    let pop3Transport: ?TransportFactory

    init(
        smtpHost: ?String,
        smtpPort: UInt16,
        imapHost: ?String,
        imapPort: UInt16,
        pop3Host: ?String,
        pop3Port: UInt16,
        tlsMode: TlsMode,
        user: ?String,
        secret: ?Secret,
        protocol: ReceiveProtocol,
        timeouts: MailTimeouts,
        allowPlaintextAuth: Bool,
        requireEncryption: Bool,
        smtpTransport: ?TransportFactory,
        imapTransport: ?TransportFactory,
        pop3Transport: ?TransportFactory
    ) {
        this.smtpHost = smtpHost
        this.smtpPort = smtpPort
        this.imapHost = imapHost
        this.imapPort = imapPort
        this.pop3Host = pop3Host
        this.pop3Port = pop3Port
        this.tlsMode = tlsMode
        this.user = user
        this.secret = secret
        this.protocol = protocol
        this.timeouts = timeouts
        this.allowPlaintextAuth = allowPlaintextAuth
        this.requireEncryption = requireEncryption
        this.smtpTransport = smtpTransport
        this.imapTransport = imapTransport
        this.pop3Transport = pop3Transport
    }
}

/**
 * [Email] 的构造器。
 *
 * 端口默认值按隐式 TLS 的常见组合给：SMTP 587、IMAP 993、POP3 995。
 * 用 465 时要显式 `smtp(host, port: 465)`；`tls` 默认 `Implicit`，明文调试需显式
 * `tls(TlsMode.None)` + `allowPlaintextAuth(true)`。
 */
public class EmailBuilder {
    private var smtpHostValue: ?String = None
    private var smtpPortValue: UInt16 = 587
    private var imapHostValue: ?String = None
    private var imapPortValue: UInt16 = 993
    private var pop3HostValue: ?String = None
    private var pop3PortValue: UInt16 = 995
    private var tlsModeValue: TlsMode = TlsMode.Implicit
    private var userValue: ?String = None
    private var secretValue: ?Secret = None
    private var protocolValue: ReceiveProtocol = ReceiveProtocol.Imap
    private var timeoutsValue: MailTimeouts = MailTimeouts()
    private var allowPlaintextAuthValue = false
    private var requireEncryptionValue = true
    private var smtpTransportValue: ?TransportFactory = None
    private var imapTransportValue: ?TransportFactory = None
    private var pop3TransportValue: ?TransportFactory = None

    public func smtp(host: String, port!: UInt16 = 587): This {
        smtpHostValue = Some(host)
        smtpPortValue = port
        this
    }

    public func imap(host: String, port!: UInt16 = 993): This {
        imapHostValue = Some(host)
        imapPortValue = port
        this
    }

    public func pop3(host: String, port!: UInt16 = 995): This {
        pop3HostValue = Some(host)
        pop3PortValue = port
        this
    }

    /** 选择收件协议；不设时默认 IMAP。 */
    public func receiveVia(protocol: ReceiveProtocol): This {
        protocolValue = protocol
        this
    }

    public func tls(mode: TlsMode): This {
        tlsModeValue = mode
        this
    }

    /** 发送与收件共用同一套账号。 */
    public func auth(user: String, secret: Secret): This {
        userValue = Some(user)
        secretValue = Some(secret)
        this
    }

    public func timeouts(timeouts: MailTimeouts): This {
        timeoutsValue = timeouts
        this
    }

    public func allowPlaintextAuth(allow: Bool): This {
        allowPlaintextAuthValue = allow
        this
    }

    public func requireEncryption(required: Bool): This {
        requireEncryptionValue = required
        this
    }

    /** 测试注入：替换 SMTP 传输层。 */
    public func smtpTransport(factory: TransportFactory): This {
        smtpTransportValue = Some(factory)
        this
    }

    /** 测试注入：替换 IMAP 传输层。 */
    public func imapTransport(factory: TransportFactory): This {
        imapTransportValue = Some(factory)
        this
    }

    /** 测试注入：替换 POP3 传输层。 */
    public func pop3Transport(factory: TransportFactory): This {
        pop3TransportValue = Some(factory)
        this
    }

    public func build(): Email {
        if (smtpHostValue.isNone() && imapHostValue.isNone() && pop3HostValue.isNone()) {
            throw IllegalArgumentException("至少配置 smtp / imap / pop3 中的一个服务器")
        }
        if (userValue.isSome() != secretValue.isSome()) {
            throw IllegalArgumentException("auth 必须同时给 user 与 secret")
        }
        // 只发信可以不给收件服务器；但只要配了收件服务器，协议必须对得上
        match (protocolValue) {
            case ReceiveProtocol.Imap =>
                if (imapHostValue.isNone() && pop3HostValue.isSome()) {
                    throw IllegalArgumentException("配置了 pop3 但收件协议是 IMAP，请显式 receiveVia(ReceiveProtocol.Pop3)")
                }
            case ReceiveProtocol.Pop3 =>
                if (pop3HostValue.isNone()) {
                    throw IllegalArgumentException("receiveVia(POP3) 需要 pop3(host)")
                }
        }
        Email(
            EmailConfig(
                smtpHostValue,
                smtpPortValue,
                imapHostValue,
                imapPortValue,
                pop3HostValue,
                pop3PortValue,
                tlsModeValue,
                userValue,
                secretValue,
                protocolValue,
                timeoutsValue,
                allowPlaintextAuthValue,
                requireEncryptionValue,
                smtpTransportValue,
                imapTransportValue,
                pop3TransportValue
            )
        )
    }
}
