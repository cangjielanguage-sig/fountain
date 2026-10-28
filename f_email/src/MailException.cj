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
package fountain::f_email

/**
 * 邮件模块的异常根类型。
 *
 * 所有失败都能落到这里；子类按"失败发生在哪一层"划分，调用方可以只 catch 需要的层级：
 *
 * - [MailIoException]：网络 / 超时 / EOF
 * - [MailProtocolException]：服务器回复不符合协议、命令注入被拒、连接已关闭
 * - [MailAuthException]：认证被拒
 * - [MailLimitException]：头部 / 行 / part / 深度 / 正文 / literal 超限
 * - [MimeException]：MIME 结构损坏或生成参数冲突
 * - [MailTlsException]：TLS 握手与证书校验
 */
public open class MailException <: Exception {
    public init(message: String) {
        super(message)
    }

    public init(message: String, causedBy: Exception) {
        super(message, causedBy)
    }
}

/** IO 失败发生的阶段。 */
public enum IoStage <: ToString {
    | Connect
    | Tls
    | Greeting
    | Read
    | Write
    | Timeout

    public func toString(): String {
        match (this) {
            case Connect => "Connect"
            case Tls => "Tls"
            case Greeting => "Greeting"
            case Read => "Read"
            case Write => "Write"
            case Timeout => "Timeout"
        }
    }
}

/** 触发上限的类别。 */
public enum LimitKind <: ToString {
    | Header
    | Line
    | Parts
    | Depth
    | Body
    | Literal
    | Size

    public func toString(): String {
        match (this) {
            case Header => "Header"
            case Line => "Line"
            case Parts => "Parts"
            case Depth => "Depth"
            case Body => "Body"
            case Literal => "Literal"
            case Size => "Size"
        }
    }
}

/**
 * 网络层失败。
 *
 * [stage] 为 [IoStage.Timeout] 时表示命令总超时（不是单次系统调用超时）；
 * 超时后连接必然已被关闭——流已经不可信，继续读只会把错误放大。
 */
public class MailIoException <: MailException {
    public let stage: IoStage

    public init(stage: IoStage, message: String) {
        super(message)
        this.stage = stage
    }

    public init(stage: IoStage, message: String, causedBy: Exception) {
        super(message, causedBy)
        this.stage = stage
    }
}

/**
 * 协议层失败：回复格式错误、命令被拒、连接已关闭、CRLF 注入被拒。
 *
 * [command] 在 `AUTH` / `PASS` / `LOGIN` 场景下已被替换为 `<redacted>`，
 * 因此可以直接进日志。
 */
public class MailProtocolException <: MailException {
    public let command: ?String
    public let reply: ?String
    /** 缺失的扩展能力名（`MOVE` / `CONDSTORE` / `THREAD=REFERENCES` 等），无则为 `None`。 */
    public let capability: ?String

    public init(message: String) {
        super(message)
        this.command = None
        this.reply = None
        this.capability = None
    }

    public init(message: String, command!: ?String, reply!: ?String) {
        super(message)
        this.command = command
        this.reply = reply
        this.capability = None
    }

    public init(message: String, capability!: ?String) {
        super(message)
        this.command = None
        this.reply = None
        this.capability = capability
    }
}

/**
 * 认证失败。
 *
 * 只保留机制名与状态码：challenge 与 response 可能含凭据派生值，不进异常消息。
 */
public class MailAuthException <: MailException {
    public let mechanism: String
    public let code: ?Int64

    public init(mechanism: String, code: ?Int64, message: String) {
        super(message)
        this.mechanism = mechanism
        this.code = code
    }
}

/** 超出配置上限。 */
public class MailLimitException <: MailException {
    public let kind: LimitKind
    public let limit: Int64
    public let actual: Int64

    public init(kind: LimitKind, limit: Int64, actual: Int64) {
        super("超出上限：${kind} 上限 ${limit}，实际 ${actual}")
        this.kind = kind
        this.limit = limit
        this.actual = actual
    }

    public init(kind: LimitKind, limit: Int64, actual: Int64, message: String) {
        super(message)
        this.kind = kind
        this.limit = limit
        this.actual = actual
    }
}

/**
 * MIME 结构损坏或生成参数冲突。
 *
 * [partPath] 形如 `1.2`，根 part 为空串；[offset] 是出错位置在正文里的字节偏移。
 */
public class MimeException <: MailException {
    public let partPath: ?String
    public let offset: ?Int64

    public init(message: String) {
        super(message)
        this.partPath = None
        this.offset = None
    }

    public init(message: String, partPath!: ?String, offset!: ?Int64) {
        super(message)
        this.partPath = partPath
        this.offset = offset
    }

    public init(message: String, causedBy: Exception) {
        super(message, causedBy)
        this.partPath = None
        this.offset = None
    }
}

/** TLS 握手或证书校验失败。可重试（证书问题除外，重试不会变好，但归类为网络层可重试）。 */
public class MailTlsException <: MailException {
    public init(message: String) {
        super(message)
    }

    public init(message: String, causedBy: Exception) {
        super(message, causedBy)
    }
}
