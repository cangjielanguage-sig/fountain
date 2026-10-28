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
import std.io.OutputStream
import stdx.crypto.digest.{HMAC, HashType}
import stdx.encoding.hex.toHexString
import stdx.net.tls.TlsClientConfig
import fountain::f_email.mime.{MimeParseOptions, MimeParser, MimeWriteOptions, MimeWriter}
import fountain::f_email.model.*
import fountain::f_email.transport.*

/** `AUTHENTICATE` 支持的机制。 */
public enum ImapAuthMechanism <: ToString {
    | Plain
    | Login
    | CramMd5
    | XOAuth2

    public func toString(): String {
        match (this) {
            case Plain => "PLAIN"
            case Login => "LOGIN"
            case CramMd5 => "CRAM-MD5"
            case XOAuth2 => "XOAUTH2"
        }
    }
}

/** `STORE` 的三种写法。 */
public enum StoreOperation <: ToString {
    | Replace
    | Add
    | Remove

    public func toString(): String {
        match (this) {
            case Replace => "FLAGS"
            case Add => "+FLAGS"
            case Remove => "-FLAGS"
        }
    }
}

/** `STORE` 的结果。 */
public struct StoreResult {
    /** 每个被更新邮件的当前标记（`UNCHANGEDSINCE` 下只含真正改成功的）。 */
    public let updated: Array<FetchResult>
    /**
     * `[MODIFIED <set>]` 列出的序号：因为 `UNCHANGEDSINCE` 冲突**没有**被改的邮件。
     * 这些 MUST NOT 出现在 [updated] 里——并发改标记的场景全靠它。
     */
    public let modified: Array<Int64>

    public init(updated!: Array<FetchResult> = [], modified!: Array<Int64> = []) {
        this.updated = updated
        this.modified = modified
    }

    public func isPartialFailure(): Bool {
        modified.size > 0
    }
}

/** 一次命令的结果：tagged 完成回复 + 期间收到的非请求回复。 */
public struct ImapCommandResult {
    public let response: ImapResponse
    public let untagged: Array<ImapResponse>

    public init(response: ImapResponse, untagged!: Array<ImapResponse> = []) {
        this.response = response
        this.untagged = untagged
    }

    public func isOk(): Bool {
        response.isOk()
    }

    public func code(): ?String {
        response.code
    }

    public func codeArgs(): Array<String> {
        response.codeArgs
    }
}

/**
 * IMAP 客户端。
 *
 * 两条纪律：
 *
 * 1. **状态分清**：[capabilities] 是"服务器能做什么"（`CAPABILITY`），
 *    `enabledCapabilities` 是"已经生效什么"（`ENABLE` 的回显）。扩展 API 的放行条件是后者。
 * 2. **literal 不进 token**：[ImapParser] 只交长度，字节由这里按调用方的意思
 *    送进内存或 sink，因此 100 MB 的正文不会先变成一个 `String`。
 */
public class ImapClient <: Resource {
    private let connection: MailConnection
    private let timeouts: MailTimeouts
    private let tlsMode: TlsMode
    private let allowPlaintextAuthValue: Bool
    private let idName: ?String
    private let idVersion: ?String
    private let maxLiteralBytes: Int64
    private var channelRef: LineChannel
    private var capabilitiesValue: ImapCapabilities
    private var authenticated = false
    private var closedFlag = false
    private var byeSeen = false
    private var selectedMailbox: ?String = None
    private var selectedReadOnly = false
    private var mailboxExists: Int64 = 0
    private var mailboxRecent: Int64 = 0
    private var mailboxUidValidity: ?Int64 = None
    private var mailboxUidNext: ?Int64 = None
    private var mailboxHighestModSeq: ?Int64 = None
    private var mailboxUnseen: ?Int64 = None
    private var mailboxFlags: Array<String> = []
    private var mailboxPermanentFlags: Array<String> = []
    private var tagCounter: Int64 = 0
    private var idleActive = false
    private let enabledList = ArrayList<String>()
    /** 服务端主动推来的 `EXPUNGE` 序号；IDLE 之外由普通命令顺手收走。 */
    private let pendingExpunged = ArrayList<Int64>()
    private let pendingVanished = ArrayList<String>()

    init(
        connection: MailConnection,
        channel: LineChannel,
        timeouts: MailTimeouts,
        capabilities: ImapCapabilities,
        tlsMode: TlsMode,
        allowPlaintextAuth: Bool,
        idName: ?String,
        idVersion: ?String,
        maxLiteralBytes: Int64
    ) {
        this.connection = connection
        this.channelRef = channel
        this.timeouts = timeouts
        this.capabilitiesValue = capabilities
        this.tlsMode = tlsMode
        this.allowPlaintextAuthValue = allowPlaintextAuth
        this.idName = idName
        this.idVersion = idVersion
        this.maxLiteralBytes = maxLiteralBytes
    }

    public static func builder(host: String, port!: UInt16 = 143): ImapClientBuilder {
        ImapClientBuilder(host, port)
    }

    // ---------- 状态 ----------

    public prop capabilities: ImapCapabilities {
        get() {
            capabilitiesValue
        }
    }

    /** `ENABLE` 回显过的能力（已生效）。 */
    public prop enabledCapabilities: Array<String> {
        get() {
            enabledList.toArray()
        }
    }

    public func isEnabled(capability: String): Bool {
        let wanted = capability.toAsciiUpper()
        for (entry in enabledList) {
            if (entry == wanted) {
                return true
            }
        }
        false
    }

    public prop isAuthenticated: Bool {
        get() {
            authenticated
        }
    }

    /** 当前选中的邮箱；`None` 表示 AUTHENTICATED 状态。 */
    public prop selected: ?String {
        get() {
            selectedMailbox
        }
    }

    public prop isReadOnly: Bool {
        get() {
            selectedReadOnly
        }
    }

    public prop messages: Int64 {
        get() {
            mailboxExists
        }
    }

    public prop recent: Int64 {
        get() {
            mailboxRecent
        }
    }

    public prop uidValidity: ?Int64 {
        get() {
            mailboxUidValidity
        }
    }

    public prop uidNext: ?Int64 {
        get() {
            mailboxUidNext
        }
    }

    public prop highestModSeq: ?Int64 {
        get() {
            mailboxHighestModSeq
        }
    }

    public func isClosed(): Bool {
        closedFlag || connection.isClosed()
    }

    /** 服务端在普通命令里推来的 `EXPUNGE` 序号（取走后清空）。 */
    public func takeExpunged(): Array<Int64> {
        let out = pendingExpunged.toArray()
        pendingExpunged.clear()
        out
    }

    public func takeVanished(): Array<String> {
        let out = pendingVanished.toArray()
        pendingVanished.clear()
        out
    }

    // ---------- 认证 ----------

