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

/** 一个待发送的附件。`path` 是本地文件路径，媒体类型由扩展名推断。 */
public class MailAttachmentSpec {
    public let filename: String
    public let mediaType: String
    public let path: String

    public init(filename: String, mediaType: String, path: String) {
        this.filename = filename
        this.mediaType = mediaType
        this.path = path
    }
}

/** 一封待发送邮件；与 `f_email` 解耦，便于用例注入假传输。 */
public class OutgoingMail {
    public let sender: String
    public let receivers: Array<String>
    public let subject: String
    public let text: String
    public let html: String
    public let attachments: Array<MailAttachmentSpec>

    public init(sender: String, receivers: Array<String>, subject: String, text: String, html: String,
        attachments: Array<MailAttachmentSpec>) {
        this.sender = sender
        this.receivers = receivers
        this.subject = subject
        this.text = text
        this.html = html
        this.attachments = attachments
    }
}

/** 收件箱里的一封邮件；`unread` 由 `\Seen` 标记推导，正文已按字符集解码。 */
public class ReceivedMail {
    public let id: String
    public let from: String
    public let subject: String
    public let unread: Bool
    public let text: String
    public let html: String

    public init(id: String, from: String, subject: String, unread: Bool, text: String, html: String) {
        this.id = id
        this.from = from
        this.subject = subject
        this.unread = unread
        this.text = text
        this.html = html
    }
}

/**
 * 邮件传输抽象。
 *
 * 生产实现基于 `f_email`；用例用假实现记录参数，不连接 SMTP / IMAP。
 */
public interface MailTransport {
    func send(mail: OutgoingMail): Unit

    /** 最近 [limit] 封邮件，最新在前；未读邮件的正文必须已填充。 */
    func list(limit: Int64): Array<ReceivedMail>
}
