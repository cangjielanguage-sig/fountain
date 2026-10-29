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
import std.io.OutputStream
import std.random.Random
import fountain::f_email.mime.{MimeWriter, MimeWriteOptions}
import fountain::f_email.model.*
import fountain::f_email.transport.*

/** DSN 的退信内容级别。 */
public enum DsnReturn <: ToString {
    | Full
    | Headers

    public func toString(): String {
        match (this) {
            case Full => "FULL"
            case Headers => "HDRS"
        }
    }
}

/** DSN 通知时机。 */
public enum DsnNotify <: ToString {
    | Success
    | Failure
    | Delay
    | Never

    public func toString(): String {
        match (this) {
            case Success => "SUCCESS"
            case Failure => "FAILURE"
            case Delay => "DELAY"
            case Never => "NEVER"
        }
    }
}

/**
 * SMTP 客户端。
 *
 * `build()` 内完成连接、EHLO、STARTTLS、AUTH，因此返回后 `capabilities` 立即可用，
 * 配置错误在启动期暴露；`send()` 只做事务，不重新握手，也**不自动重连**。
 */
public class SmtpClient <: Resource {
    private let connection: MailConnection
    private let timeouts: MailTimeouts
    private let helloName: String
    private let capabilitiesValue: SmtpCapabilities
    private let authMechanismValue: ?SmtpAuthMechanism
    private let authUser: ?String
    private let authSecret: ?Secret
    private let policy: SendPolicy
    private let maxMessageBytes: Int64
    private let precompute: Bool
    private let dsnReturn: ?DsnReturn
    private let dsnNotify: Array<DsnNotify>
    private var channelRef: LineChannel

    init(
        connection: MailConnection,
        channel: LineChannel,
        timeouts: MailTimeouts,
        helloName: String,
        capabilities: SmtpCapabilities,
        authMechanism: ?SmtpAuthMechanism,
        authUser: ?String,
        authSecret: ?Secret,
        policy: SendPolicy,
        maxMessageBytes: Int64,
        precompute: Bool,
        dsnReturn: ?DsnReturn,
        dsnNotify: Array<DsnNotify>
    ) {
        this.connection = connection
        this.channelRef = channel
        this.timeouts = timeouts
        this.helloName = helloName
        this.capabilitiesValue = capabilities
        this.authMechanismValue = authMechanism
        this.authUser = authUser
        this.authSecret = authSecret
        this.policy = policy
        this.maxMessageBytes = maxMessageBytes
        this.precompute = precompute
        this.dsnReturn = dsnReturn
        this.dsnNotify = dsnNotify
    }

    public static func builder(host: String, port!: UInt16 = 587): SmtpClientBuilder {
        SmtpClientBuilder(host, port)
    }

    public prop capabilities: SmtpCapabilities {
        get() {
            capabilitiesValue
        }
    }

    public func send(message: MailMessage): SendReport {
        send(Envelope.fromMessage(message), message)
    }

    public func send(envelope: Envelope, message: MailMessage): SendReport {
        if (isClosed()) {
            throw MailIoException(IoStage.Write, "client is closed")
        }
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        let prepared = prepare(envelope, message)
        let plaintextAddress = hasNonAsciiAddress(envelope)
        if (plaintextAddress && !capabilitiesValue.supportsSmtpUtf8) {
            throw MailProtocolException("信封地址含非 ASCII，但服务器未广告 SMTPUTF8")
        }

        var sizeArg = ""
        if (prepared.sizeKnown) {
            if (maxMessageBytes > 0 && prepared.size > maxMessageBytes) {
                throw MailLimitException(LimitKind.Size, maxMessageBytes, prepared.size)
            }
            if (let Some(limit) <- capabilitiesValue.size) {
                if (limit > 0 && prepared.size > limit) {
                    throw MailLimitException(LimitKind.Size, limit, prepared.size)
                }
            }
            if (prepared.sizeKnown && (precompute || maxMessageBytes > 0)) {
                sizeArg = " SIZE=${prepared.size}"
            }
        }

        let mailFrom = buildMailFrom(envelope.from, sizeArg, plaintextAddress)
        let rcptCommands = ArrayList<String>()
        for (recipient in envelope.recipients) {
            rcptCommands.add(buildRcpt(recipient))
        }

        if (policy.toString() == "BestEffort" && capabilitiesValue.supportsPipelining) {
            return transactPipelined(channel, prepared, mailFrom, rcptCommands)
        }
        return transactSequential(channel, prepared, mailFrom, rcptCommands)
    }

