# f_email

邮件客户端模块：SMTP / POP3 / IMAP4rev1 + MIME 解析与生成。

- 包名：`fountain::f_email`（另有 `f_email.transport` / `f_email.mime` / `f_email.smtp` / `f_email.pop3` / `f_email.imap`）
- 依赖：`f_base`、`f_io`、`f_log`、`f_random`、`charset4cj`、`stdx`（tls / base64 / digest / x509）
- 设计文档：[`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## 当前状态

按里程碑推进（M0 → M4），代码与单元测试同步落地。

- **M0 传输骨架**：`MailConnection` / `LineChannel` / `DotStuff` / `MailTrace` /
  `TransportFactory`（含脚本化测试传输）。
- **M1 消息模型与 MIME**：`HeaderMap`、地址/日期、`CharsetResolver`、base64/QP、
  RFC 2047/2231、`MimePart`/`MailMessage`、流式 `MimeParser` 与 `MimeWriter`。
- **M1-e SMTP**：`SmtpClient` 建连/EHLO/STARTTLS/AUTH（PLAIN / LOGIN / CRAM-MD5 / XOAUTH2）、
  投递事务、PIPELINING、逐收件人 `SendReport`、Bcc 剥离、SIZE 预检、8BITMIME / SMTPUTF8。
- **M2 POP3**：`Pop3Client`（`CAPA` / `STLS`、`USER`+`PASS` / `APOP` / `AUTH PLAIN`+`LOGIN`、
  `STAT`/`LIST`/`UIDL`、流式 `RETR`/`TOP`、`DELE`/`RSET`/`QUIT`），`-ERR` 响应码分类。
- **M3 IMAP 核心**：tag 驱动的命令框架、modified UTF-7、token 解析、`SELECT`/`EXAMINE`/
  `STATUS`/`LIST`/`LSUB`、`FETCH`（含 literal 的流式与内存两路）、`BODYSTRUCTURE`、
  `ENVELOPE`、`INTERNALDATE`、`SEARCH`、`STORE`/`COPY`/`EXPUNGE`、`APPEND`、`LOGOUT`。
- **M4 IMAP 扩展七组**：`ENABLE` 协商、`IDLE`（读线程 + 有界队列 + 25 分钟重建）、
  `MOVE`（含非原子回退）、`SPECIAL-USE`、`NAMESPACE`、`UTF8=ACCEPT`、
  `CONDSTORE`/`QRESYNC`、`SORT`/`THREAD`。
- **统一门面**：`Email` 一个类管住三种协议——发送、列表（标题 + 接收时间）、读正文、
  取附件、删除指定邮件；懒连接，读走 `EXAMINE` + `BODY.PEEK[]`，删除按 UID 精确到单封。

全量 `cjpm test`：**275 通过 / 0 失败**。真实服务器验证：QQ 邮箱 SMTP 465 发信、
IMAP 993 列信/读正文/取附件均通过（含 1.6 MB pptx 附件与长中文标题）。

逐条验收见 `doc/spec/add-f-email-client/tasks.md`，验证记录见同目录 `verification.md`。

## 用法

### 统一门面（`fountain::f_email.Email`）

一个类管住 SMTP / IMAP / POP3：发信、列信、读正文、取附件、删信都在这里，
下面的 `SmtpClient` / `ImapClient` / `Pop3Client` 是它的实现细节。

```cangjie
let email = Email.builder()
    .smtp("smtp.example.com", port: 465)
    .imap("imap.example.com", port: 993)      // 或 .pop3(...) + receiveVia(ReceiveProtocol.Pop3)
    .auth("user@example.com", Secret.of("password"))
    .build()                                   // 懒连接：这里不建连

// 发信
let report = email.send(
    MailMessage.builder()
        .from("user@example.com")
        .to("friend@example.com")
        .subject("你好")
        .text("正文")
        .attach("report.pdf", FileBodySource(Path("report.pdf")))
        .build()
)

// 收信：标题 + 接收时间 + 已读状态（IMAP 用 EXAMINE，不会置 \Seen）
let summaries = email.list(limit: 20)
for (summary in summaries) {
    var received = "?"
    match (summary.receivedAt) {
        case Some(value) => received = value.toString()
        case None => ()
    }
    println("${summary.subject}  ${received}  unread=${summary.isUnread()}")
}

// 读正文与附件（只读）
let body = email.body(summaries[0])
let text = body.text ?? ""
for (attachment in body.attachments) {
    println("${attachment.filename} ${attachment.size} B")
    attachment.saveTo(Path("download/${attachment.filename}"))
}

// 删信：IMAP 按 UID 只删这一封；POP3 是 DELE + QUIT 提交
email.delete(summaries[0])
email.close()
```

`Email` 的三条行为约定：

| 约定 | 说明 |
|---|---|
| 懒连接 | `build()` 不建连；第一次 `send` 才连 SMTP，第一次 `list` / `fetch` / `delete` 才连收件协议。只发信不需要 IMAP 可达 |
| 用摘要定位 | `list` 返回 `MailSummary`，后续读/删都传它；IMAP 用 UID，不会因 `EXPUNGE` 导致序号移动而删错信 |
| 读是只读的 | `list` / `body` 走 `EXAMINE` + `BODY.PEEK[]`，不改 `\Seen`；删除必须显式调 `delete` |

### 发信（SMTP）

```cangjie
let client = SmtpClient.builder("smtp.example.com", port: 465)
    .tls(TlsMode.Implicit)
    .auth(SmtpAuthMechanism.Plain, "user@example.com", Secret.of("password"))
    .build()

let message = MailMessage.builder()
    .from("user@example.com")
    .to("friend@example.com")
    .subject("你好")
    .text("正文")
    .attach("report.pdf", FileBodySource(Path("report.pdf")))
    .build()

let report = client.send(message)   // 部分拒收不抛异常，看 report.rejected
client.close()
```

### 收信（POP3）

```cangjie
let client = Pop3Client.builder("pop.example.com", port: 995).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
let list = client.list()                 // 每封的序号与大小
let message = client.retrMessage(1)      // RETR 直接交给 MimeParser
let text = message.text()
client.quit()                            // 删除标记只在 QUIT 的 +OK 后提交
```

### 读信（IMAP）

```cangjie
let client = ImapClient.builder("imap.example.com", port: 993).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
client.select("INBOX")

// 只要头部：不置 \Seen
let heads = client.fetch(
    SequenceSet.range(1, 10),
    [FetchItem.uid(), FetchItem.envelope(), FetchItem.flags()]
)

// 只要未读里来自某个人的
let ids = client.uidSearch(
    SearchCriteria.unseen().andWith(SearchCriteria.from("boss@example.com"))
)
```

### IDLE（服务器推送）

```cangjie
let enabled = ImapEnable(client).enableUtf8Accept()
let session = ImapIdle(client).start()      // 默认 25 分钟自动 DONE 后重建
while (true) {
    match (session.nextEvent(timeout: Duration.second * 30)) {
        case Some(event) => println("${event.kind} ${event.sequence}")
        case None => ()                     // 超时不是错误，连接仍然有效
    }
}
session.close()                             // 发 DONE 后收尾
```

### MIME 编解码

```cangjie
// 解析：解码后 ≤ 256 KB 的文本进内存，其余落临时文件（权限 0600）
let message = MimeParser.parse(input, options: MimeParseOptions(strict: false))
let attachments = message.attachments()

// 生成：target 支持 8BITMIME 时 allow8Bit=true
MimeWriter(target, options: MimeWriteOptions(allow8Bit: true)).write(message)
```

## 环境要求

构建前必须设置 `CANGJIE_STDX_DYNAMIC_PATH` 指向 stdx 动态库目录：

```shell
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

### P-0 依赖验证结论（2026-10-28，Linux aarch64）

| 项 | 结论 |
|---|---|
| `stdx.net.tls` | `TlsSocket.client` 连接 `smtp.163.com:465` 成功，协商到 TLS 1.3 + `TLS_AES_256_GCM_SHA384`，系统 CA 校验链路（3 张证书）通过，默认 `CertificateVerifyMode.Default` 可用。**OHOS 目标机未验证**（无设备），按设计保留"调用方注入 `TlsClientConfig` + 自签 CA"的退路，不默认 `TrustAll` |
| `charset4cj` 1.0.5 | GBK / GB18030 / BIG5 / WINDOWS_1252 解码中文样本均正确（`中文测试`、`中文測試`、`éÿ`） |
| `stdx.encoding.base64` | **不容错**：缺 padding（`SGVsbG8`）与含空白（`SGVs bG8=\n`）都返回 `None`，非法字符同样 `None`。因此 `mime/Base64Codec` 必须自行去空白、补 padding、按宽松/严格两态处理非法字符 |
| `stdx.crypto.digest` | `MD5` / `HMAC(key, HashType.MD5)` + `toHexString` 输出**小写**十六进制，可直接用于 CRAM-MD5 与 APOP 摘要 |

验证方式：一次性探针测试（已从仓库移除），逐项断言/打印上表结果。

## 已知未验证项

- OHOS 目标机上的 TLS 与 `Spool` 目录（无设备）。
- Dovecot / 163 的扩展错误矩阵（QQ 邮箱的 IMAP/SMTP 往返已验证通过）。
- TLS 自签证书的自动化用例（当前由 G6 与 P-0 的手工验证覆盖）。

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`AddressList`（class）、`AppendResult`（struct）、`Base64Decoder`（class）、`Base64Encoder`（class）、`BodySection`（struct）、`BodySource`（interface）、`BodyStructure`（enum）、`CharsetOptions`（struct）、`ContentDisposition`（class）、`ContentType`（class）、`CopyResult`（struct）、`DecodedText`（struct）、`DotStuffWriter`（class）、`DotUnstuffReader`（class）、`DsnNotify`（enum）、`DsnReturn`（enum）、`EmailAddress`（class）、`EmailBuilder`（class）、`EncodedWord`（class）、`Envelope`（class）、`F_EMAIL_VERSION`（let）、`FetchItem`（struct）、`FetchMeta`（struct）、`FetchResult`（struct）、`FetchSink`（interface）、`ImapAddress`（struct）、`ImapAuthMechanism`（enum）、`ImapCapabilities`（struct）、`ImapClientBuilder`（class）、`ImapCommandResult`（struct）、`ImapCondStore`（class）、`ImapDate`（struct）、`ImapEnvelope`（struct）、`ImapEvent`（struct）、`ImapEventKind`（enum）、`ImapIdleSession`（class）、`ImapMove`（class）、`ImapNamespace`（class）、`ImapParser`（class）、`ImapResponse`（struct）、`ImapResponseKind`（enum）、`ImapSort`（class）、`ImapSpecialUse`（class）、`ImapUtf7`（class）、`ImapValue`（enum）、`IoStage`（enum）、`IoTimeout`（interface）、`LeafBody`（struct）、`LimitKind`（enum）、`MailAttachment`（class）、`MailAuthException`（class）、`MailBody`（class）、`MailDate`（class）、`MailException`（class）、`MailIoException`（class）、`MailLimitException`（class）、`MailMessageBuilder`（class）、`MailProtocolException`（class）、`MailTimeouts`（struct）、`MailTlsException`（class）、`MailboxInfo`（struct）、`MailboxStatus`（struct）、`MemoryBodySource`（class）、`MimeAction`（enum）、`MimeException`（class）、`MimeParameter`（class）、`MimeParameters`（class）、`MimeVisitor`（interface）、`MoveResult`（struct）、`MultiBody`（struct）、`Multipart`（class）、`NamespaceEntry`（struct）、`NamespaceInfo`（struct）、`PartBody`（enum）、`Pop3AuthMechanism`（enum）、`Pop3Capabilities`（struct）、`Pop3Capability`（struct）、`Pop3ClientBuilder`（class）、`Pop3ErrorKind`（enum）、`Pop3MessageInfo`（struct）、`Pop3Reply`（struct）、`Pop3Stat`（struct）、`Pop3Uidl`（struct）、`QResyncParams`（struct）、`QuotedPrintable`（class）、`QuotedPrintableDecoder`（class）、`QuotedPrintableEncoder`（class）、`ReceiveProtocol`（enum）、`RecipientStatus`（struct）、`ScriptedTransport`（class）、`SearchCriteria`（class）、`Secret`（class）、`SendPolicy`（enum）、`SequenceSet`（struct）、`SmtpAuth`（class）、`SmtpAuthMechanism`（enum）、`SmtpCapabilities`（class）、`SmtpClientBuilder`（class）、`SmtpReply`（struct）、`SocketTransportFactory`（class）、`SortCriterion`（enum）、`SortKey`（struct）、`SpecialUse`（enum）、`StoreOperation`（enum）、`StoreResult`（struct）、`StreamBodySource`（class）、`ThreadAlgorithm`（enum）、`ThreadNode`（struct）、`TlsMode`（enum）、`TransferDecoder`（class）、`TransferEncoding`（enum）、`expired`（func）、`isRetryable`（func）、`joinValues`（func）、`remaining`（func）
- `AddressList`：`isEmpty`（func）、`iterator`（func）
- `AppendResult`：`let uidValidity: ?Int64`
- `Base64Codec`：`decode`（func）、`decodeBytes`（func）、`encode`（func）、`encodeUnwrapped`（func）、`encoder`（func）
- `Base64Decoder`：`read`（func）
- `Base64Encoder`：`finish`（func）
- `BodySection`：`entire`（func）、`header`（func）、`headerFields`（func）、`part`（func）
- `BodyStructure`：`contentType`（func）、`isMultipart`（func）、`leafCount`（func）
- `CharsetOptions`：`let fallback: Array<Charset>`
- `CharsetResolver`：`decode`（func）、`encode`（func）、`isKnown`（func）、`resolve`（func）、`tryDecode`（func）
- `ContentDisposition`：`let disposition: String`、`isAttachment`（prop）、`isInline`（prop）、`parameters`（func）
- `ContentType`：`boundary`（func）、`charset`（func）、`charsetName`（func）、`defaultText`（func）、`isMultipart`（func）、`isText`（func）、`mediaType`（prop）、`name`（func）、`parameters`（prop）、`let subtype: String`、`let typeName: String`
- `CopyResult`：`let destUids: ?SequenceSet`、`let sourceUids: ?SequenceSet`、`let uidValidity: ?Int64`
- `DecodedText`：`let charset: Charset`、`let lossy: Bool`
- `DotStuffWriter`：`finish`（func）
- `DotUnstuffReader`：`read`（func）
- `Email`：`isClosed`（func）、`protocol`（prop）
- `EmailAddress`：`address`（prop）、`name`（prop）
- `EmailBuilder`：`allowPlaintextAuth`（func）、`imapTransport`（func）、`pop3Transport`（func）、`requireEncryption`（func）、`smtpTransport`（func）、`timeouts`（func）
- `EncodedWord`：`decode`（func）、`encode`（func）、`needsEncoding`（func）
- `Envelope`：`let recipients: Array<String>`
- `FetchItem`：`bodyStructure`（func）、`internalDate`（func）、`modseq`（func）
- `FetchMeta`：`let bodyStructure: ?BodyStructure`、`let internalDate: ?String`、`let modseq: ?Int64`、`let origin: ?Int64`、`let section: ?String`
- `FetchResult`：`let bodyStructure: ?BodyStructure`、`let internalDate: ?String`、`meta`（func）、`let modseq: ?Int64`、`origin`（let）、`section`（let）
- `FileBodySource`：`isClosed`（func）、`open`（func）、`reusable`（prop）
- `HeaderMap`：`MAX_LINE_OCTETS`（let）、`clear`（func）、`contains`（func）、`entries`（func）、`get`（func）、`getAll`（func）、`isEmpty`（func）、`names`（func）、`remove`（func）、`set`（func）
- `ImapAddress`：`let adl: ?String`、`let host: ?String`、`let mailbox: ?String`、`let name: ?String`
- `ImapCapabilities`：`authMechanisms`（prop）、`hasPrefix`（func）、`isEmpty`（prop）、`let raw: Array<String>`、`supports`（func）、`supportsCondStore`（prop）、`supportsEnable`（prop）、`supportsId`（prop）、`supportsIdle`（prop）、`supportsListExtended`（prop）、`supportsLiteralPlus`（prop）、`supportsLoginDisabled`（prop）、`supportsMove`（prop）、`supportsNamespace`（prop）、`supportsQResync`（prop）、`supportsSaslIr`（prop）、`supportsSort`（prop）、`supportsSortDisplay`（prop）、`supportsSpecialUse`（prop）、`supportsStartTls`（prop）、`supportsThreadOrderedSubject`（prop）、`supportsThreadReferences`（prop）、`supportsUidPlus`（prop）、`supportsUnselect`（prop）、`supportsUtf8Accept`（prop）
- `ImapClient`：`append`（func）、`appendBytes`（func）、`authenticate`（func）、`capabilities`（prop）、`closeMailbox`（func）、`copy`（func）、`enabledCapabilities`（prop）、`examine`（func）、`expunge`（func）、`fetchMessage`（func）、`highestModSeq`（prop）、`isAuthenticated`（prop）、`isClosed`（func）、`isEnabled`（func）、`isReadOnly`（prop）、`logout`（func）、`lsub`（func）、`messages`（prop）、`noop`（func）、`recent`（prop）、`search`（func）、`selected`（prop）、`status`（func）、`store`（func）、`takeExpunged`（func）、`takeVanished`（func）、`uidCopy`（func）、`uidExpunge`（func）、`uidFetch`（func）、`uidFetchMessage`（func）、`uidNext`（prop）、`uidValidity`（prop）、`unselect`（func）
- `ImapClientBuilder`：`allowPlaintextAuth`（func）、`id`（func）、`maxLiteralBytes`（func）、`requireEncryption`（func）、`timeouts`（func）
- `ImapCommandResult`：`code`（func）、`codeArgs`（func）、`isOk`（func）、`let response: ImapResponse`、`let untagged: Array<ImapResponse>`
- `ImapCondStore`：`fetchChangedSince`（func）、`requireSupported`（func）、`storeUnchangedSince`（func）、`takeVanished`（func）、`uidFetchChangedSince`（func）
- `ImapDate`：`let day: ?Int64`、`let hour: ?Int64`、`let minute: ?Int64`、`let month: ?String`、`let raw: String`、`let year: ?Int64`、`let zone: ?String`
- `ImapEnable`：`enable`（func）、`enableCondStore`（func）、`enableQResync`（func）
- `ImapEnvelope`：`let bcc: Array<ImapAddress>`、`let cc: Array<ImapAddress>`、`let date: ?String`、`let inReplyTo: ?String`、`let messageId: ?String`、`let replyTo: Array<ImapAddress>`、`let sender: Array<ImapAddress>`
- `ImapEvent`：`earlier`（let）、`let raw: String`
- `ImapIdle`：`withPollInterval`（func）、`withRebuildAfter`（func）
- `ImapIdleSession`：`done`（func）、`isClosed`（func）、`isFinished`（func）、`rebuildCount`（prop）
- `ImapMove`：`move`（func）、`uidMove`（func）
- `ImapNamespace`：`joinPath`（func）
- `ImapParser`：`MAX_DEPTH`（let）、`MAX_LINE`（let）、`isSafeAtom`（func）、`param`（func）、`parseNumber`（func）、`quoted`（func）
- `ImapResponse`：`let code: ?String`、`let codeArgs: Array<String>`、`firstList`（func）、`isBad`（func）、`isBye`（func）、`isContinuation`（func）、`isNo`（func）、`isOk`（func）、`isTagged`（func）、`isUntagged`（func）、`let name: ?String`、`numberOf`（func）、`raw`（let）、`let status: ?String`、`let tag: ?String`、`let values: Array<ImapValue>`
- `ImapSort`：`sort`（func）、`thread`（func）、`uidSort`（func）、`uidThread`（func）
- `ImapSpecialUse`：`indexBySpecialUse`（func）、`listSpecialUse`（func）、`specialUseOf`（func）
- `ImapUtf7`：`static func decode(text: String, strict!: Bool = false): String`、`encode`（func）、`isAscii`（func）
- `ImapValue`：`isNil`（func）、`items`（func）、`number`（func）
- `LeafBody`：`contentType`（func）、`let description: ?String`、`let disposition: ?(String, Array<(String, String)>)`、`let id: ?String`、`isAttachment`（func）、`let lines: ?Int64`、`let md5: ?String`、`let mediaSubtype: String`、`let mediaType: String`、`param`（func）、`let params: Array<(String, String)>`
- `LineChannel`：`beginSensitive`（func）、`clearDeadline`（func）、`endSensitive`（func）、`flush`（func）、`isClosed`（func）、`lastReadTimedOut`（func）、`pushBack`（func）、`read`（func）、`readExact`（func）、`readLine`（func）、`readLineSoft`（func）、`withDeadline`（func）、`writeLine`（func）
- `MailAttachment`：`let mediaType: String`、`open`（func）、`read`（func）
- `MailAuthException`：`let code: ?Int64`、`let mechanism: String`
- `MailBody`：`let html: ?String`
- `MailConnection`：`channel`（func）、`isClosed`（func）、`isTls`（prop）、`open`（func）、`remoteAddress`（prop）、`setReadTimeout`（func）、`setWriteTimeout`（func）、`startTls`（func）
- `MailDate`：`dateTime`（prop）、`now`（func）、`let offsetMinutes: Int32`、`warnings`（let）
- `MailIoException`：`let stage: IoStage`
- `MailLimitException`：`let actual: Int64`
- `MailMessage`：`bcc`（func）、`cc`（func）、`contentType`（func）、`date`（func）、`headers`（prop）、`html`（func）、`messageId`（func）、`let root: MimePart`
- `MailMessageBuilder`：`bcc`（func）、`cc`（func）、`date`（func）、`header`（func）、`html`（func）
- `MailProtocolException`：`capability`（let）、`let command: ?String`、`let reply: ?String`
- `MailSummary`：`let date: ?MailDate`、`let id: Int64`、`let mailbox: String`
- `MailTimeouts`：`let command: Duration`、`let connect: Duration`、`let data: Duration`、`let greeting: Duration`、`let idle: Duration`
- `MailboxInfo`：`let attributes: Array<String>`、`let delimiter: ?String`、`hasAttribute`（func）、`let name: String`
- `MailboxStatus`：`let highestModSeq: ?Int64`、`let mailbox: String`、`let messages: ?Int64`、`let permanentFlags: Array<String>`、`let readOnly: Bool`、`let recent: ?Int64`、`let uidNext: ?Int64`、`let uidValidity: ?Int64`
- `MemoryBodySource`：`isClosed`（func）、`open`（func）、`reusable`（prop）
- `MimeException`：`let offset: ?Int64`、`let partPath: ?String`
- `MimeParameter`：`formatValue`（func）、`parseExtended`（func）
- `MimeParameters`：`contains`（func）、`entries`（func）、`get`（func）、`isEmpty`（func）
- `MimeParseOptions`：`let defaultCharset: Charset`、`inlineTextLimit`（let）、`let maxBodyBytes: Int64`、`let maxDepth: Int64`、`let maxHeaderBytes: Int64`、`let maxHeaderLine: Int64`、`let maxParts: Int64`、`let spoolDir: ?Path`、`spoolThreshold`（let）
- `MimeParser`：`walk`（func）
- `MimePart`：`charsetLossy`（prop）、`charsetUsed`（prop）、`children`（func）、`collectAttachments`（func）、`contentType`（prop）、`disposition`（prop）、`let headers: HeaderMap`、`isAttachment`（func）、`isMultipart`（func）、`markCharset`（func）、`source`（func）
- `MimeWriteOptions`：`bodyLineLength`（let）、`let boundaryPrefix: String`、`forceEncoding`（let）、`maxBytes`（let）、`maxLineLength`（let）、`utf8Headers`（let）
- `MimeWriter`：`bytesWritten`（func）、`flush`（func）
- `MoveResult`：`atomic`（let）、`let copyUid: CopyResult`、`expunged`（let）、`vanished`（let）、`warnings`（let）
- `MultiBody`：`contentType`（func）、`let disposition: ?(String, Array<(String, String)>)`、`let mediaSubtype: String`、`param`（func）、`let params: Array<(String, String)>`、`let parts: Array<BodyStructure>`
- `Multipart`：`let boundary: String`、`epilogue`（let）、`let parts: Array<MimePart>`、`preamble`（let）
- `NamespaceEntry`：`let delimiter: ?String`、`let prefix: String`
- `NamespaceInfo`：`let otherUsers: Array<NamespaceEntry>`、`let personal: Array<NamespaceEntry>`、`primaryDelimiter`（func）、`primaryPrefix`（func）、`let shared: Array<NamespaceEntry>`
- `Pop3Capabilities`：`args`（func）、`authMechanisms`（prop）、`let entries: Array<Pop3Capability>`、`expire`（prop）、`get`（func）、`implementation`（prop）、`isEmpty`（prop）、`supports`（func）、`supportsPipelining`（prop）、`supportsRespCodes`（prop）、`supportsStls`（prop）、`supportsTop`（prop）、`supportsUidl`（prop）、`supportsUser`（prop）
- `Pop3Capability`：`let args: Array<String>`、`let name: String`
- `Pop3Client`：`apop`（func）、`authenticate`（func）、`capabilities`（prop）、`dele`（func）、`greeting`（prop）、`isAuthenticated`（prop）、`isClosed`（func）、`isDeleteCommitted`（prop）、`noop`（func）、`pendingDeletes`（prop）、`retr`（func）、`rset`（func）、`stat`（func）、`top`（func）、`topMessage`（func）、`uidl`（func）
- `Pop3ClientBuilder`：`allowPlaintextAuth`（func）、`requireEncryption`（func）、`timeouts`（func）
- `Pop3MessageInfo`：`let number: Int64`
- `Pop3Reply`：`errorCode`（let）、`errorKind`（func）、`isOk`（func）、`let ok: Bool`、`read`（func）
- `Pop3Stat`：`let messages: Int64`
- `Pop3Uidl`：`let number: Int64`
- `QResyncParams`：`let knownSeqUids: ?SequenceSet`、`knownSeqs`（let）、`knownUids`（let）、`let modseq: Int64`、`let uidValidity: Int64`
- `QuotedPrintable`：`static let HEX =`、`decode`（func）、`decoder`（func）、`encode`（func）、`encoder`（func）
- `QuotedPrintableDecoder`：`read`（func）
- `QuotedPrintableEncoder`：`finish`（func）
- `RecipientStatus`：`let accepted: Bool`、`let address: String`、`let code: Int64`、`let enhanced: ?String`
- `ScriptedTransport`：`clearRecorded`（func）、`connect`（func）、`pushServer`（func）、`recorded`（func）、`recordedText`（func）
- `SearchCriteria`：`all`（func）、`andAll`（func）、`answered`（func）、`bcc`（func）、`before`（func）、`cc`（func）、`deleted`（func）、`draft`（func）、`flagged`（func）、`header`（func）、`keyword`（func）、`larger`（func）、`needsUtf8`（func）、`negate`（func）、`newMessages`（func）、`old`（func）、`on`（func）、`orAny`（func）、`orWith`（func）、`recent`（func）、`seen`（func）、`sentBefore`（func）、`sentSince`（func）、`since`（func）、`smaller`（func）、`unanswered`（func）、`undeleted`（func）、`undraft`（func）、`unflagged`（func）、`unkeyword`（func）
- `Secret`：`use`（func）
- `SendReport`：`let aborted: Bool`、`let accepted: Array<RecipientStatus>`、`isCompleteSuccess`（func）、`isRetryable`（func）、`let messageId: String`、`let reply: SmtpReply`
- `SequenceSet`：`all`（func）、`single`（func）
- `SmtpAuth`：`cramMd5Response`（func）、`loginPassword`（func）、`loginUser`（func）、`plainToken`（func）、`xoauth2Token`（func）
- `SmtpCapabilities`：`authMechanisms`（prop）、`has`（func）、`supports8BitMime`（prop）、`supportsDsn`（prop）、`supportsEnhancedStatusCodes`（prop）、`supportsPipelining`（prop）、`supportsSmtpUtf8`（prop）、`supportsStartTls`（prop）、`value`（func）
- `SmtpClient`：`capabilities`（prop）、`isClosed`（func）、`noop`（func）、`reset`（func）
- `SmtpClientBuilder`：`allowPlaintextAuth`（func）、`dsn`（func）、`helloName`（func）、`maxMessageBytes`（func）、`oauth2`（func）、`precomputeSize`（func）、`requireEncryption`（func）、`sendPolicy`（func）、`timeouts`（func）
- `SmtpReply`：`let code: Int64`、`enhanced`（let）、`isIntermediate`（func）、`isPermanentFailure`（func）、`isSuccess`（func）、`isTemporaryFailure`（func）、`let lines: Array<String>`、`read`（func）
- `SocketTransportFactory`：`connect`（func）
- `SortCriterion`：`requiresDisplayCapability`（func）
- `SortKey`：`let criterion: SortCriterion`、`let reverse: Bool`
- `Spool`：`createFile`（func）、`resolveDirectory`（func）
- `StoreResult`：`isPartialFailure`（func）、`modified`（let）、`updated`（let）
- `StreamBodySource`：`isClosed`（func）、`open`（func）、`reusable`（prop）
- `ThreadAlgorithm`：`capability`（func）
- `ThreadNode`：`let children: Array<ThreadNode>`、`flatten`（func）
- `TransferDecoder`：`static func stream(`
