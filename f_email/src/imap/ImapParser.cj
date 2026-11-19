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
import fountain::f_email.model.{LimitKind, MailLimitException, MailProtocolException}

/**
 * IMAP 响应行的 token 化。
 *
 * 只做词法，不解释语义：`* 3 FETCH (UID 9 FLAGS (\Seen))` 变成
 * `[Atom("*"), Number(3), Atom("FETCH"), List([...])]`。
 *
 * 两个容易写错的地方：
 *
 * 1. 响应键可以带方括号并且**括号里有空格**（`BODY[HEADER.FIELDS (FROM TO)]`），
 *    按空白切词会把它切成三个 token，所以读 atom 时要一路吃到匹配的 `]`；
 * 2. `{n}` 只是长度标记，字面量字节在 CRLF 之后，必须留给调用方去读。
 */
public class ImapParser {
    /** 列表嵌套上限；超过按协议层错误处理，避免恶意响应把栈打穿。 */
    public static let MAX_DEPTH: Int64 = 64
    /** 单行上限（RFC 3501 要求客户端至少支持 8000 字节）。 */
    public static let MAX_LINE: Int64 = 8192

    public static func parse(line: String): Array<ImapValue> {
        let bytes = line.toArray()
        if (bytes.size > MAX_LINE) {
            throw MailLimitException(LimitKind.Line, MAX_LINE, bytes.size)
        }
        let tokens = ArrayList<ImapValue>()
        var index = 0
        while (index < bytes.size) {
            // 跳过空白
            while (index < bytes.size && (bytes[index] == b' ' || bytes[index] == b'\t')) {
                index += 1
            }
            if (index >= bytes.size) {
                break
            }
            let parsed = parseOne(bytes, index, 1)
            tokens.add(parsed.value)
            index = parsed.next
        }
        tokens.toArray()
    }

    private static func parseOne(bytes: Array<Byte>, start: Int64, depth: Int64): ParsedToken {
        if (depth > MAX_DEPTH) {
            throw MailLimitException(LimitKind.Depth, MAX_DEPTH, depth)
        }
        let first = bytes[start]
        match (first) {
            case b'(' =>
                let values = ArrayList<ImapValue>()
                var index = start + 1
                while (true) {
                    while (index < bytes.size && (bytes[index] == b' ' || bytes[index] == b'\t')) {
                        index += 1
                    }
                    if (index >= bytes.size) {
                        throw MailProtocolException("IMAP 列表没有闭合的右括号")
                    }
                    if (bytes[index] == b')') {
                        return ParsedToken(List(values.toArray()), index + 1)
                    }
                    let inner = parseOne(bytes, index, depth + 1)
                    values.add(inner.value)
                    index = inner.next
                }
                ParsedToken(Nil, index)
            case b')' => throw MailProtocolException("IMAP 响应出现多余的右括号")
            case b'"' =>
                let (value, next) = parseQuoted(bytes, start + 1)
                ParsedToken(Quoted(value), next)
            case b'{' =>
                let (value, next) = parseLiteral(bytes, start + 1)
                ParsedToken(value, next)
            case _ =>
                let (value, next) = parseAtom(bytes, start)
                ParsedToken(value, next)
        }
    }

    private static func parseQuoted(bytes: Array<Byte>, from: Int64): (String, Int64) {
        let text = ArrayList<Byte>()
        var index = from
        while (index < bytes.size) {
            let b = bytes[index]
            if (b == b'\\') {
                if (index + 1 >= bytes.size) {
                    throw MailProtocolException("IMAP 引号字符串以反斜杠结尾")
                }
                text.add(bytes[index + 1])
                index += 2
                continue
            }
            if (b == b'"') {
                return (String.fromUtf8(text.toArray()), index + 1)
            }
            text.add(b)
            index += 1
        }
        throw MailProtocolException("IMAP 引号字符串没有闭合")
    }

    private static func parseLiteral(bytes: Array<Byte>, from: Int64): (ImapValue, Int64) {
        var index = from
        var value: Int64 = 0
        var digits = 0
        while (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') {
            value = value * 10 + Int64(bytes[index] - b'0')
            index += 1
            digits += 1
        }
        if (digits == 0) {
            throw MailProtocolException("IMAP literal 长度不是数字")
        }
        var plus = false
        if (index < bytes.size && bytes[index] == b'+') {
            plus = true
            index += 1
        }
        if (index >= bytes.size || bytes[index] != b'}') {
            throw MailProtocolException("IMAP literal 长度标记没有闭合")
        }
        let token = if (plus) {
            ImapValue.LiteralPlus(value)
        } else {
            ImapValue.Literal(value)
        }
        (token, index + 1)
    }

    /**
     * atom：一直读到空白或结构的边界。
     *
     * `[` 之后的所有内容（含空格与括号）都属于同一个 atom，直到匹配的 `]`——
     * 这就是 `BODY[HEADER.FIELDS (FROM TO)]` 能被当作一个 token 的原因。
     */
    private static func parseAtom(bytes: Array<Byte>, from: Int64): (ImapValue, Int64) {
        let text = ArrayList<Byte>()
        var index = from
        var bracketDepth: Int64 = 0
        while (index < bytes.size) {
            let b = bytes[index]
            if (bracketDepth == 0) {
                if (b == b' ' || b == b'\t' || b == b'(' || b == b')' || b == b'"') {
                    break
                }
                if (b == b'[') {
                    bracketDepth = 1
                }
            } else {
                if (b == b'[') {
                    bracketDepth += 1
                } else if (b == b']') {
                    bracketDepth -= 1
                }
            }
            text.add(b)
            index += 1
        }
        let value = String.fromUtf8(text.toArray())
        if (value.toAsciiUpper() == "NIL") {
            return (ImapValue.Nil, index)
        }
        if (let Some(number) <- parseNumber(value)) {
            return (ImapValue.Number(number), index)
        }
        (ImapValue.Atom(value), index)
    }

    // ---------- 生成侧 ----------

    public static func parseNumber(text: String): ?Int64 {
        if (text.size == 0) {
            return None
        }
        var value: Int64 = 0
        for (b in text.toArray()) {
            if (b < b'0' || b > b'9') {
                return None
            }
            value = value * 10 + Int64(b - b'0')
        }
        Some(value)
    }

    /** 加引号并转义 `\` 与 `"`；按字节处理，UTF-8 多字节字符原样保留。 */
    public static func quoted(value: String): String {
        let out = ArrayList<Byte>()
        out.add(b'"')
        for (b in value.toArray()) {
            if (b == b'\\' || b == b'"') {
                out.add(b'\\')
            }
            out.add(b)
        }
        out.add(b'"')
        String.fromUtf8(out.toArray())
    }

    /** atom 是否可以不加引号直接写。 */
    public static func isSafeAtom(value: String): Bool {
        if (value.size == 0) {
            return false
        }
        for (b in value.toArray()) {
            if (b <= 32 || b >= 127) {
                return false
            }
            if (b == b'(' || b == b')' || b == b'{' || b == b'%' || b == b'*' ||
                b == b'"' || b == b'\\' || b == b']' || b == b'[') {
                return false
            }
        }
        true
    }

    /** 字符串参数：安全 atom 直接发，否则加引号。 */
    public static func param(value: String): String {
        if (isSafeAtom(value)) {
            return value
        }
        quoted(value)
    }

}

struct ParsedToken {
    let value: ImapValue
    let next: Int64

    init(value: ImapValue, next: Int64) {
        this.value = value
        this.next = next
    }
}
