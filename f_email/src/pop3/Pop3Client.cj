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

import std.collection.{ArrayList, HashSet}
import std.io.OutputStream
import stdx.crypto.digest.MD5
import stdx.encoding.hex.toHexString
import stdx.net.tls.TlsClientConfig
import fountain::f_email.mime.{MimeParseOptions, MimeParser}
import fountain::f_email.model.*
import fountain::f_email.transport.*

/** `AUTH` 支持的 SASL 机制（RFC 5034）。 */
public enum Pop3AuthMechanism <: ToString {
    | Plain
    | Login

    public func toString(): String {
        match (this) {
            case Plain => "PLAIN"
            case Login => "LOGIN"
        }
    }
}

/** `STAT` 的结果。 */
public struct Pop3Stat {
    public let messages: Int64
    public let size: Int64

    public init(messages: Int64, size: Int64) {
        this.messages = messages
        this.size = size
    }
}

/** `LIST` 的一行。 */
public struct Pop3MessageInfo {
    public let number: Int64
    public let size: Int64

    public init(number: Int64, size: Int64) {
        this.number = number
        this.size = size
    }
}

/** `UIDL` 的一行。 */
public struct Pop3Uidl {
    public let number: Int64
    public let uid: String

    public init(number: Int64, uid: String) {
        this.number = number
        this.uid = uid
    }
}

/**
 * POP3 客户端。
 *
 * 三态由调用方驱动：`build()` 停在 AUTHORIZATION（已 `CAPA` / 可选 `STLS`，但**未登录**），
 * 登录成功后进入 TRANSACTION，`quit()` 的 `+OK` 之后进入 UPDATE 并关闭连接。
 *
 * 删除语义（RFC 1939 第 6 节）：`dele()` 只是给邮件打标记，真正的删除发生在 `QUIT`
 * 成功之后。因此 `close()` 与任何异常断开都**不会**删除任何邮件——这是"读到一半崩溃
 * 不丢信"的唯一保证，客户端这边只如实记录状态（[isDeleteCommitted]）。
 */
public class Pop3Client <: Resource {
    private let connection: MailConnection
    private let timeouts: MailTimeouts
    private let capabilitiesValue: Pop3Capabilities
    private let greetingValue: String
    private let apopTimestamp: ?String
    private let tlsMode: TlsMode
    private let allowPlaintextAuthValue: Bool
    private var channelRef: LineChannel
    private var authenticated = false
    private var closedFlag = false
    private var deleteCommitted = false
    private let deleteMarks = HashSet<Int64>()
    init(
        connection: MailConnection,
        channel: LineChannel,
        timeouts: MailTimeouts,
        capabilities: Pop3Capabilities,
        greeting: String,
        apopTimestamp: ?String,
        tlsMode: TlsMode,
        allowPlaintextAuth: Bool
    ) {
        this.connection = connection
        this.channelRef = channel
        this.timeouts = timeouts
        this.capabilitiesValue = capabilities
        this.greetingValue = greeting
        this.apopTimestamp = apopTimestamp
        this.tlsMode = tlsMode
        this.allowPlaintextAuthValue = allowPlaintextAuth
    }

    public static func builder(host: String, port!: UInt16 = 110): Pop3ClientBuilder {
        Pop3ClientBuilder(host, port)
    }

    public prop capabilities: Pop3Capabilities {
        get() {
            capabilitiesValue
        }
    }

    /** 服务器的问候文本（`+OK` 之后的部分）。 */
    public prop greeting: String {
        get() {
            greetingValue
        }
    }

    public prop isAuthenticated: Bool {
        get() {
            authenticated
        }
    }

    /** `QUIT` 成功过：已标记删除的邮件在服务器侧已提交。 */
    public prop isDeleteCommitted: Bool {
        get() {
            deleteCommitted
        }
    }