    public func noop(): SmtpReply {
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.writeLine("NOOP")
        SmtpReply.read(channel)
    }

    public func reset(): Unit {
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.writeLine("RSET")
        SmtpReply.read(channel)
    }

    public func close(): Unit {
        if (isClosed()) {
            return
        }
        try {
            channelRef.withDeadline(timeouts.command)
            channelRef.writeLine("QUIT")
            SmtpReply.read(channelRef)
        } catch (_: Exception) {}
        connection.close()
    }

    public func isClosed(): Bool {
        connection.isClosed()
    }

    // ---------- 事务 ----------

    private func transactSequential(
        channel: LineChannel,
        prepared: PreparedMessage,
        mailFrom: String,
        rcptCommands: ArrayList<String>
    ): SendReport {
        channel.writeLine(mailFrom)
        let mailReply = SmtpReply.read(channel)
        abortIf421(mailReply)
        if (!mailReply.isSuccess()) {
            return failAll(prepared, rcptCommands, mailReply)
        }
        let accepted = ArrayList<RecipientStatus>()
        let rejected = ArrayList<RecipientStatus>()
        for (command in rcptCommands) {
            channel.writeLine(command)
            let reply = SmtpReply.read(channel)
            abortIf421(reply)
            handleRcpt(reply, command, accepted, rejected)
        }
        return finishTransaction(channel, prepared, accepted, rejected)
    }

    private func transactPipelined(
        channel: LineChannel,
        prepared: PreparedMessage,
        mailFrom: String,
        rcptCommands: ArrayList<String>
    ): SendReport {
        channel.writeLine(mailFrom)
        for (command in rcptCommands) {
            channel.writeLine(command)
        }
        channel.writeLine("DATA")
        channel.flush()

        let mailReply = SmtpReply.read(channel)
        abortIf421(mailReply)
        if (!mailReply.isSuccess()) {
            // 按序把剩余回复读掉，避免流错位
            for (_ in 0..rcptCommands.size) {
                SmtpReply.read(channel)
            }
            SmtpReply.read(channel)
            return failAll(prepared, rcptCommands, mailReply)
        }
        let accepted = ArrayList<RecipientStatus>()
        let rejected = ArrayList<RecipientStatus>()
        var index = 0
        for (command in rcptCommands) {
            let reply = SmtpReply.read(channel)
            abortIf421(reply)
            handleRcpt(reply, command, accepted, rejected)
            index += 1
        }
        let dataReply = SmtpReply.read(channel)
        abortIf421(dataReply)
        if (!dataReply.isIntermediate()) {
            sendReset(channel)
            return SendReport(
                prepared.messageId,
                accepted: accepted.toArray(),
                rejected: rejected.toArray(),
                reply: dataReply
            )
        }
        if (accepted.size == 0) {
            // 服务器不合规地给了 354：只能结束空事务再 RSET，绝不能在此状态发 RSET
            channel.writeLine(".")
            SmtpReply.read(channel)
            sendReset(channel)
            return SendReport(
                prepared.messageId,
                rejected: rejected.toArray(),
                reply: dataReply
            )
        }
        return writeData(channel, prepared, accepted, rejected)
    }

