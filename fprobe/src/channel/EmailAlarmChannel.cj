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
import fountain::f_data.*
import fountain::f_probe.{AlarmMessageChannel, ProbeErrorCode, ProbeException}

/**
 * 邮件告警渠道（设计 D11）。
 *
 * 只依赖 [MailTransport]，SMTP / IMAP 细节由生产实现负责；用例注入假传输即可
 * 验证 HTML、附件与收件映射，不打开任何网络连接。
 */
public class EmailAlarmChannel <: AlarmMessageChannel {
    private let transport: MailTransport
    private let sender: String
    private let subjectPrefix: String
    private let defaultReceivers: Array<String>
    private let receiveLimit: Int64

    public init(transport: MailTransport, sender: String, subjectPrefix!: String = "[fprobe]",
        defaultReceivers!: Array<String> = [], receiveLimit!: Int64 = 20) {
        this.transport = transport
        this.sender = sender
        this.subjectPrefix = subjectPrefix
        this.defaultReceivers = defaultReceivers
        this.receiveLimit = receiveLimit
    }

    public func send(message: String, receiver: Array<String>): Unit {
        sendRich(message, renderHtml(message), [], receiver)
    }

    public func sendRich(message: String, html: String, attachments: Array<String>,
        receiver: Array<String>): Unit {
        let actual = if (receiver.isEmpty()) {
            defaultReceivers
        } else {
            receiver
        }
        if (actual.isEmpty()) {
            throw ProbeException(ProbeErrorCode.CONFIG, "email 渠道没有收件人")
        }
        let specs = ArrayList<MailAttachmentSpec>()
        for (path in attachments) {
            specs.add(MailAttachmentSpec(fileName(path), mediaType(path), path))
        }
        transport.send(OutgoingMail(sender, actual, subjectOf(message), message, html, specs.toArray()))
    }

    public func receive(): String {
        for (mail in transport.list(receiveLimit)) {
            if (mail.unread) {
                let body = if (!mail.text.isEmpty()) {
                    mail.text
                } else {
                    mail.html
                }
                let message = ChannelMessage(mail.id, mail.from, mail.subject, body)
                return JsonValue.from(message.toData()).toString()
            }
        }
        ""
    }

    public func replyConf(): String {
        "probe_channel_email_replyAccount"
    }

    private func subjectOf(message: String): String {
        var title = ""
        var node = ""
        for (line in message.split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.isEmpty()) {
                continue
            }
            if (title.isEmpty()) {
                title = trimmed
            }
            let parts = trimmed.split("节点:")
            if (parts.size == 2) {
                node = parts[1].trimAscii()
            }
        }
        let core = if (node.isEmpty()) {
            title
        } else {
            "${node} ${title}"
        }
        let prefix = subjectPrefix.trimAscii()
        if (prefix.isEmpty()) {
            core
        } else {
            "${prefix} ${core}".trimAscii()
        }
    }

    /**
     * 把渠道消息渲染成 HTML。
     *
     * 第一行是横幅标题；之后的 `key: value` 行变成表格。恢复事件用绿色横幅，
     * 其它事件用红色，保证邮件客户端不渲染样式时纯文本仍然可读。
     */
    private func renderHtml(message: String): String {
        let lines = message.split("\n")
        var title = ""
        var banner = "#c0392b"
        let rows = ArrayList<(String, String)>()
        var index = 0
        while (index < lines.size) {
            let line = lines[index].trimAscii()
            if (!line.isEmpty()) {
                if (title.isEmpty()) {
                    title = line
                    if (title.startsWith("【已恢复】")) {
                        banner = "#27ae60"
                    }
                } else {
                    let colon = match (line.indexOf(':')) {
                        case Some(value) => value
                        case None => -1
                    }
                    if (colon > 0) {
                        let key = line[0..colon].trimAscii()
                        let value = line[colon + 1..].trimAscii()
                        rows.add((key, value))
                    }
                }
            }
            index += 1
        }

        var html = "<html><body style=\"font-family:Arial,sans-serif;color:#222\">"
        html += "<div style=\"background:${banner};color:#ffffff;padding:16px;font-size:18px;font-weight:bold\">" +
            escapeHtml(title) + "</div>"
        if (rows.isEmpty()) {
            html += "<pre>" + escapeHtml(message) + "</pre>"
        } else {
            html += "<table border=\"0\" cellpadding=\"6\" cellspacing=\"0\" " +
                "style=\"border-collapse:collapse;margin-top:12px\">"
            for ((key, value) in rows) {
                html += "<tr><td style=\"border:1px solid #dddddd;background:#f5f5f5;" +
                    "font-weight:bold\">" + escapeHtml(key) + "</td>"
                html += "<td style=\"border:1px solid #dddddd\">" + escapeHtml(value) + "</td></tr>"
            }
            html += "</table>"
        }
        html += "</body></html>"
        html
    }

    private func fileName(path: String): String {
        match (path.lastIndexOf('/')) {
            case Some(index) => path[index + 1..]
            case None => path
        }
    }

    private func mediaType(path: String): String {
        if (path.toAsciiLower().endsWith(".svg")) {
            "image/svg+xml"
        } else {
            "application/octet-stream"
        }
    }

    private func escapeHtml(value: String): String {
        var result = value.replace("&", "&amp;")
        result = result.replace("<", "&lt;")
        result = result.replace(">", "&gt;")
        result = result.replace("\"", "&quot;")
        result
    }
}