    /** 已 `DELE` 但尚未随 `QUIT` 提交的邮件号。 */
    public prop pendingDeletes: Array<Int64> {
        get() {
            let out = ArrayList<Int64>()
            for (number in deleteMarks) {
                out.add(number)
            }
            out.toArray()
        }
    }

    // ---------- 认证 ----------

    /** `USER` / `PASS`。 */
    public func login(user: String, secret: Secret): Unit {
        requireFresh()
        requirePlaintextSafe("USER")
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            channel.writeLine("USER ${user}")
            expect(Pop3Reply.read(channel), "USER")
            channel.writeLine("PASS " + secret.use { password => password })
            channel.withDeadline(timeouts.command)
            expect(Pop3Reply.read(channel), "PASS")
        } finally {
            channel.endSensitive()
        }
        authenticated = true
    }

    /**
     * `APOP name digest`。
     *
     * 摘要 = `hex(MD5(timestamp + password))`。服务器没在问候里给 `<...>` 时间戳时
     * **必须**报错而不是退回明文密码——退回等于把"想要摘要认证"静默降级成明文。
     */
    public func apop(user: String, secret: Secret): Unit {
        requireFresh()
        let timestamp = match (apopTimestamp) {
            case Some(value) => value
            case None => throw MailProtocolException("服务器问候里没有 APOP 时间戳，无法做摘要认证")
        }
        let digest = secret.use { password =>
            let md5 = MD5()
            md5.write((timestamp + password).toArray())
            toHexString(md5.finish())
        }
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            channel.writeLine("APOP ${user} ${digest}")
            expect(Pop3Reply.read(channel), "APOP")
        } finally {
            channel.endSensitive()
        }
        authenticated = true
    }

    /** `AUTH PLAIN` / `AUTH LOGIN`（RFC 5034）。 */
    public func authenticate(mechanism: Pop3AuthMechanism, user: String, secret: Secret): Unit {
        requireFresh()
        requirePlaintextSafe("AUTH")
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            match (mechanism) {
                case Pop3AuthMechanism.Plain => authPlain(channel, user, secret)
                case Pop3AuthMechanism.Login => authLogin(channel, user, secret)
            }
        } finally {
            channel.endSensitive()
        }
        authenticated = true
    }

    private func authPlain(channel: LineChannel, user: String, secret: Secret): Unit {
        let nul = String([Rune(0)])
        channel.writeLine("AUTH PLAIN")
        channel.withDeadline(timeouts.command)
        let continuation = channel.readLine()
        if (continuation.isNone()) {
            throw MailProtocolException("AUTH PLAIN 期间连接断开")
        }
        let replyText = String.fromUtf8(continuation.getOrThrow())
        if (!(replyText.size > 0 && replyText[0..1] == "+")) {
            expect(Pop3Reply.parse(replyText), "AUTH PLAIN")
        }
        let token = secret.use { password =>
            Base64Codec.encodeUnwrapped((nul + user + nul + password).toArray())
        }
        channel.writeLine(token)
        channel.withDeadline(timeouts.command)
        expect(Pop3Reply.read(channel), "AUTH PLAIN")
    }

    private func authLogin(channel: LineChannel, user: String, secret: Secret): Unit {
        channel.writeLine("AUTH LOGIN")
        channel.withDeadline(timeouts.command)
        expectContinuation(channel, "AUTH LOGIN")
        channel.writeLine(Base64Codec.encodeUnwrapped(user.toArray()))
        channel.withDeadline(timeouts.command)
        expectContinuation(channel, "AUTH LOGIN")
        let encoded = secret.use { password =>
            Base64Codec.encodeUnwrapped(password.toArray())
        }
        channel.writeLine(encoded)
        channel.withDeadline(timeouts.command)
        expect(Pop3Reply.read(channel), "AUTH LOGIN")
    }

    private func expectContinuation(channel: LineChannel, command: String): Unit {
        let raw = channel.readLine()
        if (raw.isNone()) {
            throw MailProtocolException("${command} 期间连接断开")
        }
        let text = String.fromUtf8(raw.getOrThrow())
        if (!(text.size > 0 && text[0..1] == "+")) {
            expect(Pop3Reply.parse(text), command)
        }
    }

    // ---------- 事务 ----------

    public func stat(): Pop3Stat {
        requireTransaction("STAT")
        let reply = send("STAT")
        let tokens = reply.text.split(" ", removeEmpty: true)
        if (tokens.size < 1) {
            throw MailProtocolException("STAT 回复格式错误：${reply.text}")
        }
        // 两种常见写法：`+OK 2 320`（RFC 1939 形式）与 `+OK 2 messages (320 octets)`
        let count = requireNumber(tokens[0], "STAT")
        var size: Int64 = 0
        for (i in 1..tokens.size) {
            if (let Some(value) <- parseUnsigned(tokens[i])) {
                size = value
                break
            }
        }
        Pop3Stat(count, size)
    }

    /** 全部邮件的 `LIST`。 */
    public func list(): Array<Pop3MessageInfo> {
        requireTransaction("LIST")
        let reply = sendMultiline("LIST")
        if (!reply.ok) {
            throw toException(reply, "LIST")
        }
        let out = ArrayList<Pop3MessageInfo>()
        for (line in reply.text.split("\r\n")) {
            if (line.trimAscii().size == 0) {
                continue
            }
            out.add(parseMessageInfo(line, "LIST"))
        }
        out.toArray()
    }

    /** 单封邮件的 `LIST n`。 */
    public func list(message: Int64): Pop3MessageInfo {
        requireTransaction("LIST")
        parseMessageInfo(send("LIST ${requireMessageNumber(message)}").text, "LIST")
    }

    /** 全部邮件的 `UIDL`。没有 `UIDL` 能力时抛 `MailProtocolException(capability="UIDL")`。 */
    public func uidl(): Array<Pop3Uidl> {
        requireTransaction("UIDL")
        requireCapability(capabilitiesValue.supportsUidl, "UIDL")
        let reply = sendMultiline("UIDL")
        if (!reply.ok) {
            throw toException(reply, "UIDL")
        }
        let out = ArrayList<Pop3Uidl>()
        for (line in reply.text.split("\r\n")) {
            if (line.trimAscii().size == 0) {
                continue
            }
            out.add(parseUidl(line))
        }
        out.toArray()
    }

    public func uidl(message: Int64): String {
        requireTransaction("UIDL")
        requireCapability(capabilitiesValue.supportsUidl, "UIDL")
        let text = send("UIDL ${requireMessageNumber(message)}").text
        parseUidl(text).uid
    }

    /**
     * 把整封邮件流式写进 `sink`，返回写入字节数。
     *
     * 走 `DotUnstuffReader` 逐字节状态机，因此正文行可以任意长、内存占用与邮件大小无关。
     */
    public func retr(message: Int64, sink: OutputStream): Int64 {
        requireTransaction("RETR")
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("RETR ${requireMessageNumber(message)}")
        expect(Pop3Reply.read(channel), "RETR")
        channel.withDeadline(timeouts.data)
        copyBody(channel, sink)
    }

    /** `RETR` 之后直接交给 `MimeParser`；正文不整封进内存（超过阈值落 [Spool]）。 */
    public func retrMessage(
        message: Int64,
        options!: MimeParseOptions = MimeParseOptions()
    ): MailMessage {
        requireTransaction("RETR")
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("RETR ${requireMessageNumber(message)}")
        expect(Pop3Reply.read(channel), "RETR")
        channel.withDeadline(timeouts.data)
        let reader = DotUnstuffReader(channel)
        let parsed = MimeParser.parse(reader, options: options)
        channel.pushBack(reader.unread())
        parsed
    }

    /** `TOP n lines`：只要头部 + 前 `lines` 行正文。 */
    public func top(message: Int64, lines: Int64, sink: OutputStream): Int64 {
        requireTransaction("TOP")
        requireCapability(capabilitiesValue.supportsTop, "TOP")
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("TOP ${requireMessageNumber(message)} ${lines}")
        expect(Pop3Reply.read(channel), "TOP")
        channel.withDeadline(timeouts.data)
        copyBody(channel, sink)
    }

    public func topMessage(
        message: Int64,
        lines: Int64,
        options!: MimeParseOptions = MimeParseOptions()
    ): MailMessage {
        requireTransaction("TOP")
        requireCapability(capabilitiesValue.supportsTop, "TOP")
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("TOP ${requireMessageNumber(message)} ${lines}")
        expect(Pop3Reply.read(channel), "TOP")
        channel.withDeadline(timeouts.data)
        let reader = DotUnstuffReader(channel)
        let parsed = MimeParser.parse(reader, options: options)
        channel.pushBack(reader.unread())
        parsed
    }

    /** 标记删除；要等 `QUIT` 的 `+OK` 才真正提交。 */
    public func dele(message: Int64): Unit {
        requireTransaction("DELE")
        let number = requireMessageNumber(message)
        send("DELE ${number}")
        deleteMarks.add(number)
    }

    /** 撤销本次会话里的全部 `DELE` 标记。 */
    public func rset(): Unit {
        requireTransaction("RSET")
        send("RSET")
        deleteMarks.clear()
    }

    public func noop(): Unit {
        requireTransaction("NOOP")
        send("NOOP")
    }

    /** `QUIT`：进入 UPDATE，服务器在此提交删除。 */
    public func quit(): Unit {
        if (closedFlag) {
            return
        }
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        var ok = false
        try {
            channel.writeLine("QUIT")
            let reply = Pop3Reply.read(channel)
            ok = reply.ok
        } catch (_: Exception) {
            ok = false
        } finally {
            closedFlag = true
            connection.close()
        }
        if (!ok) {
            throw MailProtocolException("QUIT 未得到 +OK，服务器可能没有提交删除")
        }
        deleteCommitted = true
    }

    /** 直接断开，不进入 UPDATE：已标记的删除全部作废。 */
    public func close(): Unit {
        closedFlag = true
        connection.close()
    }

    public func isClosed(): Bool {
        closedFlag || connection.isClosed()
    }

    // ---------- 内部 ----------

    private func send(command: String): Pop3Reply {
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.writeLine(command)
        let reply = Pop3Reply.read(channel)
        expect(reply, commandName(command))
        reply
    }

    private func sendMultiline(command: String): Pop3Reply {
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.writeLine(command)
        let reply = Pop3Reply.read(channel)
        if (!reply.ok) {
            return reply
        }
        channel.withDeadline(timeouts.data)
        let lines = Pop3Multiline.readLines(channel)
        var text = ""
        var first = true
        for (line in lines) {
            if (!first) {
                text = text + "\r\n"
            }
            text = text + line
            first = false
        }
        Pop3Reply(true, text)
    }

    private func copyBody(channel: LineChannel, sink: OutputStream): Int64 {
        let reader = DotUnstuffReader(channel)
        let buffer = Array<Byte>(8192, repeat: 0)
        var total: Int64 = 0
        while (true) {
            let n = reader.read(buffer)
            if (n <= 0) {
                break
            }
            let chunk = Array<Byte>(n, repeat: 0)
            for (i in 0..n) {
                chunk[i] = buffer[i]
            }
            sink.write(chunk)
            total += n
        }
        channel.pushBack(reader.unread())
        total
    }

    private func parseMessageInfo(line: String, command: String): Pop3MessageInfo {
        let tokens = line.trimAscii().split(" ", removeEmpty: true)
        if (tokens.size < 2) {
            throw MailProtocolException("${command} 回复格式错误：${line}")
        }
        Pop3MessageInfo(requireNumber(tokens[0], command), requireNumber(tokens[1], command))
    }

    private func parseUidl(line: String): Pop3Uidl {
        let trimmed = line.trimAscii()
        let space = trimmed.indexOf(" ") ?? -1
        if (space <= 0) {
            throw MailProtocolException("UIDL 回复格式错误：${line}")
        }
        Pop3Uidl(requireNumber(trimmed[0..space], "UIDL"), trimmed[(space + 1)..].trimAscii())
    }

    private func requireNumber(text: String, command: String): Int64 {
        if (let Some(value) <- parseUnsigned(text)) {
            return value
        }
        throw MailProtocolException("${command} 回复里的数字非法：${text}")
    }

    private func requireMessageNumber(message: Int64): Int64 {
        if (message < 1) {
            throw IllegalArgumentException("邮件号从 1 开始：${message}")
        }
        message
    }

    private func requireCapability(present: Bool, capability: String): Unit {
        if (!present) {
            throw MailProtocolException("服务器未广告 ${capability} 能力", capability: capability)
        }
    }

    private func requireFresh(): Unit {
        if (isClosed()) {
            throw MailProtocolException("client is closed")
        }
        if (authenticated) {
            throw MailProtocolException("已认证，不能重复登录")
        }
    }

    private func requireTransaction(command: String): Unit {
        if (isClosed()) {
            throw MailProtocolException("client is closed")
        }
        if (!authenticated) {
            throw MailProtocolException("${command} 需要先登录")
        }
    }

    /** 明文连接上发凭据必须显式放行，否则"配错了 TLS"会静默变成明文密码。 */
    private func requirePlaintextSafe(command: String): Unit {
        if (tlsMode.toString() == "None" && !allowPlaintextAuthValue) {
            throw MailAuthException(command, None<Int64>, "明文连接上拒绝发送凭据")
        }
    }

    private func commandName(command: String): String {
        let space = command.indexOf(" ") ?? -1
        if (space > 0) {
            return command[0..space]
        }
        command
    }

    private func expect(reply: Pop3Reply, command: String): Unit {
        if (!reply.ok) {
            throw toException(reply, command)
        }
    }

    /**
     * `-ERR` → 异常。
     *
     * `[AUTH]` 落 `MailAuthException`（调用方不应该重试同一份凭据）；
     * 其余落 `MailProtocolException` 并在消息里保留响应码，方便调用方按 `[SYS/TEMP]` 决定重试。
     */
    private func toException(reply: Pop3Reply, command: String): MailException {
        let kind = reply.errorKind()
        let code = match (reply.errorCode) {
            case Some(value) => "[${value}] "
            case None => ""
        }
        match (kind) {
            case Pop3ErrorKind.Auth =>
                MailAuthException(command, None<Int64>, "POP3 认证失败：${code}${reply.text}")
            case _ =>
                MailProtocolException("POP3 ${command} 失败：${code}${reply.text}", command: command, reply: reply.text)
        }
    }
}