    public func login(user: String, secret: Secret): Unit {
        requireConnection()
        if (authenticated) {
            throw MailProtocolException("已认证，不能重复登录")
        }
        requirePlaintextSafe("LOGIN")
        let tag = nextTag()
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            let password = secret.use { value => value }
            channel.writeLine("${tag} LOGIN ${ImapParser.param(user)} ${ImapParser.param(password)}")
            let result = collect(tag)
            expectOk(result, "LOGIN")
        } finally {
            channel.endSensitive()
        }
        authenticated = true
    }

    /**
     * `AUTHENTICATE <mech>`。
     *
     * `SASL-IR` 可用时把初始响应放进命令行（少一次往返）；`XOAUTH2` 失败时服务器会
     * 先回一个错误挑战 `+ <base64>`，必须补一个**空行**才能读到最终 tagged 回复——
     * 直接等 tagged 会卡住直到超时。
     */
    public func authenticate(mechanism: ImapAuthMechanism, user: String, secret: Secret): Unit {
        requireConnection()
        if (authenticated) {
            throw MailProtocolException("已认证，不能重复登录")
        }
        requirePlaintextSafe("AUTHENTICATE")
        let name = mechanism.toString()
        let initial = initialResponse(mechanism, user, secret)
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            let tag = nextTag()
            let useIr = capabilitiesValue.supportsSaslIr && initial.isSome()
            if (useIr) {
                channel.writeLine("${tag} AUTHENTICATE ${name} ${initial.getOrThrow()}")
            } else {
                channel.writeLine("${tag} AUTHENTICATE ${name}")
            }
            var step = 0
            while (true) {
                let raw = readLineOrThrow()
                if (raw.size > 0 && raw[0..1] == "+") {
                    let challenge = if (raw.size > 1) {
                        raw[1..].trimAscii()
                    } else {
                        ""
                    }
                    let reply = match (mechanism) {
                        case ImapAuthMechanism.Plain =>
                            if (step == 0) {
                                initial.getOrThrow()
                            } else {
                                ""
                            }
                        case ImapAuthMechanism.Login =>
                            if (step == 0) {
                                Base64Codec.encodeUnwrapped(user.toArray())
                            } else {
                                secret.use { value => Base64Codec.encodeUnwrapped(value.toArray()) }
                            }
                        case ImapAuthMechanism.CramMd5 =>
                            secret.use { value => cramResponse(user, value, challenge) }
                        case ImapAuthMechanism.XOAuth2 =>
                            // 失败挑战：补空行，让服务器把最终回复吐出来
                            ""
                    }
                    channel.writeLine(reply)
                    step += 1
                    continue
                }
                let response = ImapResponse.parse(raw)
                if ((response.tag ?? "") == tag) {
                    if (!response.isOk()) {
                        throw MailAuthException(name, None<Int64>, "IMAP 认证失败：${response.raw}")
                    }
                    break
                }
                // 认证期间不应有其它 untagged，忽略但不吞掉 BYE
                if (response.isBye()) {
                    byeSeen = true
                    throw MailAuthException(name, None<Int64>, "服务器在认证期间关闭连接")
                }
            }
        } finally {
            channel.endSensitive()
        }
        authenticated = true
    }

    private func initialResponse(
        mechanism: ImapAuthMechanism,
        user: String,
        secret: Secret
    ): ?String {
        match (mechanism) {
            case ImapAuthMechanism.Plain =>
                let nul = String([Rune(0)])
                Some(
                    secret.use { value =>
                        Base64Codec.encodeUnwrapped((nul + user + nul + value).toArray())
                    }
                )
            case ImapAuthMechanism.XOAuth2 =>
                let soh = String([Rune(1)])
                Some(
                    secret.use { value =>
                        Base64Codec.encodeUnwrapped(
                            ("user=${user}" + soh + "auth=Bearer " + value + soh + soh).toArray()
                        )
                    }
                )
            case _ => None<String>
        }
    }

    private func cramResponse(user: String, password: String, base64Challenge: String): String {
        let challenge = try {
            String.fromUtf8(Base64Codec.decode(base64Challenge))
        } catch (_: Exception) {
            base64Challenge
        }
        let hmac = HMAC(password.toArray(), HashType.MD5)
        hmac.write(challenge.toArray())
        Base64Codec.encodeUnwrapped("${user} ${toHexString(hmac.finish())}".toArray())
    }

    /** `LOGOUT`：服务器先回 `* BYE`，再回 tagged `OK`。 */
    public func logout(): Unit {
        if (isClosed()) {
            return
        }
        try {
            let result = execute("LOGOUT")
            if (!result.isOk()) {
                throw MailProtocolException("LOGOUT 失败：${result.response.raw}")
            }
        } finally {
            closedFlag = true
            authenticated = false
            selectedMailbox = None
            connection.close()
        }
    }

    /** 直接断开（不发 `LOGOUT`）。 */
    public func close(): Unit {
        closedFlag = true
        authenticated = false
        selectedMailbox = None
        connection.close()
    }

    public func noop(): Unit {
        requireAuth("NOOP")
        let result = execute("NOOP")
        expectOk(result, "NOOP")
    }

    // ---------- 邮箱 ----------

    public func select(mailbox: String): MailboxStatus {
        selectInternal(mailbox, "SELECT", "")
    }

    public func examine(mailbox: String): MailboxStatus {
        selectInternal(mailbox, "EXAMINE", "")
    }

    /** 带扩展参数的 `SELECT`（M4 的 `CONDSTORE` / `QRESYNC` 用）。 */
    func selectInternal(mailbox: String, command: String, extra: String): MailboxStatus {
        requireAuth(command)
        valReset()
        let suffix = if (extra.size > 0) {
            " ${extra}"
        } else {
            ""
        }
        let result = execute("${command} ${encodeMailbox(mailbox)}${suffix}")
        expectOk(result, command)
        for (untagged in result.untagged) {
            applyMailboxResponse(untagged)
        }
        selectedMailbox = Some(mailbox)
        selectedReadOnly = (result.code() ?? "") == "READ-ONLY"
        MailboxStatus(
            mailbox,
            messages: Some(mailboxExists),
            recent: Some(mailboxRecent),
            unseen: mailboxUnseen,
            uidNext: mailboxUidNext,
            uidValidity: mailboxUidValidity,
            highestModSeq: mailboxHighestModSeq,
            flags: mailboxFlags,
            permanentFlags: mailboxPermanentFlags,
            readOnly: selectedReadOnly
        )
    }

    /** `CLOSE`：静默删除带 `\Deleted` 的邮件并回到 AUTHENTICATED。 */
    public func closeMailbox(): Unit {
        requireAuth("CLOSE")
        expectOk(execute("CLOSE"), "CLOSE")
        selectedMailbox = None
    }

    /** `UNSELECT`：不删除任何邮件地退回 AUTHENTICATED（需要能力）。 */
    public func unselect(): Unit {
        requireAuth("UNSELECT")
        requireCapability("UNSELECT")
        expectOk(execute("UNSELECT"), "UNSELECT")
        selectedMailbox = None
    }

    public func list(reference: String, pattern: String): Array<MailboxInfo> {
        listInternal("LIST", reference, pattern, "")
    }

    public func lsub(reference: String, pattern: String): Array<MailboxInfo> {
        listInternal("LSUB", reference, pattern, "")
    }

    func listInternal(command: String, reference: String, pattern: String, extra: String): Array<MailboxInfo> {
        requireAuth(command)
        let suffix = if (extra.size > 0) {
            " ${extra}"
        } else {
            ""
        }
        // LIST-EXTENDED 的 selection-options 紧跟在命令名之后：`LIST (SPECIAL-USE) "" "*"`
        let result = execute("${command}${prefixSuffix(extra)} ${encodeMailbox(reference)} ${ImapParser.param(pattern)}")
        expectOk(result, command)
        let out = ArrayList<MailboxInfo>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == command) {
                out.add(parseMailboxInfo(untagged))
            }
        }
        out.toArray()
    }

    public func status(mailbox: String, items!: Array<String> = []): MailboxStatus {
        requireAuth("STATUS")
        var wanted = items
        if (wanted.size == 0) {
            wanted = ["MESSAGES", "RECENT", "UIDNEXT", "UIDVALIDITY", "UNSEEN"]
        }
        var list = "("
        var first = true
        for (item in wanted) {
            if (!first) {
                list = list + " "
            }
            list = list + item.toAsciiUpper()
            first = false
        }
        list = list + ")"
        let result = execute("STATUS ${encodeMailbox(mailbox)} ${list}")
        expectOk(result, "STATUS")
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "STATUS") {
                return parseStatus(mailbox, untagged)
            }
        }
        throw MailProtocolException("STATUS 没有返回数据：${mailbox}")
    }

    // ---------- FETCH ----------

    public func fetch(set: SequenceSet, items: Array<FetchItem>): Array<FetchResult> {
        fetchInternal("FETCH", set, items)
    }

    public func uidFetch(set: SequenceSet, items: Array<FetchItem>): Array<FetchResult> {
        fetchInternal("UID FETCH", set, items)
    }

    private func fetchInternal(prefix: String, set: SequenceSet, items: Array<FetchItem>): Array<FetchResult> {
        fetchWithSuffix(prefix, set, items, "")
    }

    /** 带额外修饰符的 `FETCH`（`CONDSTORE` 的 `(CHANGEDSINCE n)` 用）。 */
    func fetchWithSuffix(
        prefix: String,
        set: SequenceSet,
        items: Array<FetchItem>,
        suffix: String
    ): Array<FetchResult> {
        requireSelected(prefix)
        let tag = nextTag()
        channelRef.withDeadline(timeouts.command)
        channelRef.writeLine("${tag} ${prefix} ${set} ${itemsText(items)}${suffix}")
        let results = ArrayList<FetchResult>()
        valFetchStreamInto(tag, prefix, None<FetchSink>, results)
        results.toArray()
    }

    /** 流式版：正文按块交给 `sink`，不经过内存整封拷贝。 */
    public func fetch(set: SequenceSet, items: Array<FetchItem>, sink: FetchSink): Array<FetchMeta> {
        fetchToSink("FETCH", set, items, sink)
    }

    public func uidFetch(set: SequenceSet, items: Array<FetchItem>, sink: FetchSink): Array<FetchMeta> {
        fetchToSink("UID FETCH", set, items, sink)
    }

    private func fetchToSink(
        prefix: String,
        set: SequenceSet,
        items: Array<FetchItem>,
        sink: FetchSink
    ): Array<FetchMeta> {
        requireSelected(prefix)
        let tag = nextTag()
        channelRef.withDeadline(timeouts.data)
        channelRef.writeLine("${tag} ${prefix} ${set} ${itemsText(items)}")
        let unused = ArrayList<FetchResult>()
        valFetchStreamInto(tag, prefix, Some(sink), unused)
    }

    /**
     * 读 FETCH 响应直到 tagged 完成回复。
     *
     * literal 会把一条响应拆成多行（`... {n}` / 字节 / `...)`），所以这里不能
     * "读一行解析一次"：按片段累积 token，遇到 `{n}` 就精确读 n 字节，
     * 括号深度回到 0 才算这一条结束。
     */
    private func valFetchStreamInto(
        tag: String,
        command: String,
        sink: ?FetchSink,
        results: ArrayList<FetchResult>
    ): Array<FetchMeta> {
        let metas = ArrayList<FetchMeta>()
        while (true) {
            let line = readLineOrThrow()
            if (isTaggedLine(line, tag)) {
                let response = ImapResponse.parse(line)
                let result = ImapCommandResult(response)
                expectOk(result, command)
                return metas.toArray()
            }
            let trimmed = line.trimAscii()
            if (trimmed.size == 0) {
                continue
            }
            let head = untaggedHead(trimmed)
            if (head.name != "FETCH") {
                let response = ImapResponse.parse(trimmed)
                applyUntagged(response)
                continue
            }
            // 一条 FETCH 响应可能跨多个片段
            let tokens = ArrayList<ImapValue>()
            var literalIndex: Int64 = 0
            var bodyBytes = ArrayList<Byte>()
            var streamed = false
            var rest = head.rest
            var first = true
            while (true) {
                var fragment = rest.trimAscii()
                if (first && fragment.size > 0 && fragment[0..1] == "(") {
                    fragment = fragment[1..]
                }
                var done = false
                if (fragment.size > 0 && fragment[(fragment.size - 1)..] == ")") {
                    fragment = fragment[0..(fragment.size - 1)]
                    done = true
                }
                let fragmentTokens = ImapParser.parse(fragment)
                var pendingLiteral: ?Int64 = None
                for (token in fragmentTokens) {
                    match (token) {
                        case Literal(length) => pendingLiteral = Some(length)
                        case LiteralPlus(length) => pendingLiteral = Some(length)
                        case _ => ()
                    }
                    tokens.add(token)
                }
                match (pendingLiteral) {
                    case Some(length) =>
                        literalIndex += 1
                        if (let Some(target) <- sink) {
                            streamed = true
                            valReadLiteral(length) { chunk => target.onBodyChunk(chunk) }
                        } else {
                            for (b in valReadLiteralBytes(length)) {
                                bodyBytes.add(b)
                            }
                        }
                    case None => ()
                }
                if (done) {
                    break
                }
                let next = readLineOrThrow()
                rest = next
                first = false
            }
            let literals: Array<Array<Byte>> = if (streamed) {
                []
            } else {
                [bodyBytes.toArray()]
            }
            let meta = parseFetchMeta(tokens.toArray(), head.number, literals: literals)
            metas.add(meta)
            match (sink) {
                case Some(target) => target.onComplete(meta)
                case None =>
                    results.add(
                        FetchResult(
                            meta.sequence,
                            uid: meta.uid,
                            flags: meta.flags,
                            internalDate: meta.internalDate,
                            size: meta.size,
                            modseq: meta.modseq,
                            envelope: meta.envelope,
                            bodyStructure: meta.bodyStructure,
                            body: if (literals.size > 0) {
                                Some(literals[0])
                            } else {
                                None<Array<Byte>>
                            },
                            section: meta.section,
                            origin: meta.origin
                        )
                    )
            }
        }
        metas.toArray()
    }

    private func valReadLiteralBytes(length: Int64): Array<Byte> {
        if (length > maxLiteralBytes) {
            connection.close()
            throw MailLimitException(LimitKind.Literal, maxLiteralBytes, length)
        }
        channelRef.withDeadline(timeouts.data)
        channelRef.readExact(length)
    }

    private func valReadLiteral(length: Int64, consumer: (Array<Byte>) -> Unit): Unit {
        if (length > maxLiteralBytes) {
            connection.close()
            throw MailLimitException(LimitKind.Literal, maxLiteralBytes, length)
        }
        var remaining = length
        let chunkSize: Int64 = 8192
        while (remaining > 0) {
            let want = if (remaining < chunkSize) {
                remaining
            } else {
                chunkSize
            }
            let chunk = valReadLiteralBytes(want)
            consumer(chunk)
            remaining -= want
        }
    }

    private func isTaggedLine(line: String, tag: String): Bool {
        if (line.size <= tag.size) {
            return false
        }
        if (line[0..tag.size] != tag) {
            return false
        }
        line[tag.size..(tag.size + 1)] == " "
    }

    /** 拆出 `* <n> <NAME> <rest>`；不合形状的返回空 name。 */
    private func untaggedHead(line: String): UntaggedHead {
        let bytes = line.toArray()
        var index = 0
        if (bytes.size == 0 || bytes[0] != b'*') {
            return UntaggedHead("", 0, "")
        }
        index = 1
        while (index < bytes.size && bytes[index] == b' ') {
            index += 1
        }
        var number: Int64 = 0
        var digits = 0
        while (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') {
            number = number * 10 + Int64(bytes[index] - b'0')
            index += 1
            digits += 1
        }
        while (index < bytes.size && bytes[index] == b' ') {
            index += 1
        }
        let nameStart = index
        while (index < bytes.size && bytes[index] != b' ' && bytes[index] != b'(') {
            index += 1
        }
        let name = if (index > nameStart) {
            line[nameStart..index].toAsciiUpper()
        } else {
            ""
        }
        let rest = if (digits == 0) {
            line
        } else {
            line[index..]
        }
        UntaggedHead(name, if (digits == 0) {
            0
        } else {
            number
        }, rest)
    }

    public func fetchMessage(
        set: SequenceSet,
        options!: MimeParseOptions = MimeParseOptions()
    ): Array<MailMessage> {
        fetchMessagesInternal("FETCH", set, options)
    }

    public func uidFetchMessage(
        set: SequenceSet,
        options!: MimeParseOptions = MimeParseOptions()
    ): Array<MailMessage> {
        fetchMessagesInternal("UID FETCH", set, options)
    }

    private func fetchMessagesInternal(
        prefix: String,
        set: SequenceSet,
        options: MimeParseOptions
    ): Array<MailMessage> {
        let results = fetchInternal(prefix, set, [FetchItem.body(section: BodySection.entire(), peek: true)])
        let out = ArrayList<MailMessage>()
        for (result in results) {
            match (result.body) {
                case Some(bytes) => out.add(MimeParser.parse(MemoryBodySource(bytes).open(), options: options))
                case None => ()
            }
        }
        out.toArray()
    }

    // ---------- SEARCH ----------

    public func search(criteria: SearchCriteria): Array<Int64> {
        searchInternal("SEARCH", criteria)
    }

    public func uidSearch(criteria: SearchCriteria): Array<Int64> {
        searchInternal("UID SEARCH", criteria)
    }

    private func searchInternal(prefix: String, criteria: SearchCriteria): Array<Int64> {
        requireSelected(prefix)
        // 只有值里出现非 ASCII 才声明 CHARSET UTF-8：不乱发 CHARSET 是兼容性要求，
        // 有些服务器见到不认识的 CHARSET 直接回 BAD。
        // UTF8=ACCEPT 已生效时 SEARCH 的字符串直接是 UTF-8，不再带 CHARSET；
        // 未生效时只有值里出现非 ASCII 才声明，避免"服务器不认识就 BAD"
        let charset = if (isEnabled("UTF8=ACCEPT")) {
            ""
        } else if (criteria.needsUtf8()) {
            " CHARSET UTF-8"
        } else {
            ""
        }
        let result = execute("${prefix}${charset} ${criteria}")
        expectOk(result, prefix)
        let out = ArrayList<Int64>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "SEARCH") {
                for (value in untagged.values) {
                    if (let Some(number) <- value.number()) {
                        out.add(number)
                    }
                }
            }
        }
        out.toArray()
    }

    // ---------- STORE / COPY / EXPUNGE ----------

    public func store(
        set: SequenceSet,
        operation: StoreOperation,
        flags: Array<String>,
        silent!: Bool = false,
        unchangedSince!: ?Int64 = None
    ): StoreResult {
        requireSelected("STORE")
        var command = "${operation}"
        if (silent) {
            command = command + ".SILENT"
        }
        var args = "("
        var first = true
        for (flag in flags) {
            if (!first) {
                args = args + " "
            }
            args = args + flag
            first = false
        }
        args = args + ")"
        var suffix = ""
        if (let Some(modseq) <- unchangedSince) {
            suffix = " (UNCHANGEDSINCE ${modseq})"
        }
        let result = execute("STORE ${set} ${command}${suffix} ${args}")
        if (!result.isOk() && (result.code() ?? "") != "MODIFIED") {
            expectOk(result, "STORE")
        }
        let updated = ArrayList<FetchResult>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "FETCH") {
                updated.add(parseFetch(untagged.firstList(), untagged.numberOf() ?? 0, []))
            }
        }
        let modified = ArrayList<Int64>()
        if ((result.code() ?? "") == "MODIFIED") {
            for (arg in result.codeArgs()) {
                for (part in arg.split(",", removeEmpty: true)) {
                    if (let Some(number) <- ImapParser.parseNumber(part)) {
                        modified.add(number)
                    }
                }
            }
        }
        StoreResult(updated: updated.toArray(), modified: modified.toArray())
    }

    public func copy(set: SequenceSet, mailbox: String): CopyResult {
        requireSelected("COPY")
        let result = execute("COPY ${set} ${encodeMailbox(mailbox)}")
        expectOk(result, "COPY")
        parseCopyUid(result)
    }

    /** `UID COPY`；`COPYUID` 才有意义时用它。 */
    public func uidCopy(set: SequenceSet, mailbox: String): CopyResult {
        requireSelected("UID COPY")
        let result = execute("UID COPY ${set} ${encodeMailbox(mailbox)}")
        expectOk(result, "UID COPY")
        parseCopyUid(result)
    }

    /**
     * `EXPUNGE`：**序号会移动**。
     *
     * 返回的是"被删掉的原始序号"按响应顺序；调用方手里的序号表必须据此重排，
     * 拿旧序号继续 FETCH 会读到别的邮件。有 `UIDPLUS` 时优先 `uidExpunge`。
     */
    public func expunge(): Array<Int64> {
        requireSelected("EXPUNGE")
        let result = execute("EXPUNGE")
        expectOk(result, "EXPUNGE")
        valExpunged(result)
    }

    public func uidExpunge(set: SequenceSet): Array<Int64> {
        requireSelected("UID EXPUNGE")
        requireCapability("UIDPLUS")
        valReset()
        let result = execute("UID EXPUNGE ${set}")
        expectOk(result, "UID EXPUNGE")
        valExpunged(result)
    }

    private func valExpunged(result: ImapCommandResult): Array<Int64> {
        let out = ArrayList<Int64>()
        for (untagged in result.untagged) {
            if ((untagged.name ?? "") == "EXPUNGE") {
                if (let Some(sequence) <- untagged.numberOf()) {
                    out.add(sequence)
                }
            }
        }
        out.toArray()
    }

    private func valReset(): Unit {
        mailboxExists = 0
        mailboxRecent = 0
        mailboxUidValidity = None
        mailboxUidNext = None
        mailboxHighestModSeq = None
    }

    // ---------- APPEND ----------

    /**
     * `APPEND`。
     *
     * 先把报文序列化两遍：第一遍只数长度（`{n}` 必须精确），第二遍直接写进连接。
     * 这样不把整封邮件拷进内存，也不需要先生成临时文件。
     */
    public func append(
        mailbox: String,
        message: MailMessage,
        flags!: Array<String> = [],
        date!: ?String = None,
        utf8Headers!: Bool = false
    ): AppendResult {
        requireAuth("APPEND")
        let options = MimeWriteOptions(utf8Headers: utf8Headers)
        let counter = ByteCounter()
        MimeWriter(counter, options: options).write(message)
        let size = counter.count
        var command = "APPEND ${encodeMailbox(mailbox)}"
        if (flags.size > 0) {
            command = command + " ("
            var first = true
            for (flag in flags) {
                if (!first) {
                    command = command + " "
                }
                command = command + flag
                first = false
            }
            command = command + ")"
        }
        if (let Some(text) <- date) {
            command = command + " " + ImapParser.quoted(text)
        }
        let literalPlus = capabilitiesValue.supportsLiteralPlus
        command = command + if (literalPlus) {
            " {${size}+}"
        } else {
            " {${size}}"
        }
        let tag = nextTag()
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("${tag} ${command}")
        if (!literalPlus) {
            valAwaitContinuation(tag, "APPEND")
        }
        MimeWriter(channel, options: options).write(message)
        channel.flush()
        let result = collect(tag)
        expectOk(result, "APPEND")
        parseAppendUid(result)
    }

    /**
     * `APPEND` 一个已序列化的字节块（草稿箱转发场景：报文来自 `RETR` / `FETCH`）。
     */
    public func appendBytes(
        mailbox: String,
        bytes: Array<Byte>,
        flags!: Array<String> = [],
        date!: ?String = None
    ): AppendResult {
        requireAuth("APPEND")
        var command = "APPEND ${encodeMailbox(mailbox)}"
        if (flags.size > 0) {
            command = command + " ("
            var first = true
            for (flag in flags) {
                if (!first) {
                    command = command + " "
                }
                command = command + flag
                first = false
            }
            command = command + ")"
        }
        if (let Some(text) <- date) {
            command = command + " " + ImapParser.quoted(text)
        }
        let literalPlus = capabilitiesValue.supportsLiteralPlus
        command = command + if (literalPlus) {
            " {${bytes.size}+}"
        } else {
            " {${bytes.size}}"
        }
        let tag = nextTag()
        let channel = channelRef
        channel.withDeadline(timeouts.data)
        channel.writeLine("${tag} ${command}")
        if (!literalPlus) {
            valAwaitContinuation(tag, "APPEND")
        }
        channel.write(bytes)
        channel.flush()
        let result = collect(tag)
        expectOk(result, "APPEND")
        parseAppendUid(result)
    }

    private func valAwaitContinuation(tag: String, command: String): Unit {
        while (true) {
            let line = readLineOrThrow()
            if (line.size > 0 && line[0..1] == "+") {
                return
            }
            let response = ImapResponse.parse(line)
            if ((response.tag ?? "") == tag) {
                throw MailProtocolException("${command} 未得到继续请求：${line}")
            }
        }
    }

    private func parseCopyUid(result: ImapCommandResult): CopyResult {
        if ((result.code() ?? "") != "COPYUID") {
            return CopyResult()
        }
        let args = result.codeArgs()
        if (args.size < 3) {
            return CopyResult()
        }
        CopyResult(
            uidValidity: ImapParser.parseNumber(args[0]),
            sourceUids: if (args[1].size > 0) {
                Some(SequenceSet(args[1]))
            } else {
                None<SequenceSet>
            },
            destUids: if (args[2].size > 0) {
                Some(SequenceSet(args[2]))
            } else {
                None<SequenceSet>
            }
        )
    }

    private func parseAppendUid(result: ImapCommandResult): AppendResult {
        if ((result.code() ?? "") != "APPENDUID") {
            return AppendResult()
        }
        let args = result.codeArgs()
        if (args.size < 2) {
            return AppendResult()
        }
        AppendResult(uidValidity: ImapParser.parseNumber(args[0]), uid: ImapParser.parseNumber(args[1]))
    }

    // ---------- 命令驱动 ----------

    func execute(command: String): ImapCommandResult {
        requireConnection()
        // IDLE 未结束时普通命令 MUST 立即失败，不排队（排队会把状态错位变成随机超时）
        requireNotIdle()
        let tag = nextTag()
        let channel = channelRef
        channel.withDeadline(timeouts.command)
        channel.writeLine("${tag} ${command}")
        let result = collect(tag)
        if (byeSeen && command.toAsciiUpper() != "LOGOUT") {
            // BYE 意味着服务器即将关闭连接；当前命令不能装作成功。
            closedFlag = true
            connection.close()
            throw MailProtocolException("命令 ${command} 期间服务器发送 BYE")
        }
        result
    }

    /**
     * 读到 tagged 完成回复为止，顺手处理非请求回复。
     *
     * 状态型 untagged（`EXISTS` / `EXPUNGE` / `RECENT`）在这里更新，是所有命令共享的
     * 唯一入口——扩展命令不需要各自维护"邮箱里还有几封"。
     */
    private func collect(tag: String): ImapCommandResult {
        let untagged = ArrayList<ImapResponse>()
        while (true) {
            let line = readLineOrThrow()
            let response = ImapResponse.parse(line)
            match (response.kind) {
                case ImapResponseKind.Continuation =>
                    throw MailProtocolException("命令 ${tag} 收到意外的继续请求：${line}")
                case ImapResponseKind.Untagged =>
                    applyUntagged(response)
                    untagged.add(response)
                case ImapResponseKind.Tagged =>
                    if ((response.tag ?? "") != tag) {
                        throw MailProtocolException("收到不匹配的 tag：${response.tag ?? ""}（期望 ${tag}）")
                    }
                    return ImapCommandResult(response, untagged: untagged.toArray())
            }
        }
        ImapCommandResult(ImapResponse(ImapResponseKind.Tagged, raw: ""))
    }

    /** 变体：允许调用方按 untagged 逐条消费（FETCH 流式用）。 */
    func valUntaggedLoop(tag: String, command: String, action: (ImapResponse) -> Unit): ImapCommandResult {
        let untagged = ArrayList<ImapResponse>()
        while (true) {
            let line = readLineOrThrow()
            let response = ImapResponse.parse(line)
            match (response.kind) {
                case ImapResponseKind.Continuation =>
                    throw MailProtocolException("${command} 收到意外的继续请求")
                case ImapResponseKind.Untagged =>
                    applyUntagged(response)
                    untagged.add(response)
                    action(response)
                case ImapResponseKind.Tagged =>
                    if ((response.tag ?? "") != tag) {
                        throw MailProtocolException("收到不匹配的 tag：${response.tag ?? ""}")
                    }
                    let result = ImapCommandResult(response, untagged: untagged.toArray())
                    if (byeSeen && command.toAsciiUpper() != "LOGOUT") {
                        closedFlag = true
                        connection.close()
                        throw MailProtocolException("命令 ${command} 期间服务器发送 BYE")
                    }
                    expectOk(result, command)
                    return result
            }
        }
        ImapCommandResult(ImapResponse(ImapResponseKind.Tagged, raw: ""))
    }

    private func applyUntagged(response: ImapResponse): Unit {
        let name = response.name ?? ""
        match (name) {
            case "EXISTS" =>
                if (let Some(value) <- response.numberOf()) {
                    mailboxExists = value
                }
            case "RECENT" =>
                if (let Some(value) <- response.numberOf()) {
                    mailboxRecent = value
                }
            case "EXPUNGE" =>
                if (let Some(value) <- response.numberOf()) {
                    pendingExpunged.add(value)
                    if (mailboxExists > 0) {
                        mailboxExists -= 1
                    }
                }
            case "VANISHED" =>
                for (value in response.values) {
                    let text = value.text()
                    if (text.size > 0) {
                        pendingVanished.add(text)
                    }
                }
            case "BYE" =>
                byeSeen = true
            case _ => ()
        }
    }

    /** `SELECT` / `EXAMINE` 之后的邮箱状态响应。 */
    private func applyMailboxResponse(response: ImapResponse): Unit {
        let name = response.name ?? ""
        if (name == "EXISTS") {
            mailboxExists = response.numberOf() ?? mailboxExists
            return
        }
        if (name == "RECENT") {
            mailboxRecent = response.numberOf() ?? mailboxRecent
            return
        }
        if (name == "FLAGS") {
            for (value in response.values) {
                match (value) {
                    case List(items) => mailboxFlags = toStrings(items)
                    case _ => ()
                }
            }
            return
        }
        match (response.code ?? "") {
            case "UIDVALIDITY" =>
                if (response.codeArgs.size > 0) {
                    mailboxUidValidity = ImapParser.parseNumber(response.codeArgs[0])
                }
            case "UIDNEXT" =>
                if (response.codeArgs.size > 0) {
                    mailboxUidNext = ImapParser.parseNumber(response.codeArgs[0])
                }
            case "HIGHESTMODSEQ" =>
                if (response.codeArgs.size > 0) {
                    mailboxHighestModSeq = ImapParser.parseNumber(response.codeArgs[0])
                }
            case "UNSEEN" =>
                if (response.codeArgs.size > 0) {
                    mailboxUnseen = ImapParser.parseNumber(response.codeArgs[0])
                }
            case "PERMANENTFLAGS" =>
                let parsed = ArrayList<String>()
                for (arg in response.codeArgs) {
                    var text = arg
                    if (text.startsWith("(")) {
                        text = text[1..]
                    }
                    if (text.endsWith(")")) {
                        text = text[0..(text.size - 1)]
                    }
                    if (text.size > 0) {
                        parsed.add(text)
                    }
                }
                mailboxPermanentFlags = parsed.toArray()
            case _ => ()
        }
    }

    func readLineOrThrow(): String {
        let raw = channelRef.readLine()
        if (raw.isNone()) {
            closedFlag = true
            throw MailIoException(IoStage.Read, "IMAP 服务器在响应中途断开连接")
        }
        String.fromUtf8(raw.getOrThrow())
    }

    /**
     * tag 生成：`A0001`…`A9999`，然后 `B0001`。**不回绕**——回绕会让"上一条命令的
     * 迟到回复"和"新命令的回复"撞在同一个 tag 上，那种错误几乎无法复现。
     */
    func nextTag(): String {
        tagCounter += 1
        let index = (tagCounter - 1) / 9999
        let number = (tagCounter - 1) % 9999 + 1
        let letter = String([Rune(UInt32(r'A') + UInt32(index % 26))])
        let digits = number.toString()
        var padded = digits
        while (padded.size < 4) {
            padded = "0" + padded
        }
        "${letter}${padded}"
    }

    // ---------- 参数编码 ----------

    func encodeMailbox(name: String): String {
        if (isEnabled("UTF8=ACCEPT")) {
            return ImapParser.param(name)
        }
        ImapParser.param(ImapUtf7.encode(name))
    }

    func encodeString(value: String): String {
        ImapParser.quoted(value)
    }

    private func itemsText(items: Array<FetchItem>): String {
        if (items.size == 0) {
            return "(UID)"
        }
        var out = "("
        var first = true
        for (item in items) {
            if (!first) {
                out = out + " "
            }
            out = out + item.toString()
            first = false
        }
        out + ")"
    }

    // ---------- 响应解析 ----------

    private func prefixSuffix(extra: String): String {
        if (extra.size > 0) {
            " ${extra}"
        } else {
            ""
        }
    }

    private func parseMailboxInfo(response: ImapResponse): MailboxInfo {
        let values = response.values
        var attributes: Array<String> = []
        var delimiter: ?String = None
        var name = ""
        if (values.size >= 1) {
            attributes = toStrings(values[0].items())
        }
        if (values.size >= 2) {
            delimiter = stringOrNone(values[1])
        }
        if (values.size >= 3) {
            name = values[2].text()
        }
        let decoded = if (isEnabled("UTF8=ACCEPT")) {
            name
        } else {
            ImapUtf7.decode(name)
        }
        MailboxInfo(decoded, delimiter: delimiter, attributes: attributes)
    }

    private func toStrings(values: Array<ImapValue>): Array<String> {
        let out = ArrayList<String>()
        for (value in values) {
            out.add(value.text())
        }
        out.toArray()
    }

    private func parseStatus(mailbox: String, response: ImapResponse): MailboxStatus {
        var messages: ?Int64 = None
        var recent: ?Int64 = None
        var unseen: ?Int64 = None
        var uidNextValue: ?Int64 = None
        var uidValidityValue: ?Int64 = None
        var modseq: ?Int64 = None
        var list: Array<ImapValue> = []
        for (value in response.values) {
            match (value) {
                case List(items) => list = items
                case _ => ()
            }
        }
        var index = 0
        while (index + 1 < list.size) {
            let key = list[index].text().toAsciiUpper()
            let number = list[index + 1].number()
            match (key) {
                case "MESSAGES" => messages = number
                case "RECENT" => recent = number
                case "UNSEEN" => unseen = number
                case "UIDNEXT" => uidNextValue = number
                case "UIDVALIDITY" => uidValidityValue = number
                case "HIGHESTMODSEQ" => modseq = number
                case _ => ()
            }
            index += 2
        }
        MailboxStatus(
            mailbox,
            messages: messages,
            recent: recent,
            unseen: unseen,
            uidNext: uidNextValue,
            uidValidity: uidValidityValue,
            highestModSeq: modseq
        )
    }

    /** 把 `* n FETCH (...)` 的列表解析成结果。literals 按出现顺序对应 body。 */
    func parseFetch(items: Array<ImapValue>, sequence: Int64, literals: Array<Array<Byte>>): FetchResult {
        let meta = parseFetchMeta(items, sequence, literals: literals)
        var body: ?Array<Byte> = None
        if (literals.size > 0) {
            body = Some(literals[0])
        }
        FetchResult(
            meta.sequence,
            uid: meta.uid,
            flags: meta.flags,
            internalDate: meta.internalDate,
            size: meta.size,
            modseq: meta.modseq,
            envelope: meta.envelope,
            bodyStructure: meta.bodyStructure,
            body: body,
            section: meta.section,
            origin: meta.origin
        )
    }

    func parseFetchMeta(items: Array<ImapValue>, sequence: Int64, literals!: Array<Array<Byte>> = []): FetchMeta {
        var uid: ?Int64 = None
        var flags: Array<String> = []
        var internalDate: ?String = None
        var size: ?Int64 = None
        var modseq: ?Int64 = None
        var envelope: ?ImapEnvelope = None
        var bodyStructure: ?BodyStructure = None
        var section: ?String = None
        var origin: ?Int64 = None
        var index = 0
        while (index + 1 < items.size) {
            let key = items[index].text().toAsciiUpper()
            let value = items[index + 1]
            match (key) {
                case "UID" => uid = value.number()
                case "FLAGS" => flags = toStrings(value.items())
                case "INTERNALDATE" => internalDate = stringOrNone(value)
                case "RFC822.SIZE" => size = value.number()
                case "ENVELOPE" =>
                    match (value) {
                        case List(_) => envelope = Some(ImapEnvelope.parse(value))
                        case _ => ()
                    }
                case "BODYSTRUCTURE" =>
                    match (value) {
                        case List(_) => bodyStructure = Some(BodyStructure.parse(value))
                        case _ => ()
                    }
                case "MODSEQ" =>
                    let list = value.items()
                    if (list.size > 0) {
                        modseq = list[0].number()
                    }
                case _ =>
                    if (key.size > 4 && key[0..4] == "BODY") {
                        let rawKey = items[index].text()
                        section = Some(markerSection(rawKey))
                        origin = extractOrigin(rawKey)
                    }
            }
            index += 2
        }
        FetchMeta(
            sequence,
            uid: uid,
            flags: flags,
            internalDate: internalDate,
            size: size,
            modseq: modseq,
            envelope: envelope,
            bodyStructure: bodyStructure,
            section: section,
            origin: origin
        )
    }

    /** `BODY[HEADER.FIELDS (FROM TO)]<0>` → `HEADER.FIELDS (FROM TO)`。 */
    private func markerSection(key: String): String {
        let open = key.indexOf("[") ?? -1
        let close = key.indexOf("]") ?? -1
        if (open >= 0 && close > open) {
            return key[(open + 1)..close]
        }
        key
    }

    private func extractOrigin(key: String): ?Int64 {
        let open = key.indexOf("<") ?? -1
        if (open < 0) {
            return None
        }
        let dot = key.indexOf(".") ?? -1
        if (dot <= open) {
            return ImapParser.parseNumber(key[(open + 1)..(key.size - 1)])
        }
        ImapParser.parseNumber(key[(open + 1)..dot])
    }

    // ---------- 守卫 ----------

    func requireConnection(): Unit {
        if (isClosed()) {
            throw MailProtocolException("client is closed")
        }
        if (byeSeen) {
            throw MailProtocolException("服务器已发送 BYE，连接不可用")
        }
    }

    func requireAuth(command: String): Unit {
        requireConnection()
        if (!authenticated) {
            throw MailProtocolException("${command} 需要先登录")
        }
    }

    func requireSelected(command: String): Unit {
        requireAuth(command)
        if (selectedMailbox.isNone()) {
            throw MailProtocolException("${command} 需要先 SELECT/EXAMINE 一个邮箱")
        }
        requireNotIdle()
    }

    func requireNotIdle(): Unit {
        if (idleActive) {
            throw MailProtocolException("connection is idle")
        }
    }

    /** 能力位检查：缺失时统一 `MailProtocolException(capability=…)`，不新增异常类型。 */
    func requireCapability(capability: String): Unit {
        if (!capabilitiesValue.supports(capability)) {
            throw MailProtocolException("服务器未广告 ${capability} 能力", capability: capability)
        }
    }

    func requireEnabled(capability: String): Unit {
        if (!isEnabled(capability)) {
            throw MailProtocolException(
                "扩展 ${capability} 未启用（需要先 ENABLE 并收到回显）",
                capability: capability
            )
        }
    }

    private func requirePlaintextSafe(command: String): Unit {
        if (tlsMode.toString() == "None" && !allowPlaintextAuthValue) {
            throw MailAuthException(command, None<Int64>, "明文连接上拒绝发送凭据")
        }
    }

    private func expectOk(result: ImapCommandResult, command: String): Unit {
        if (!result.isOk()) {
            let text = result.response.raw
            if ((result.response.status ?? "") == "NO" && isAuthFailure(text)) {
                throw MailAuthException(command, None<Int64>, "IMAP 认证失败：${text}")
            }
            throw MailProtocolException("IMAP ${command} 失败：${text}", command: command, reply: text)
        }
    }

    private func isAuthFailure(text: String): Bool {
        let upper = text.toAsciiUpper()
        upper.contains("AUTHENTICATIONFAILED") || upper.contains("[AUTHORIZATIONFAILED]") ||
            upper.contains("INVALID CREDENTIALS")
    }

    // ---------- 供扩展使用 ----------

    func setEnabled(capability: String): Unit {
        if (!isEnabled(capability)) {
            enabledList.add(capability.toAsciiUpper())
        }
    }

    func clearEnabled(): Unit {
        enabledList.clear()
    }

    func setCapabilities(capabilities: ImapCapabilities): Unit {
        capabilitiesValue = capabilities
    }

    func markIdle(active: Bool): Unit {
        idleActive = active
    }

    func markAuthenticated(): Unit {
        authenticated = true
    }

    func channel(): LineChannel {
        channelRef
    }

    func timeoutsValue(): MailTimeouts {
        timeouts
    }

    func connectionValue(): MailConnection {
        connection
    }
}