    private func finishTransaction(
        channel: LineChannel,
        prepared: PreparedMessage,
        accepted: ArrayList<RecipientStatus>,
        rejected: ArrayList<RecipientStatus>
    ): SendReport {
        if (policy.toString() == "AllOrNothing" && rejected.size > 0) {
            sendReset(channel)
            let all = ArrayList<RecipientStatus>()
            for (status in accepted) {
                all.add(RecipientStatus(status.address, 0, text: "aborted by AllOrNothing"))
            }
            for (status in rejected) {
                all.add(status)
            }
            return SendReport(
                prepared.messageId,
                rejected: all.toArray(),
                reply: SmtpReply(554, ["aborted"]),
                aborted: true
            )
        }
        if (accepted.size == 0) {
            sendReset(channel)
            return SendReport(
                prepared.messageId,
                rejected: rejected.toArray(),
                reply: SmtpReply(rejected[0].code, [rejected[0].text])
            )
        }
        channel.writeLine("DATA")
        let dataReply = SmtpReply.read(channel)
        abortIf421(dataReply)
        if (!dataReply.isIntermediate()) {
            sendReset(channel)
            return SendReport(
                prepared.messageId,
                accepted: accepted.toArray(),
                rejected: rejected.toArray(),
                reply: dataReply
            )
        }
        return writeData(channel, prepared, accepted, rejected)
    }

    private func writeData(
        channel: LineChannel,
        prepared: PreparedMessage,
        accepted: ArrayList<RecipientStatus>,
        rejected: ArrayList<RecipientStatus>
    ): SendReport {
        channel.withDeadline(timeouts.data)
        let stuffer = DotStuffWriter(channel)
        let writer = MimeWriter(stuffer, options: prepared.writeOptions)
        writer.write(prepared.message)
        stuffer.finish()
        channel.flush()
        let finalReply = SmtpReply.read(channel)
        abortIf421(finalReply)
        if (!finalReply.isSuccess()) {
            // 拿到整封邮件的最终回复就算事务结束；是否成功看 report
            return SendReport(
                prepared.messageId,
                accepted: accepted.toArray(),
                rejected: rejected.toArray(),
                reply: finalReply
            )
        }
        return SendReport(
            prepared.messageId,
            accepted: accepted.toArray(),
            rejected: rejected.toArray(),
            reply: finalReply
        )
    }

    /** RFC 5321：421 表示服务关闭传输通道，当前事务不能再继续。 */
    private func abortIf421(reply: SmtpReply): Unit {
        if (reply.code == 421) {
            connection.close()
            throw MailIoException(IoStage.Read, "SMTP 421 服务关闭传输通道：${lastLine(reply)}")
        }
    }

    private func handleRcpt(
        reply: SmtpReply,
        command: String,
        accepted: ArrayList<RecipientStatus>,
        rejected: ArrayList<RecipientStatus>
    ): Unit {
        let address = extractAddress(command)
        let status = RecipientStatus(
            address,
            reply.code,
            enhanced: reply.enhanced,
            text: lastLine(reply),
            accepted: reply.isSuccess()
        )
        if (reply.isSuccess()) {
            accepted.add(status)
        } else {
            rejected.add(status)
        }
    }

    private func failAll(
        prepared: PreparedMessage,
        rcptCommands: ArrayList<String>,
        reply: SmtpReply
    ): SendReport {
        let rejected = ArrayList<RecipientStatus>()
        for (command in rcptCommands) {
            rejected.add(
                RecipientStatus(
                    extractAddress(command),
                    reply.code,
                    enhanced: reply.enhanced,
                    text: lastLine(reply)
                )
            )
        }
        SendReport(prepared.messageId, rejected: rejected.toArray(), reply: reply)
    }

    private func sendReset(channel: LineChannel): Unit {
        try {
            channel.writeLine("RSET")
            SmtpReply.read(channel)
        } catch (_: Exception) {}
    }

    // ---------- 报文准备 ----------

    private func prepare(envelope: Envelope, message: MailMessage): PreparedMessage {
        if (envelope.from.size == 0) {
            throw MailProtocolException("邮件缺少 From，无法投递")
        }
        let copy = autoHeaders(message, envelope)
        let use8Bit = capabilitiesValue.supports8BitMime
        let options = MimeWriteOptions(
            allow8Bit: use8Bit,
            utf8Headers: hasNonAsciiAddress(envelope)
        )
        if (precompute || maxMessageBytes > 0) {
            let counter = CountingSink()
            MimeWriter(counter, options: options).write(copy)
            return PreparedMessage(copy, options, copy.headers.get("Message-ID") ?? "", counter.size, true)
        }
        PreparedMessage(copy, options, copy.headers.get("Message-ID") ?? "", -1, false)
    }

