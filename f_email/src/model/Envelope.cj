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

/**
 * SMTP 信封：反路径 + 收件人 addr-spec。
 *
 * 与邮件头不同，信封**只取 addr-spec**，不取显示名——`RCPT TO:<张三 <a@b>>` 是非法命令。
 * 反路径允许为空串（`<>`，退信场景）。
 */
public class Envelope {
    public let from: String
    public let recipients: Array<String>

    public init(from: String, recipients: Array<String>) {
        this.from = from
        this.recipients = recipients
    }

    /**
     * 从邮件头推导信封。
     *
     * 存在任意 `Resent-*` 字段时优先用 `Resent-From` / `Resent-To` / `Resent-Cc` / `Resent-Bcc`；
     * `From` 缺失或收件人全空时抛 [MailProtocolException]。
     */
    public static func fromMessage(message: MailMessage): Envelope {
        let headers = message.headers
        let resent = hasResent(headers)
        let fromHeader = if (resent) {
            "Resent-From"
        } else {
            "From"
        }
        let fromText = headers.get(fromHeader)
        if (fromText.isNone()) {
            throw MailProtocolException("邮件缺少 ${fromHeader}，无法构造信封")
        }
        let fromList = AddressList.parse(fromText.getOrThrow())
        if (fromList.isEmpty()) {
            throw MailProtocolException("${fromHeader} 无法解析出地址")
        }
        let from = fromList.toArray()[0].address

        let recipients = ArrayList<String>()
        let names = if (resent) {
            ["Resent-To", "Resent-Cc", "Resent-Bcc"]
        } else {
            ["To", "Cc", "Bcc"]
        }
        for (name in names) {
            if (let Some(raw) <- headers.get(name)) {
                for (address in AddressList.parse(raw)) {
                    recipients.add(address.address)
                }
            }
        }
        if (recipients.size == 0) {
            throw MailProtocolException("邮件没有任何收件人（To/Cc/Bcc 全空）")
        }
        Envelope(from, recipients.toArray())
    }

    private static func hasResent(headers: HeaderMap): Bool {
        for ((name, _) in headers.entries()) {
            if (name.toAsciiLower().startsWith("resent-")) {
                return true
            }
        }
        false
    }
}