/** 只数字节、不落盘的 sink（`APPEND` 的 `{n}` 预计算）。 */
class ByteCounter <: OutputStream {
    var count: Int64 = 0

    public func write(bytes: Array<Byte>): Unit {
        count += bytes.size
    }
}

/**
 * `ImapClient` 的构造器。
 *
 * `build()` 停在同一处：连接 → 问候 → `CAPABILITY` →（`STARTTLS` 后重新 `CAPABILITY`）→
 * 可选 `ID`，**不登录**。登录方式由调用方按服务器能力选择。
 */
public class ImapClientBuilder {
    private let host: String
    private let port: UInt16
    private var tlsModeValue: TlsMode = TlsMode.None
    private var tlsConfigValue: ?TlsClientConfig = None
    private var timeoutsValue: MailTimeouts = MailTimeouts()
    private var requireEncryptionValue = true
    private var allowPlaintextAuthValue = false
    private var idNameValue: ?String = None
    private var idVersionValue: ?String = None
    private var maxLiteralBytesValue: Int64 = 64 * 1024 * 1024
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

    /** 单个 IMAP literal 的最大字节数，默认 64 MB；超限断开连接。 */
    public func maxLiteralBytes(limit: Int64): This {
        maxLiteralBytesValue = limit
        this
    }

