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
 * 单个邮箱地址。
 *
 * 构造时做两道注入防线：`address` 里出现 `\r` / `\n` / `<` / `>` 直接抛异常——
 * 这是 SMTP 命令注入的主入口。废弃路由语法（`<@a,@b:user@host>`）解析时接受、生成时拒绝。
 */
public class EmailAddress <: ToString {
    private let addr: String
    private let displayName: ?String

    public init(address: String, name!: ?String = None) {
        validateAddress(address)
        this.addr = address.trimAscii()
        if (let Some(n) <- name) {
            this.displayName = if (n.trimAscii().size == 0) {
                None<String>
            } else {
                Some(n)
            }
        } else {
            this.displayName = None
        }
    }

    public static func parse(text: String): EmailAddress {
        parseMailbox(text)
    }

    /** 不含显示名与尖括号。 */
    public prop address: String {
        get() {
            addr
        }
    }

    /** 已解码的显示名。 */
    public prop name: ?String {
        get() {
            displayName
        }
    }

    public func toString(): String {
        if (let Some(n) <- displayName) {
            if (EncodedWord.needsEncoding(n)) {
                return "${EncodedWord.encode(n)} <${addr}>"
            }
            if (needsQuoting(n)) {
                return "\"${escape(n)}\" <${addr}>"
            }
            return "${n} <${addr}>"
        }
        addr
    }

    // ---------- 内部 ----------

    private static func needsQuoting(text: String): Bool {
        for (b in text.toArray()) {
            if (b == b'(' || b == b')' || b == b'<' || b == b'>' || b == b'[' ||
                b == b']' || b == b':' || b == b';' || b == b'@' || b == b',' ||
                b == b'.' || b == b'"' || b == b'\\' || b == b' ' || b == b'\t') {
                return true
            }
        }
        false
    }

    private static func escape(text: String): String {
        text.replace("\\", "\\\\").replace("\"", "\\\"")
    }

    static func validateAddress(address: String): Unit {
        if (address.trimAscii().size == 0) {
            throw MailProtocolException("邮箱地址不能为空")
        }
        for (b in address.toArray()) {
            if (b == b'\r' || b == b'\n' || b == b'<' || b == b'>') {
                throw MailProtocolException("邮箱地址含非法字符：${address}")
            }
        }
        if (address.trimAscii().startsWith("@")) {
            throw MailProtocolException("拒绝生成废弃路由语法：${address}")
        }
    }

    /** 解析一个 mailbox（不含列表分隔符）。 */
    static func parseMailbox(text: String): EmailAddress {
        let trimmed = text.trimAscii()
        let lt = lastIndexOfTopLevel(trimmed, r'<')
        if (lt >= 0) {
            let gt = trimmed.indexOf(">", lt) ?? -1
            if (gt < 0) {
                throw MailProtocolException("地址缺少 '>'：${text}")
            }
            var nameText = trimmed[0..lt].trimAscii()
            if (nameText.endsWith(",")) {
                nameText = nameText[0..(nameText.size - 1)].trimAscii()
            }
            let name = decodeDisplayName(nameText)
            let inside = stripRoute(trimmed[(lt + 1)..gt].trimAscii())
            return EmailAddress(inside, name: name)
        }
        // 无尖括号：addr-spec 可能带注释
        let comment = extractComment(trimmed)
        let bare = stripComments(trimmed).trimAscii()
        let name = if (let Some(c) <- comment) {
            Some(EncodedWord.decode(c))
        } else {
            None<String>
        }
        EmailAddress(stripRoute(bare), name: name)
    }

    private static func decodeDisplayName(text: String): ?String {
        if (text.size == 0) {
            return None<String>
        }
        if (text[0] == b'"' && text[text.size - 1] == b'"') {
            let inner = text[1..(text.size - 1)]
            return Some(EncodedWord.decode(inner.replace("\\\"", "\"").replace("\\\\", "\\")))
        }
        Some(EncodedWord.decode(stripComments(text).trimAscii()))
    }

    /** 废弃路由：`@a,@b:user@host` → `user@host`。 */
    private static func stripRoute(addr: String): String {
        if (addr.size == 0 || addr[0] != b'@') {
            return addr
        }
        let colon = addr.lastIndexOf(":") ?? -1
        if (colon >= 0) {
            return addr[(colon + 1)..].trimAscii()
        }
        addr
    }

    private static func lastIndexOfTopLevel(text: String, target: Rune): Int64 {
        let bytes = text.toArray()
        var inQuote = false
        var escaped = false
        var i = 0
        var found = -1
        while (i < bytes.size) {
            let b = bytes[i]
            if (escaped) {
                escaped = false
                i += 1
                continue
            }
            if (b == b'\\' && inQuote) {
                escaped = true
                i += 1
                continue
            }
            if (b == b'"') {
                inQuote = !inQuote
                i += 1
                continue
            }
            if (!inQuote && Rune(UInt32(b)) == target) {
                found = i
            }
            i += 1
        }
        found
    }

