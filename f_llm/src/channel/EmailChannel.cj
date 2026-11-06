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
package fountain::f_llm.channel

import std.collection.*
import std.fs.*
import std.sync.*
import fountain::f_email.{Email, MailMessage}
import fountain::f_llm.config.LLMConfig
import fountain::f_email.model.{FileBodySource, Secret}

/** 收到的一封邮件里的附件：字节按需读，避免一次把全部附件读进内存 */
public class ReceivedAttachment {
    public let filename: String
    public let size: Int64
    public let read: () -> Array<Byte>

    public init(filename: String, size: Int64, read: () -> Array<Byte>) {
        this.filename = filename
        this.size = size
        this.read = read
    }
}

/** transport 层的一封邮件（未做落盘与模型映射） */
public class ReceivedMail {
    public let id: String
    public let from: String
    public let subject: String
    public let text: String
    public let receivedAt: String
    public let unread: Bool
    public let attachments: ArrayList<ReceivedAttachment>

    public init(id: String, from: String, subject: String, text!: String = '', receivedAt!: String = '',
        unread!: Bool = false, attachments!: ArrayList<ReceivedAttachment> = ArrayList<ReceivedAttachment>()) {
        this.id = id
        this.from = from
        this.subject = subject
        this.text = text
        this.receivedAt = receivedAt
        this.unread = unread
        this.attachments = attachments
    }
}

/**
 * 邮件传输层：把 `f_email` 隔离在可替换接口后面，单测注入假实现即可离线验证映射。
 */
public interface EmailTransport {
    func send(message: OutboundMessage, from: String): SendReceipt
    func receive(limit: Int64): ArrayList<ReceivedMail>
    func close(): Unit
}

/**
 * 附件落盘：目录不存在直接失败；同名顺延 `-2`、`-3`…，不覆盖已有文件。
 */
public class AttachmentSink {
    private init() {
    }

    /** 落盘串行化：把「选名 + 创建」放进同一临界区，避免并发覆盖 */
    private static let sinkMutex: Mutex = Mutex()
    private static let FALLBACK_NAME = 'attachment.bin'
    private static let MAX_NAME_CHARS = 120

    /**
     * 只保留最后一段文件名：`../../etc/passwd` → `passwd`，`a\\b\\c.txt` → `c.txt`。
     *
     * 规则：`/` 与 `\\` 都当分隔符；去掉控制字符；拒绝空名、`.`、`..`；超长按字符截断。
     */
    public static func bareName(filename: String): String {
        let text = filename.trimAscii()
        if (text.isEmpty()) {
            return FALLBACK_NAME
        }
        var start = 0
        for (index in 0..text.size) {
            let byte = text[index]
            if (byte == 47u8 || byte == 92u8) {
                start = index + 1
            }
        }
        let tail = text[start..]
        let cleaned = StringBuilder()
        var count = 0
        for (rune in tail.runes()) {
            if (rune < r'\u{20}' || rune == r'\u{7f}') {
                continue
            }
            if (count >= MAX_NAME_CHARS) {
                break
            }
            cleaned.append(rune)
            count++
        }
        let name = cleaned.toString().trimAscii()
        if (name.isEmpty() || name == '.' || name == '..') {
            return FALLBACK_NAME
        }
        name
    }

    /** 在 `directory` 里为 `filename` 找一个不冲突的名字（不含目录）：`a.txt` → `a-2.txt` */
    public static func freeName(directory: String, filename: String): String {
        let base = bareName(filename)
        if (!exists(Path('${directory}/${base}'))) {
            return base
        }
        var stem = base
        var extension = ''
        match (base.indexOf('.')) {
            case Some(dot) =>
                if (dot > 0) {
                    stem = base[0..dot]
                    extension = base[dot..]
                }
            case None => ()
        }
        var index = 2
        while (true) {
            let candidate = '${stem}-${index}${extension}'
            if (!exists(Path('${directory}/${candidate}'))) {
                return candidate
            }
            index++
        }
        base
    }

    /**
     * @return `(落盘路径, 错误说明)`；失败时路径为空串
     */
    public static func save(directory: String, filename: String, bytes: Array<Byte>): (String, String) {
        let dir = directory.trimAscii()
        if (dir.isEmpty()) {
            return ('', 'download directory is required')
        }
        if (!exists(Path(dir))) {
            return ('', 'download directory not found: ${dir}')
        }
        var file: ?File = None
        try {
            // 「选名 + 创建」在锁内完成：进程内并发不会拿到同一个名字
            var target = ''
            synchronized(sinkMutex) {
                let name = freeName(dir, filename)
                target = '${dir}/${name}'
                file = Some(File.create(Path(target)))
            }
            file.getOrThrow().write(bytes)
            (target, '')
        } catch (e: Exception) {
            ('', 'write attachment failed: ${e.message}')
        } finally {
            match (file) {
                case Some(value) => try {
                    value.close()
                } catch (e: Exception) {}
                case None => ()
            }
        }
    }
}

/** 邮件通道：把通用消息模型翻译成 transport 调用 */
public class EmailChannel <: Channel {
    private let accountName: String
    private let sender: String
    private let transport: EmailTransport

    public init(account: String, from: String, transport: EmailTransport) {
        this.accountName = account
        this.sender = from
        this.transport = transport
    }

    public prop platform: String {
        get() {
            ChannelPlatforms.EMAIL
        }
    }

    public prop account: String {
        get() {
            accountName
        }
    }

    public func send(message: OutboundMessage): SendReceipt {
        let roots = LLMConfig.channelSendRoots()
        for (attachment in message.attachments) {
            if (roots.isEmpty()) {
                return SendReceipt.failure(
                    'attachment directory not configured (llm_channelSendRoots): ${attachment.filename}')
            }
            match (checkAttachment(attachment, roots)) {
                case Some(reason) => return SendReceipt.failure(reason)
                case None => ()
            }
        }
        transport.send(message, sender)
    }