/** 从问候里提取 APOP 时间戳（`<...>`）。 */
func extractApopTimestamp(greeting: String): ?String {
    let open = greeting.indexOf("<") ?? -1
    if (open < 0) {
        return None
    }
    let close = greeting.indexOf(">") ?? -1
    if (close <= open) {
        return None
    }
    Some(greeting[open..(close + 1)])
}

func parseUnsigned(text: String): ?Int64 {
    var trimmed = text.trimAscii()
    // 允许 `(320` / `320)` / `(320)` 这些把数字包在括号里的写法
    while (trimmed.size > 0 && (trimmed[0..1] == "(" || trimmed[0..1] == ")")) {
        trimmed = trimmed[1..]
    }
    while (trimmed.size > 0 && (trimmed[(trimmed.size - 1)..] == ")" || trimmed[(trimmed.size - 1)..] == "(")) {
        trimmed = trimmed[0..(trimmed.size - 1)]
    }
    if (trimmed.size == 0) {
        return None
    }
    var value: Int64 = 0
    for (b in trimmed.toArray()) {
        if (b < b'0' || b > b'9') {
            return None
        }
        value = value * 10 + Int64(b - b'0')
    }
    Some(value)
}

/**
 * `Pop3Client` 的构造器。
 *
 * `build()` 只走到 AUTHORIZATION 结束（`CAPA`，必要时 `STLS`），不登录：
 * 登录方式（`USER`/`PASS`、`APOP`、`AUTH`）由调用方按服务器能力选择。
 */
