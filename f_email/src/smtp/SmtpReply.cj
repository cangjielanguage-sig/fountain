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
package fountain::f_email.smtp

import std.collection.ArrayList
import fountain::f_email.model.MailProtocolException
import fountain::f_email.transport.LineChannel

/**
 * SMTP 回复。
 *
 * 多行回复形如 `250-first` / `250-second` / `250 last`：**最后一行**的代码才是有效代码，
 * [lines] 保留去掉代码前缀后的原文。
 */
public struct SmtpReply {
    public let code: Int64
    public let lines: Array<String>
    /** 第一行里的 `2.x.x` / `4.x.x` / `5.x.x` 增强状态码。 */
    public let enhanced: ?String

    public init(code: Int64, lines: Array<String>, enhanced!: ?String = None) {
        this.code = code
        this.lines = lines
        this.enhanced = enhanced
    }

    public func isSuccess(): Bool {
        code >= 200 && code < 300
    }

    public func isIntermediate(): Bool {
        code >= 300 && code < 400
    }

    public func isTemporaryFailure(): Bool {
        code >= 400 && code < 500
    }

    public func isPermanentFailure(): Bool {
        code >= 500
    }

    /** 读取一条完整回复（含多行）。 */
    public static func read(channel: LineChannel): SmtpReply {
        let lines = ArrayList<String>()
        var code: Int64 = 0
        while (true) {
            let raw = channel.readLine()
            if (raw.isNone()) {
                throw MailProtocolException("服务器在回复中途断开连接")
            }
            let text = String.fromUtf8(raw.getOrThrow())
            if (text.size < 3) {
                throw MailProtocolException("SMTP 回复过短：${text}")
            }
            let parsed = parseInt(text[0..3])
            if (parsed.isNone()) {
                throw MailProtocolException("SMTP 回复代码不是数字：${text}")
            }
            code = parsed.getOrThrow()
            let rest = if (text.size > 4) {
                text[4..]
            } else if (text.size == 4) {
                ""
            } else {
                ""
            }
            lines.add(rest)
            if (text.size <= 3 || text[3] != b'-') {
                break
            }
        }
        let enhanced = extractEnhanced(lines.toArray())
        SmtpReply(code, lines.toArray(), enhanced: enhanced)
    }

    private static func parseInt(text: String): ?Int64 {
        var value: Int64 = 0
        for (b in text.toArray()) {
            if (b < b'0' || b > b'9') {
                return None
            }
            value = value * 10 + Int64(b - b'0')
        }
        Some(value)
    }

    private static func extractEnhanced(lines: Array<String>): ?String {
        for (line in lines) {
            let token = line.trimAscii().split(" ", removeEmpty: true)
            if (token.size == 0) {
                continue
            }
            let value = token[0]
            let first = value.indexOf(".") ?? -1
            if (first != 1) {
                continue
            }
            let rest = value[(first + 1)..]
            let second = rest.indexOf(".") ?? -1
            if (second <= 0 || second == rest.size - 1) {
                continue
            }
            return Some(value)
        }
        None<String>
    }
}
