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

/** 响应行的三类：带 tag 的完成回复、`*` 开头的非请求回复、`+` 继续请求。 */
public enum ImapResponseKind <: ToString {
    | Tagged
    | Untagged
    | Continuation

    public func toString(): String {
        match (this) {
            case Tagged => "Tagged"
            case Untagged => "Untagged"
            case Continuation => "Continuation"
        }
    }
}

/**
 * 一条 IMAP 响应。
 *
 * - tagged：`A0001 OK [READ-WRITE] SELECT completed` → `status=OK`、`code=READ-WRITE`
 * - untagged：`* 3 FETCH (...)` → `name=FETCH`、`values=[Number(3), List(...)]`
 * - continuation：`+ idling` → `text=idling`
 */
public struct ImapResponse {
    public let kind: ImapResponseKind
    public let tag: ?String
    public let status: ?String
    public let code: ?String
    public let codeArgs: Array<String>
    public let name: ?String
    public let values: Array<ImapValue>
    /** 去掉行结束符的原始行，便于排障与断言。 */
    public let raw: String

    public init(
        kind: ImapResponseKind,
        tag!: ?String = None,
        status!: ?String = None,
        code!: ?String = None,
        codeArgs!: Array<String> = [],
        name!: ?String = None,
        values!: Array<ImapValue> = [],
        raw!: String = ""
    ) {
        this.kind = kind
        this.tag = tag
        this.status = status
        this.code = code
        this.codeArgs = codeArgs
        this.name = name
        this.values = values
        this.raw = raw
    }

    public func isTagged(): Bool {
        kind.toString() == "Tagged"
    }

    public func isUntagged(): Bool {
        kind.toString() == "Untagged"
    }

    public func isContinuation(): Bool {
        kind.toString() == "Continuation"
    }

    public func isOk(): Bool {
        (status ?? "").toAsciiUpper() == "OK"
    }

    public func isNo(): Bool {
        (status ?? "").toAsciiUpper() == "NO"
    }

    public func isBad(): Bool {
        (status ?? "").toAsciiUpper() == "BAD"
    }

    public func isBye(): Bool {
        (status ?? "").toAsciiUpper() == "BYE"
    }

    /** 第一个 `Number` token（`* 3 EXISTS` 的 3）。 */
    public func numberOf(index!: Int64 = 0): ?Int64 {
        var seen: Int64 = 0
        for (value in values) {
            if (let Some(number) <- value.number()) {
                if (seen == index) {
                    return Some(number)
                }
                seen += 1
            }
        }
        None<Int64>
    }

    /** 第一个列表 token（`* 3 FETCH (...)` 的括号内容）。 */
    public func firstList(): Array<ImapValue> {
        for (value in values) {
            match (value) {
                case List(items) => return items
                case _ => ()
            }
        }
        []
    }

    public static func parse(line: String): ImapResponse {
        if (line.size > 0 && line[0..1] == "+") {
            return ImapResponse(ImapResponseKind.Continuation, values: [], raw: line)
        }
        let tokens = ImapParser.parse(line)
        if (tokens.size == 0) {
            throw MailProtocolException("空的 IMAP 响应行")
        }
        let head = tokens[0].text()
        if (head == "*") {
            return parseUntagged(tokens, line)
        }
        parseTagged(tokens, line)
    }

    private static func parseTagged(tokens: Array<ImapValue>, line: String): ImapResponse {
        if (tokens.size < 2) {
            throw MailProtocolException("IMAP 带 tag 响应缺少状态：${line}")
        }
        let status = tokens[1].text().toAsciiUpper()
        let rest = slice(tokens, 2)
        let (code, codeArgs) = extractCode(rest)
        ImapResponse(
            ImapResponseKind.Tagged,
            tag: Some(tokens[0].text()),
            status: Some(status),
            code: code,
            codeArgs: codeArgs,
            values: rest,
            raw: line
        )
    }

    private static func parseUntagged(tokens: Array<ImapValue>, line: String): ImapResponse {
        if (tokens.size < 2) {
            throw MailProtocolException("IMAP 非请求响应缺少内容：${line}")
        }
        // `* 3 EXISTS` / `* 3 FETCH (...)`：数字在前，响应名紧跟其后
        if (let Some(number) <- tokens[1].number()) {
            if (tokens.size >= 3 && tokens[2].text().size > 0) {
                let name = tokens[2].text().toAsciiUpper()
                let rest = ArrayList<ImapValue>()
                rest.add(ImapValue.Number(number))
                for (i in 3..tokens.size) {
                    rest.add(tokens[i])
                }
                return ImapResponse(
                    ImapResponseKind.Untagged,
                    name: Some(name),
                    values: rest.toArray(),
                    raw: line
                )
            }
        }
        let name = tokens[1].text().toAsciiUpper()
        let rest = slice(tokens, 2)
        let status = if (name == "OK" || name == "NO" || name == "BAD" || name == "BYE" || name == "PREAUTH") {
            Some(name)
        } else {
            None<String>
        }
        let (code, codeArgs) = extractCode(rest)
        ImapResponse(
            ImapResponseKind.Untagged,
            status: status,
            code: code,
            codeArgs: codeArgs,
            name: Some(name),
            values: rest,
            raw: line
        )
    }

    private static func extractCode(values: Array<ImapValue>): (?String, Array<String>) {
        if (values.size == 0) {
            return (None, [])
        }
        let text = values[0].text()
        if (text.size >= 2 && text[0..1] == "[") {
            let close = text.indexOf("]") ?? -1
            let inner = if (close > 0) {
                text[1..close]
            } else {
                text[1..]
            }
            let parts = inner.split(" ", removeEmpty: true)
            if (parts.size == 0) {
                return (None, [])
            }
            let args = ArrayList<String>()
            for (i in 1..parts.size) {
                args.add(parts[i])
            }
            return (Some(parts[0].toAsciiUpper()), args.toArray())
        }
        (None, [])
    }

    private static func slice(values: Array<ImapValue>, from: Int64): Array<ImapValue> {
        if (from >= values.size) {
            return []
        }
        let out = ArrayList<ImapValue>()
        for (i in from..values.size) {
            out.add(values[i])
        }
        out.toArray()
    }
}
