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
package fountain::fprobe.channel

import std.collection.ArrayList
import std.convert.*
import std.fs.Path
import fountain::f_config.Config
import fountain::f_email.Email
import fountain::f_email.model.{FileBodySource, MailMessage, Secret}
import fountain::f_email.transport.TlsMode
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/**
 * 基于 `f_email` 的生产传输。
 *
 * `Email` 懒连接：只发告警时不要求 IMAP 可达，`receive()` 第一次调用才连收件服务器。
 */
public class FEmailTransport <: MailTransport {
    private let email: Email

    public init(email: Email) {
        this.email = email
    }

    /** 按 `probe_channel_email_*` 配置构造；SMTP 主机缺失时启动失败。 */
    public static func fromConfig(): FEmailTransport {
        let smtpHost = match (Config.getString("probe_channel_email_smtpHost")) {
            case Some(value) =>
                let trimmed = value.trimAscii()
                if (trimmed.isEmpty()) {
                    throw ProbeException(ProbeErrorCode.CONFIG, "probe_channel_email_smtpHost 未配置")
                }
                trimmed
            case None =>
                throw ProbeException(ProbeErrorCode.CONFIG, "probe_channel_email_smtpHost 未配置")
        }
        let smtpPort = Config.getValue<UInt16>("probe_channel_email_smtpPort") ?? 465
        let tls = match (Config.getString("probe_channel_email_smtpTls")) {
            case Some(raw) => match (Bool.tryParse(raw.trimAscii())) {
                case Some(value) => value
                case None => true
            }
            case None => true
        }

        var builder = Email.builder().smtp(smtpHost, port: smtpPort)
        match (Config.getString("probe_channel_email_smtpUser")) {
            case Some(user) =>
                let trimmed = user.trimAscii()
                if (!trimmed.isEmpty()) {
                    let password = Config.getString("probe_channel_email_smtpPassword") ?? ""
                    builder = builder.auth(trimmed, Secret.of(password))
                }
            case None => ()
        }
        builder = if (tls) {
            builder.tls(TlsMode.Implicit)
        } else {
            builder.tls(TlsMode.None).allowPlaintextAuth(true).requireEncryption(false)
        }

        match (Config.getString("probe_channel_email_imapHost")) {
            case Some(host) =>
                let trimmed = host.trimAscii()
                if (!trimmed.isEmpty()) {
                    let imapPort = Config.getValue<UInt16>("probe_channel_email_imapPort") ?? 993
                    builder = builder.imap(trimmed, port: imapPort)
                }
            case None => ()
        }

        FEmailTransport(builder.build())
    }

    public func send(mail: OutgoingMail): Unit {
        var builder = MailMessage.builder()
            .from(mail.sender)
            .subject(mail.subject)
            .text(mail.text)
        if (!mail.html.isEmpty()) {
            builder = builder.html(mail.html)
        }
        for (receiver in mail.receivers) {
            builder = builder.to(receiver)
        }
        for (attachment in mail.attachments) {
            builder = builder.attach(attachment.filename,
                FileBodySource(Path(attachment.path)), mediaType: attachment.mediaType)
        }

        let report = email.send(builder.build())
        if (!report.isCompleteSuccess()) {
            throw ProbeException(ProbeErrorCode.COLLECT,
                '邮件发送未完全成功：${mail.subject}，被拒 ${report.rejected.size} 个收件人')
        }
    }

    public func list(limit: Int64): Array<ReceivedMail> {
        let summaries = email.list(limit: limit)
        let result = ArrayList<ReceivedMail>()
        for (summary in summaries) {
            let unread = summary.isUnread()
            var text = ""
            var html = ""
            if (unread) {
                let body = email.body(summary)
                text = body.text ?? ""
                html = body.html ?? ""
            }
            result.add(ReceivedMail(summary.id.toString(), summary.from, summary.subject, unread, text, html))
        }
        result.toArray()
    }
}