public class Pop3ClientBuilder {
    private let host: String
    private let port: UInt16
    private var tlsModeValue: TlsMode = TlsMode.None
    private var tlsConfigValue: ?TlsClientConfig = None
    private var timeoutsValue: MailTimeouts = MailTimeouts()
    private var requireEncryptionValue = true
    private var allowPlaintextAuthValue = false
    private var factory: ?TransportFactory = None

    init(host: String, port: UInt16) {
        this.host = host
        this.port = port
    }

    public func tls(mode: TlsMode): This {
        tlsModeValue = mode
        this
    }

    public func tlsConfig(config: TlsClientConfig): This {
        tlsConfigValue = Some(config)
        this
    }

    public func timeouts(timeouts: MailTimeouts): This {
        timeoutsValue = timeouts
        this
    }

    public func requireEncryption(required: Bool): This {
        requireEncryptionValue = required
        this
    }

    public func allowPlaintextAuth(allow: Bool): This {
        allowPlaintextAuthValue = allow
        this
    }

    /** 注入传输实现（测试与未来代理）。 */
    public func transport(factory: TransportFactory): This {
        this.factory = Some(factory)
        this
    }

    public func build(): Pop3Client {
        if (requireEncryptionValue && tlsModeValue.toString() == "None") {
            throw IllegalArgumentException("requireEncryption=true 时必须配置 TLS")
        }
        let timeouts = timeoutsValue
        let transport = match (factory) {
            case Some(value) => value
            case None => SocketTransportFactory(timeouts: timeouts, tlsConfig: tlsConfigValue)
        }
        let connection = transport.connect(host, port, tlsModeValue)
        var channel = connection.channel()
        try {
            channel.withDeadline(timeouts.greeting)
            let greeting = Pop3Reply.read(channel)
            if (!greeting.ok) {
                throw MailProtocolException("POP3 问候失败：${greeting.text}")
            }
            var capabilities = readCapabilities(channel, timeouts)
            if (tlsModeValue.toString() == "StartTls") {
                if (!capabilities.supportsStls) {
                    throw MailProtocolException("服务器未广告 STLS，拒绝明文继续", capability: "STLS")
                }
                channel.withDeadline(timeouts.command)
                channel.writeLine("STLS")
                let reply = Pop3Reply.read(channel)
                if (!reply.ok) {
                    throw MailProtocolException("STLS 被拒绝：${reply.text}", capability: "STLS")
                }
                connection.startTls(config: tlsConfigValue)
                channel = connection.channel()
                capabilities = readCapabilities(channel, timeouts)
            }
            Pop3Client(
                connection,
                channel,
                timeouts,
                capabilities,
                greeting.text,
                extractApopTimestamp(greeting.text),
                tlsModeValue,
                allowPlaintextAuthValue
            )
        } catch (e: Exception) {
            connection.close()
            throw e
        }
    }

    /**
     * `CAPA`：`-ERR` 时返回空表而不是失败。
     *
     * RFC 2449 之前的服务器只实现最小命令集，回 `-ERR` 是合法响应；
     * 把它当失败会让"能正常收发信的老服务器"直接不可用。
     */
    private func readCapabilities(channel: LineChannel, timeouts: MailTimeouts): Pop3Capabilities {
        channel.withDeadline(timeouts.command)
        channel.writeLine("CAPA")
        let reply = Pop3Reply.read(channel)
        if (!reply.ok) {
            return Pop3Capabilities()
        }
        channel.withDeadline(timeouts.command)
        Pop3Capabilities.fromLines(Pop3Multiline.readLines(channel))
    }
}
