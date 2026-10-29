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
package fountain::f_email.pop3

import std.collection.ArrayList
import fountain::f_email.model.MailProtocolException
import fountain::f_email.transport.{DotUnstuffReader, LineChannel}

/**
 * `-ERR` 里方括号响应码的分类（RFC 3206 / RFC 2449）。
 *
 * 分类只影响调用方怎么处理，不改变"失败就是失败"：`[IN-USE]` 表示邮箱被别的会话占着，
 * 立刻重试只会继续失败；`[SYS/TEMP]` 才是"稍后可以再来"。
 */
public enum Pop3ErrorKind <: ToString {
    | Ok
    | Auth
    | SysTemp
    | SysPerm
    | InUse
    | Other

    public func toString(): String {
        match (this) {
            case Ok => "OK"
            case Auth => "AUTH"
            case SysTemp => "SYS/TEMP"
            case SysPerm => "SYS/PERM"
            case InUse => "IN-USE"
            case Other => "OTHER"
        }
    }
}

/**
 * 一条 POP3 状态行（`+OK` / `-ERR`）。
 *
 * 多行数据（`CAPA` / `LIST` / `UIDL` / `RETR` / `TOP`）不在这个结构里：它们由
 * [Pop3Client] 用 `DotUnstuffReader` 逐字节读，正文行可以任意长。
 */
public struct Pop3Reply {
    public let ok: Bool
    public let text: String
    /** `-ERR` 文本里的方括号码，例如 `AUTH` / `SYS/TEMP`；没有则为 `None`。 */
    public let errorCode: ?String

    public init(ok: Bool, text: String, errorCode!: ?String = None) {
        this.ok = ok
        this.text = text
        this.errorCode = errorCode
    }

    public func isOk(): Bool {
        ok
    }

    public func errorKind(): Pop3ErrorKind {
        match (errorCode) {
            case Some(code) =>
                let upper = code.toAsciiUpper()
                match (upper) {
                    case "AUTH" => Pop3ErrorKind.Auth
                    case "SYS/TEMP" => Pop3ErrorKind.SysTemp
                    case "SYS/PERM" => Pop3ErrorKind.SysPerm
                    case "IN-USE" => Pop3ErrorKind.InUse
                    case "LOGIN-DELAY" => Pop3ErrorKind.Auth
                    case _ => Pop3ErrorKind.Other
                }
            case None => if (ok) {
                Pop3ErrorKind.Ok
            } else {
                Pop3ErrorKind.Other
            }
        }
    }

    /** 读一条状态行；EOF 视为协议错误（服务器在事务中途断开）。 */
    public static func read(channel: LineChannel): Pop3Reply {
        let raw = channel.readLine()
        if (raw.isNone()) {
            throw MailProtocolException("POP3 服务器在回复中途断开连接")
        }
        parse(String.fromUtf8(raw.getOrThrow()))
    }

    public static func parse(line: String): Pop3Reply {
        let trimmed = line.trimAscii()
        if (trimmed.size >= 3 && trimmed[0..3] == "+OK") {
            Pop3Reply(true, trimmed[3..].trimAscii())
        } else if (trimmed.size >= 4 && trimmed[0..4] == "-ERR") {
            let text = trimmed[4..].trimAscii()
            Pop3Reply(false, text, errorCode: extractErrorCode(text))
        } else {
            throw MailProtocolException("POP3 状态行格式错误：${trimmed}")
        }
    }

    private static func extractErrorCode(text: String): ?String {
        if (!(text.size > 0 && text[0..1] == "[")) {
            return None
        }
        let close = text.indexOf("]") ?? -1
        if (close <= 1) {
            return None
        }
        Some(text[1..close])
    }
}

/** 多行数据的逐行读取：用 dot-unstuffing 状态机，正文行长度不受 `maxLine` 限制。 */
class Pop3Multiline {
    /**
     * 读取直到单独一行 `.`，返回去掉 CRLF 的原始字节块。
     *
     * 不按行返回的原因：`RETR` 的正文要原样交给 sink，多一次拼接就多一次全量拷贝。
     */
    static func readAll(channel: LineChannel): Array<Byte> {
        let reader = DotUnstuffReader(channel)
        let out = ArrayList<Byte>()
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let n = reader.read(buffer)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.add(buffer[i])
            }
        }
        // 预读过的字节必须退回，否则紧随其后的命令会读到正文的尾巴
        channel.pushBack(reader.unread())
        out.toArray()
    }

    /** 读多行数据并按 CRLF / 裸 LF 切成文本行（供 `CAPA` / `LIST` / `UIDL` 使用）。 */
    static func readLines(channel: LineChannel): Array<String> {
        splitLines(readAll(channel))
    }

    static func splitLines(bytes: Array<Byte>): Array<String> {
        let lines = ArrayList<String>()
        var start = 0
        var i = 0
        while (i < bytes.size) {
            if (bytes[i] == b'\n') {
                var end = i
                if (end > start && bytes[end - 1] == b'\r') {
                    end -= 1
                }
                lines.add(String.fromUtf8(slice(bytes, start, end)))
                start = i + 1
            }
            i += 1
        }
        if (start < bytes.size) {
            lines.add(String.fromUtf8(slice(bytes, start, bytes.size)))
        }
        lines.toArray()
    }

    private static func slice(bytes: Array<Byte>, from: Int64, to: Int64): Array<Byte> {
        let n = to - from
        let out = Array<Byte>(n, repeat: 0)
        for (i in 0..n) {
            out[i] = bytes[from + i]
        }
        out
    }
}
