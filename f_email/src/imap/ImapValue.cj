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

/**
 * IMAP 的一个 token。
 *
 * `Literal` 只记长度、不持有内容：literal 的字节在响应行之外（`{n}\r\n<字节>`），
 * 由 [ImapClient] 决定进内存、落 [Spool] 还是直接写 sink。
 * 把"解析"和"IO 决策"分开，才能在测试里只测解析、在生产里保证流式。
 */
public enum ImapValue <: ToString {
    | Nil
    | Atom(String)
    | Quoted(String)
    | Number(Int64)
    /** `{n}`：服务器在等 `+ OK`，客户端必须显式写出"继续"。 */
    | Literal(Int64)
    /** `{n+}`：`LITERAL+`，客户端不用等确认。 */
    | LiteralPlus(Int64)
    | List(Array<ImapValue>)

    /** 文本视图：atom / quoted 返回内容，number 返回十进制，其它返回空串。 */
    public func text(): String {
        match (this) {
            case Atom(value) => value
            case Quoted(value) => value
            case Number(value) => value.toString()
            case _ => ""
        }
    }

    public func isNil(): Bool {
        match (this) {
            case Nil => true
            case _ => false
        }
    }

    /** `(A B C)` 形式的列表；非列表返回空数组。 */
    public func items(): Array<ImapValue> {
        match (this) {
            case List(values) => values
            case _ => []
        }
    }

    public func number(): ?Int64 {
        match (this) {
            case Number(value) => Some(value)
            case Atom(value) => ImapParser.parseNumber(value)
            case _ => None<Int64>
        }
    }

    /** 重建成 IMAP 文本（用于断言与调试；literal 重建为长度标记）。 */
    public func toString(): String {
        match (this) {
            case Nil => "NIL"
            case Atom(value) => value
            case Quoted(value) => "\"${value}\""
            case Number(value) => value.toString()
            case Literal(length) => "{${length}}"
            case LiteralPlus(length) => "{${length}+}"
            case List(values) =>
                var out = "("
                var first = true
                for (value in values) {
                    if (!first) {
                        out = out + " "
                    }
                    out = out + value.toString()
                    first = false
                }
                out + ")"
        }
    }
}

/** 把 `Array<ImapValue>` 拼成空格分隔的文本，供日志与断言使用。 */
public func joinValues(values: Array<ImapValue>): String {
    var out = ""
    var first = true
    for (value in values) {
        if (!first) {
            out = out + " "
        }
        out = out + value.toString()
        first = false
    }
    out
}