    static func stripComments(text: String): String {
        let out = StringBuilder()
        var depth = 0
        var escaped = false
        for (ch in text.toRuneArray()) {
            if (escaped) {
                escaped = false
                if (depth == 0) {
                    out.append(ch)
                }
                continue
            }
            if (ch == r'\\') {
                escaped = true
                if (depth == 0) {
                    out.append(ch)
                }
                continue
            }
            if (ch == r'(') {
                depth += 1
                continue
            }
            if (ch == r')') {
                if (depth > 0) {
                    depth -= 1
                }
                continue
            }
            if (depth == 0) {
                out.append(ch)
            }
        }
        out.toString()
    }

    static func extractComment(text: String): ?String {
        let start = text.indexOf("(") ?? -1
        if (start < 0) {
            return None<String>
        }
        let end = text.lastIndexOf(")") ?? -1
        if (end <= start) {
            return None<String>
        }
        Some(text[(start + 1)..end].trimAscii())
    }
}

/**
 * 地址列表。
 *
 * 支持逗号分隔与组语法（`Team: a@x, b@y;`），组名丢弃、成员展开成普通地址——
 * 组在 RFC 5322 里只是显示用的分类，不改变投递语义。
 */
public class AddressList <: Iterable<EmailAddress> & ToString {
    private let items = ArrayList<EmailAddress>()

    public init(addresses!: Array<EmailAddress> = []) {
        for (address in addresses) {
            items.add(address)
        }
    }

    public static func parse(text: String): AddressList {
        let list = AddressList()
        parseInto(text, list)
        list
    }

    public func add(address: EmailAddress): Unit {
        items.add(address)
    }

    public func add(text: String): Unit {
        items.add(EmailAddress.parse(text))
    }

    public func iterator(): Iterator<EmailAddress> {
        items.iterator()
    }

    public prop size: Int64 {
        get() {
            items.size
        }
    }

    public func isEmpty(): Bool {
        items.isEmpty()
    }

    public func toArray(): Array<EmailAddress> {
        items.toArray()
    }

    public func toString(): String {
        var out = ""
        var first = true
        for (item in items) {
            if (!first) {
                out = out + ", "
            }
            out = out + item.toString()
            first = false
        }
        out
    }

    private static func parseInto(text: String, list: AddressList): Unit {
        for (raw in splitTopLevel(text)) {
            let piece = raw.trimAscii()
            if (piece.size == 0) {
                continue
            }
            let colon = groupColon(piece)
            if (colon > 0) {
                var inner = piece[(colon + 1)..]
                if (inner.endsWith(";")) {
                    inner = inner[0..(inner.size - 1)]
                }
                parseInto(inner, list)
                continue
            }
            var mailbox = piece
            if (mailbox.endsWith(";")) {
                mailbox = mailbox[0..(mailbox.size - 1)].trimAscii()
            }
            if (mailbox.trimAscii().size == 0) {
                continue
            }
            list.add(EmailAddress.parseMailbox(mailbox))
        }
    }

    /** 组语法的 `:` 只出现在尖括号与引号之外；返回 -1 表示不是组。 */
    private static func groupColon(text: String): Int64 {
        var inQuote = false
        var inAngle = false
        var escaped = false
        let bytes = text.toArray()
        var i = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (escaped) {
                escaped = false
                i += 1
                continue
            }
            if (b == b'\\' && inQuote) {
                escaped = true
                i += 1
                continue
            }
            if (b == b'"') {
                inQuote = !inQuote
                i += 1
                continue
            }
            if (!inQuote) {
                if (b == b'<') {
                    inAngle = true
                } else if (b == b'>') {
                    inAngle = false
                } else if (b == b':' && !inAngle) {
                    return i
                } else if (b == b'@' && !inAngle) {
                    return -1
                }
            }
            i += 1
        }
        -1
    }

    /** 顶层分隔符：逗号与分号；引号、尖括号、注释内的不切。 */
    private static func splitTopLevel(text: String): Array<String> {
        let out = ArrayList<String>()
        var current = ""
        var inQuote = false
        var inAngle = false
        var depth = 0
        var escaped = false
        for (ch in text.toRuneArray()) {
            if (escaped) {
                current = current + String([ch])
                escaped = false
                continue
            }
            if (ch == r'\\' && inQuote) {
                current = current + String([ch])
                escaped = true
                continue
            }
            if (ch == r'"') {
                inQuote = !inQuote
                current = current + String([ch])
                continue
            }
            if (!inQuote) {
                if (ch == r'<') {
                    inAngle = true
                } else if (ch == r'>') {
                    inAngle = false
                } else if (ch == r'(') {
                    depth += 1
                } else if (ch == r')') {
                    if (depth > 0) {
                        depth -= 1
                    }
                }
            }
            if (!inQuote && !inAngle && depth == 0 && (ch == r',' || ch == r';')) {
                out.add(current)
                current = ""
                continue
            }
            current = current + String([ch])
        }
        out.add(current)
        out.toArray()
    }
}