    /** 配置 `ID` 命令的客户端标识（RFC 2971）。 */
    public func id(name: String, version: String): This {
        idNameValue = Some(name)
        idVersionValue = Some(version)
        this
    }

    public func transport(factory: TransportFactory): This {
        this.factory = Some(factory)
        this
    }

    public func build(): ImapClient {
        if (requireEncryptionValue && tlsModeValue.toString() == "None") {
            throw IllegalArgumentException("requireEncryption=true 时必须配置 TLS")
        }
        let timeouts = timeoutsValue
        let transport = match (factory) {
            case Some(value) => value
            case None => SocketTransportFactory(timeouts: timeouts, tlsConfig: tlsConfigValue, maxLine: 8192)
        }
        let connection = transport.connect(host, port, tlsModeValue)
        var channel = connection.channel()
        try {
            channel.withDeadline(timeouts.greeting)
            let greetingLine = readGreeting(channel)
            let greeting = ImapResponse.parse(greetingLine)
            if (greeting.isBye()) {
                throw MailProtocolException("IMAP 服务器拒绝连接：${greeting.raw}")
            }
            var capabilities = fetchCapabilities(connection, channel, timeouts)
            var client = ImapClient(
                connection,
                channel,
                timeouts,
                capabilities,
                tlsModeValue,
                allowPlaintextAuthValue,
                idNameValue,
                idVersionValue,
                maxLiteralBytesValue
            )
            if ((greeting.status ?? "").toAsciiUpper() == "PREAUTH") {
                client.markAuthenticated()
            }
            if (tlsModeValue.toString() == "StartTls") {
                if (!capabilities.supportsStartTls) {
                    throw MailProtocolException("服务器未广告 STARTTLS，拒绝明文继续", capability: "STARTTLS")
                }
                let result = client.execute("STARTTLS")
                if (!result.isOk()) {
                    throw MailProtocolException("STARTTLS 被拒绝：${result.response.raw}", capability: "STARTTLS")
                }
                connection.startTls(config: tlsConfigValue)
                client = ImapClient(
                    connection,
                    connection.channel(),
                    timeouts,
                    fetchCapabilities(connection, connection.channel(), timeouts),
                    tlsModeValue,
                    allowPlaintextAuthValue,
                    idNameValue,
                    idVersionValue,
                    maxLiteralBytesValue
                )
                if ((greeting.status ?? "").toAsciiUpper() == "PREAUTH") {
                    client.markAuthenticated()
                }
            }
            if (let Some(name) <- idNameValue) {
                if (client.capabilities.supportsId) {
                    let version = idVersionValue ?? ""
                    client.execute("ID (\"name\" ${ImapParser.quoted(name)} \"version\" ${ImapParser.quoted(version)})")
                }
            }
            capabilities = client.capabilities
            client
        } catch (e: Exception) {
            connection.close()
            throw e
        }
    }