    /** 复制 headers（去 Bcc、补 Date/Message-ID/MIME-Version），**不修改调用方的 message**。 */
    private func autoHeaders(message: MailMessage, envelope: Envelope): MailMessage {
        let headers = HeaderMap()
        for ((name, value) in message.headers.entries()) {
            if (name.toAsciiLower() != "bcc") {
                headers.add(name, value)
            }
        }
        if (!headers.contains("Date")) {
            headers.set("Date", MailDate.now().toString())
        }
        if (!headers.contains("Message-ID")) {
            let domain = domainOf(envelope.from)
            headers.set("Message-ID", "<${uniqueToken()}@${domain}>")
        }
        if (!headers.contains("MIME-Version")) {
            headers.set("MIME-Version", "1.0")
        }
        MailMessage(MimePart(headers: headers, body: message.root.body))
    }

    private func domainOf(address: String): String {
        let at = address.lastIndexOf("@") ?? -1
        if (at >= 0 && at + 1 < address.size) {
            return address[(at + 1)..]
        }
        "localhost"
    }

    private func uniqueToken(): String {
        Random().nextUInt64().toString()
    }

    // ---------- 命令拼装 ----------

    private func buildMailFrom(from: String, sizeArg: String, smtpUtf8: Bool): String {
        var command = "MAIL FROM:<${from}>"
        if (let Some(ret) <- dsnReturn) {
            if (capabilitiesValue.supportsDsn) {
                command = command + " RET=${ret.toString()}"
            }
        }
        if (sizeArg.size > 0) {
            command = command + sizeArg
        }
        if (capabilitiesValue.supports8BitMime) {
            command = command + " BODY=8BITMIME"
        }
        if (smtpUtf8) {
            command = command + " SMTPUTF8"
        }
        command
    }

    private func buildRcpt(address: String): String {
        var command = "RCPT TO:<${address}>"
        if (dsnNotify.size > 0 && capabilitiesValue.supportsDsn) {
            command = command + " NOTIFY=${notifyList()}"
        }
        command
    }

    private func notifyList(): String {
        var out = ""
        var first = true
        for (item in dsnNotify) {
            if (!first) {
                out = out + ","
            }
            out = out + item.toString()
            first = false
        }
        out
    }

    private func lastLine(reply: SmtpReply): String {
        if (reply.lines.size == 0) {
            return ""
        }
        reply.lines[reply.lines.size - 1]
    }

    private func extractAddress(command: String): String {
        let lt = command.indexOf("<") ?? -1
        let gt = command.lastIndexOf(">") ?? -1
        if (lt >= 0 && gt > lt) {
            return command[(lt + 1)..gt]
        }
        command
    }

    private func hasNonAsciiAddress(envelope: Envelope): Bool {
        if (hasNonAscii(envelope.from)) {
            return true
        }
        for (recipient in envelope.recipients) {
            if (hasNonAscii(recipient)) {
                return true
            }
        }
        false
    }

    private func hasNonAscii(text: String): Bool {
        for (b in text.toArray()) {
            if (b > 126) {
                return true
            }
        }
        false
    }
}

private class PreparedMessage {
    let message: MailMessage
    let writeOptions: MimeWriteOptions
    let messageId: String
    let size: Int64
    let sizeKnown: Bool

    init(message: MailMessage, options: MimeWriteOptions, messageId: String, size: Int64, sizeKnown: Bool) {
        this.message = message
        this.writeOptions = options
        this.messageId = messageId
        this.size = size
        this.sizeKnown = sizeKnown
    }
}

/** 只数字节、不落盘的 sink（`SIZE=` 预计算）。 */
class CountingSink <: OutputStream {
    var size: Int64 = 0

    public func write(buffer: Array<Byte>): Unit {
        size += buffer.size
    }
}