    /** 附件必须在允许根目录内、存在、且不是目录；返回拒绝原因（`None` 表示通过） */
    private static func checkAttachment(attachment: OutboundAttachment, roots: ArrayList<String>): Option<String> {
        if (!exists(Path(attachment.path))) {
            return Some('attachment not found: ${attachment.filename} (${attachment.path})')
        }
        var actual = attachment.path
        try {
            actual = canonicalize(Path(attachment.path)).toString()
        } catch (e: Exception) {
            return Some('attachment path is not accessible: ${attachment.filename}')
        }
        for (root in roots) {
            var base = root
            try {
                base = canonicalize(Path(root)).toString()
            } catch (e: Exception) {
                continue
            }
            let inside = actual == base || actual.startsWith('${base}/')
            if (inside) {
                if (isDirectory(Path(actual))) {
                    return Some('attachment is a directory: ${attachment.filename}')
                }
                return None
            }
        }
        Some('attachment outside allowed roots: ${attachment.filename} (${attachment.path})')
    }

    /** 目录判定：`<path>/.` 能解析说明是目录；文件/不存在都会抛 */
    private static func isDirectory(path: Path): Bool {
        try {
            let _ = canonicalize(Path('${path}/.'))
            true
        } catch (e: Exception) {
            false
        }
    }

    public func receive(limit: Int64, downloadDir: String): ArrayList<InboundMessage> {
        let result = ArrayList<InboundMessage>()
        for (mail in transport.receive(limit)) {
            let attachments = ArrayList<InboundAttachment>()
            for (item in mail.attachments) {
                if (downloadDir.trimAscii().isEmpty()) {
                    attachments.add(InboundAttachment(item.filename, item.size))
                    continue
                }
                let (path, error) = AttachmentSink.save(downloadDir, item.filename, item.read())
                if (error.isEmpty()) {
                    attachments.add(InboundAttachment(item.filename, item.size, path: path, saved: true))
                } else {
                    attachments.add(InboundAttachment(item.filename, item.size, error: error))
                }
            }
            result.add(
                InboundMessage(mail.id, mail.from, mail.subject, text: mail.text, receivedAt: mail.receivedAt,
                    unread: mail.unread, attachments: attachments))
        }
        result
    }

    public func close(): Unit {
        transport.close()
    }
}

/** 生产 transport：包住 `f_email` 的 `Email` 门面（懒连接） */
public class FEmailTransport <: EmailTransport {
    private let conf: ChannelAccountConf
    private var client: ?Email = None

    public init(conf: ChannelAccountConf) {
        this.conf = conf
    }

    private func email(): Email {
        match (client) {
            case Some(value) => return value
            case None => ()
        }
        if (conf.smtpHost.trimAscii().isEmpty() || conf.user.trimAscii().isEmpty()) {
            throw ChannelException('email account ${conf.account} requires smtpHost and user')
        }
        let built = Email
            .builder()
            .smtp(conf.smtpHost, port: conf.smtpPort)
            .imap(conf.imapHost, port: conf.imapPort)
            .auth(conf.user, Secret.of(conf.password))
            .build()
        client = Some(built)
        built
    }

    public func send(message: OutboundMessage, from: String): SendReceipt {
        try {
            let builder = MailMessage
                .builder()
                .from(if (from.trimAscii().isEmpty()) {
                    conf.user
                } else {
                    from
                })
                .to(message.to)
                .subject(message.subject)
            if (message.html.trimAscii().isEmpty()) {
                let _ = builder.text(message.text)
            } else {
                let _ = builder.html(message.html)
            }
            for (attachment in message.attachments) {
                let _ = builder.attach(attachment.filename, FileBodySource(Path(attachment.path)))
            }
            let report = email().send(builder.build())
            let accepted = report.accepted.size
            let rejected = report.rejected.size
            if (report.aborted || rejected > 0) {
                return SendReceipt.failure('smtp rejected ${rejected} of ${accepted + rejected} recipients')
            }
            SendReceipt.success(messageId: report.messageId)
        } catch (e: ChannelException) {
            SendReceipt.failure(e.message)
        } catch (e: Exception) {
            SendReceipt.failure('email send failed: ${e.message}')
        }
    }

    public func receive(limit: Int64): ArrayList<ReceivedMail> {
        let result = ArrayList<ReceivedMail>()
        try {
            let messages = email().list(limit: limit)
            for (summary in messages) {
                let body = email().body(summary)
                let text = body.text ?? ''
                let attachments = ArrayList<ReceivedAttachment>()
                for (item in body.attachments) {
                    attachments.add(ReceivedAttachment(item.filename, item.size, {=> item.read()}))
                }
                result.add(
                    ReceivedMail('${summary.id}', summary.from, summary.subject, text: text, receivedAt: '',
                        unread: summary.isUnread(), attachments: attachments))
            }
        } catch (e: Exception) {
            // 收信失败不抛给流程：返回空列表，调用方可从工具结果看到 0 条
            return result
        }
        result
    }

    public func close(): Unit {
        match (client) {
            case Some(value) => try {
                value.close()
            } catch (_: Exception) {}
            case None => ()
        }
        client = None
    }
}

/** 静态注册：模块加载即把 `email` 平台挂到中介者（Cangjie 无 static initializer，用顶层 let） */
let _emailChannelProviderRegistered = ChannelMediator.registerProvider(ChannelPlatforms.EMAIL,
    {conf: ChannelAccountConf => EmailChannel(conf.account, conf.from, FEmailTransport(conf))})