    private func readGreeting(channel: LineChannel): String {
        let raw = channel.readLine()
        if (raw.isNone()) {
            throw MailIoException(IoStage.Greeting, "IMAP 服务器没有发问候")
        }
        String.fromUtf8(raw.getOrThrow())
    }

    private func fetchCapabilities(
        connection: MailConnection,
        channel: LineChannel,
        timeouts: MailTimeouts
    ): ImapCapabilities {
        channel.withDeadline(timeouts.command)
        channel.writeLine("A0000 CAPABILITY")
        var capabilities = ImapCapabilities()
        while (true) {
            let raw = channel.readLine()
            if (raw.isNone()) {
                throw MailIoException(IoStage.Read, "CAPABILITY 中途断开")
            }
            let line = String.fromUtf8(raw.getOrThrow())
            let response = ImapResponse.parse(line)
            if (response.isUntagged() && (response.name ?? "") == "CAPABILITY") {
                capabilities = ImapCapabilities.fromValues(response.values)
                continue
            }
            if (response.isTagged()) {
                if (!response.isOk()) {
                    throw MailProtocolException("CAPABILITY 失败：${line}")
                }
                break
            }
        }
        capabilities
    }
}

struct UntaggedHead {
    let name: String
    let number: Int64
    let rest: String

    init(name: String, number: Int64, rest: String) {
        this.name = name
        this.number = number
        this.rest = rest
    }
}
