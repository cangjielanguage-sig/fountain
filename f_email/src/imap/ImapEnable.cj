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
import fountain::f_email.model.MailProtocolException

/**
 * `ENABLE`（RFC 5161）。
 *
 * 这一层是 M4 的闸门：`CAPABILITY` 只说明"能做什么"，`ENABLE` 的 `* ENABLED`
 * 回显才说明"已经生效什么"。**只有回显过的能力才置位**——这是防止"客户端以为开了
 * QRESYNC、服务器实际只发 EXPUNGE"的唯一屏障。
 *
 * 服务器回 `BAD`/`NO` 不算致命：对应能力保持"未启用"，后续调用该扩展时
 * 由 [ImapClient] 抛 `MailProtocolException(capability=…)`。
 */
public class ImapEnable {
    private let client: ImapClient

    public init(client: ImapClient) {
        this.client = client
    }

    /**
     * `ENABLE <cap>…`，返回**服务器回显**的启用列表。
     *
     * 未认证时本地直接拒绝，不浪费一次往返（RFC 5161 要求 ENABLE 只能在已认证状态发）。
     */
    public func enable(capabilities: Array<String>): Array<String> {
        if (!client.isAuthenticated) {
            throw MailProtocolException("ENABLE 需要先登录")
        }
        client.requireCapability("ENABLE")
        if (capabilities.size == 0) {
            return client.enabledCapabilities
        }
        var command = "ENABLE"
        for (capability in capabilities) {
            command = command + " " + capability.toAsciiUpper()
        }
        let result = client.execute(command)
        let enabled = ArrayList<String>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "ENABLED") {
                for (value in untagged.values) {
                    let text = value.text().toAsciiUpper()
                    if (text.size > 0) {
                        enabled.add(text)
                        client.setEnabled(text)
                    }
                }
            }
        }
        // `BAD`/`NO` 不抛：能力保持未启用，由调用方按 [isEnabled] 判断
        enabled.toArray()
    }

    /** 启用 `UTF8=ACCEPT`；返回是否真的生效。 */
    public func enableUtf8Accept(): Bool {
        enable(["UTF8=ACCEPT"])
        client.isEnabled("UTF8=ACCEPT")
    }

    /**
     * 启用 `QRESYNC`。
     *
     * `QRESYNC` 蕴含 `CONDSTORE`，两个一起 `ENABLE` 会让部分服务器回 `BAD`，
     * 因此这里只发 `QRESYNC`。
     */
    public func enableQResync(): Bool {
        enable(["QRESYNC"])
        client.isEnabled("QRESYNC")
    }

    public func enableCondStore(): Bool {
        enable(["CONDSTORE"])
        client.isEnabled("CONDSTORE")
    }
}
