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

import fountain::f_email.model.{IoStage, MailAuthException, MailException, MailIoException, MailProtocolException, MailTlsException}

/** 投递策略。 */
public enum SendPolicy <: ToString {
    /** 至少一个收件人成功就发送（默认）。 */
    | BestEffort
    /** 任一收件人被拒则整封不发。 */
    | AllOrNothing

    public func toString(): String {
        match (this) {
            case BestEffort => "BestEffort"
            case AllOrNothing => "AllOrNothing"
        }
    }
}

/** 单个收件人的投递结果。 */
public struct RecipientStatus {
    public let address: String
    public let code: Int64
    public let enhanced: ?String
    public let text: String
    public let accepted: Bool

    public init(
        address: String,
        code: Int64,
        enhanced!: ?String = None,
        text!: String = "",
        accepted!: Bool = false
    ) {
        this.address = address
        this.code = code
        this.enhanced = enhanced
        this.text = text
        this.accepted = accepted
    }
}

/**
 * 一次投递的结果。
 *
 * `aborted=true` 表示 `AllOrNothing` 因部分拒收而**整封未发**：此时 `accepted` 为空，
 * `rejected` 包含全部收件人（原本通过的也在里面，`code=0`），调用方不会误以为"部分已发"。
 */
public struct SendReport {
    public let messageId: String
    public let accepted: Array<RecipientStatus>
    public let rejected: Array<RecipientStatus>
    public let reply: SmtpReply
    public let aborted: Bool

    public init(
        messageId: String,
        accepted!: Array<RecipientStatus> = [],
        rejected!: Array<RecipientStatus> = [],
        reply!: SmtpReply,
        aborted!: Bool = false
    ) {
        this.messageId = messageId
        this.accepted = accepted
        this.rejected = rejected
        this.reply = reply
        this.aborted = aborted
    }

    public func isCompleteSuccess(): Bool {
        !aborted && rejected.size == 0 && accepted.size > 0
    }

    /** 部分或全部收件人 4xx：调用方可以只重试被拒的那部分（自行去重）。 */
    public func isRetryable(): Bool {
        isRetryable(this)
    }
}

/** 回复或异常层面的可重试分类。 */
public func isRetryable(report: SendReport): Bool {
    if (report.aborted) {
        return false
    }
    if (report.rejected.size == 0) {
        return false
    }
    for (status in report.rejected) {
        if (status.code < 400 || status.code >= 500) {
            return false
        }
    }
    true
}

/**
 * 异常分类。
 *
 * 只有连接 / 超时 / TLS 与 4xx 增强码可重试；认证失败与 5xx 不可重试。
 * 客户端**不自动重试**——`250` 可能已在断网前到达服务器，库内重试等于重复投递。
 */
public func isRetryable(error: MailException): Bool {
    match (error as MailIoException) {
        case Some(io) => return io.stage.toString() == "Timeout"
        case None => ()
    }
    match (error as MailTlsException) {
        case Some(_) => return true
        case None => ()
    }
    match (error as MailAuthException) {
        case Some(_) => return false
        case None => ()
    }
    match (error as MailProtocolException) {
        case Some(_) => return false
        case None => ()
    }
    true
}
