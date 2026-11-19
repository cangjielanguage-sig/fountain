# f_email

Email client module: SMTP / POP3 / IMAP4rev1 + MIME parsing and generation.

- Package: `fountain::f_email` (plus `f_email.transport` / `f_email.mime` / `f_email.smtp` / `f_email.pop3` / `f_email.imap`)
- Dependencies: `f_base`, `f_io`, `f_log`, `f_random`, `charset4cj`, `stdx` (tls / base64 / digest / x509)
- Design document: [`doc/f_email设计文档.md`](doc/f_email设计文档.md)

## Status

Milestones M0 → M4 are implemented, each with unit tests.

- **M0 transport**: `MailConnection` / `LineChannel` / `DotStuff` / `MailTrace` /
  `TransportFactory` (including a scripted test transport with byte-level recording).
- **M1 message model and MIME**: `HeaderMap`, addresses/dates, `CharsetResolver`,
  base64/QP, RFC 2047/2231, `MimePart`/`MailMessage`, streaming `MimeParser` and `MimeWriter`.
- **M1-e SMTP**: connect/EHLO/STARTTLS/AUTH (PLAIN, LOGIN, CRAM-MD5, XOAUTH2),
  delivery transaction, PIPELINING, per-recipient `SendReport`, Bcc stripping,
  SIZE pre-check, 8BITMIME / SMTPUTF8.
- **M2 POP3**: `Pop3Client` (`CAPA`/`STLS`, `USER`+`PASS`, `APOP`, `AUTH PLAIN`/`LOGIN`,
  `STAT`/`LIST`/`UIDL`, streaming `RETR`/`TOP`, `DELE`/`RSET`/`QUIT`) and `-ERR`
  response-code classification.
- **M3 IMAP core**: tag-driven command loop, modified UTF-7, tokenizer, `SELECT`/`EXAMINE`/
  `STATUS`/`LIST`/`LSUB`, `FETCH` (streaming and in-memory literal paths), `BODYSTRUCTURE`,
  `ENVELOPE`, `INTERNALDATE`, `SEARCH`, `STORE`/`COPY`/`EXPUNGE`, `APPEND`, `LOGOUT`.
- **M4 IMAP extensions**: `ENABLE` negotiation, `IDLE` (reader thread + bounded queue +
  25-minute rebuild), `MOVE` (with explicit non-atomic fallback), `SPECIAL-USE`,
  `NAMESPACE`, `UTF8=ACCEPT`, `CONDSTORE`/`QRESYNC`, `SORT`/`THREAD`.
- **Unified facade**: `Email` owns all three protocols — send, list (subject + received
  time), read body, fetch attachments, delete a specific mail. Lazy connections; reads use
  `EXAMINE` + `BODY.PEEK[]`; deletion targets a single UID.

Full `cjpm test`: **275 passed / 0 failed**. Verified against a real server: QQ Mail SMTP 465
send, IMAP 993 list/body/attachment (including a 1.6 MB pptx and a long non-ASCII subject).

Per-task acceptance: `doc/spec/add-f-email-client/tasks.md`; verification log in the same folder.

## Usage

### Unified facade (`fountain::f_email.Email`)

One class owns SMTP / IMAP / POP3: send, list, read body, fetch attachments, delete.
The `SmtpClient` / `ImapClient` / `Pop3Client` types below are its building blocks.

```cangjie
let email = Email.builder()
    .smtp("smtp.example.com", port: 465)
    .imap("imap.example.com", port: 993)      // or .pop3(...) + receiveVia(ReceiveProtocol.Pop3)
    .auth("user@example.com", Secret.of("password"))
    .build()                                   // lazy: no connection yet

// send
let report = email.send(
    MailMessage.builder()
        .from("user@example.com")
        .to("friend@example.com")
        .subject("hello")
        .text("body")
        .attach("report.pdf", FileBodySource(Path("report.pdf")))
        .build()
)

// list: subject + received time + unread flag (IMAP uses EXAMINE, never sets \Seen)
let summaries = email.list(limit: 20)
for (summary in summaries) {
    var received = "?"
    match (summary.receivedAt) {
        case Some(value) => received = value.toString()
        case None => ()
    }
    println("${summary.subject}  ${received}  unread=${summary.isUnread()}")
}

// read body and attachments (read-only)
let body = email.body(summaries[0])
let text = body.text ?? ""
for (attachment in body.attachments) {
    println("${attachment.filename} ${attachment.size} B")
    attachment.saveTo(Path("download/${attachment.filename}"))
}

// delete: IMAP deletes by UID; POP3 commits with DELE + QUIT
email.delete(summaries[0])
email.close()
```

| Contract | Behaviour |
|---|---|
| Lazy connections | `build()` connects to nothing; the first `send` opens SMTP, the first `list` / `fetch` / `delete` opens the receive protocol. Sending only does not require IMAP to be reachable. |
| Locate by summary | `list` returns `MailSummary`; reads and deletes take that summary. IMAP locates by UID, so an `EXPUNGE` in between cannot shift sequence numbers and delete the wrong mail. |
| Reads are read-only | `list` / `body` use `EXAMINE` + `BODY.PEEK[]` and never modify `\Seen`; deleting is always an explicit `delete` call. |

### Sending (SMTP)

```cangjie
let client = SmtpClient.builder("smtp.example.com", port: 465)
    .tls(TlsMode.Implicit)
    .auth(SmtpAuthMechanism.Plain, "user@example.com", Secret.of("password"))
    .build()

let message = MailMessage.builder()
    .from("user@example.com")
    .to("friend@example.com")
    .subject("hello")
    .text("body")
    .attach("report.pdf", FileBodySource(Path("report.pdf")))
    .build()

let report = client.send(message)   // partial rejection does not throw; inspect report.rejected
client.close()
```

### Receiving (POP3)

```cangjie
let client = Pop3Client.builder("pop.example.com", port: 995).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
let list = client.list()                 // sequence number and size of every message
let message = client.retrMessage(1)      // RETR feeds MimeParser directly
let text = message.text()
client.quit()                            // deletions commit only after +OK for QUIT
```

### Reading (IMAP)

```cangjie
let client = ImapClient.builder("imap.example.com", port: 993).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
client.select("INBOX")

// Headers only: \Seen is not set
let heads = client.fetch(
    SequenceSet.range(1, 10),
    [FetchItem.uid(), FetchItem.envelope(), FetchItem.flags()]
)

// Only unread mail from one sender
let ids = client.uidSearch(
    SearchCriteria.unseen().andWith(SearchCriteria.from("boss@example.com"))
)
```

### IDLE (server push)

```cangjie
let enabled = ImapEnable(client).enableUtf8Accept()
let session = ImapIdle(client).start()      // by default re-issues DONE and rebuilds after 25 minutes
while (true) {
    match (session.nextEvent(timeout: Duration.second * 30)) {
        case Some(event) => println("${event.kind} ${event.sequence}")
        case None => ()                     // a timeout is not an error; the connection stays open
    }
}
session.close()                             // sends DONE and cleans up
```

### MIME encoding and decoding

```cangjie
// parse: decoded text up to 256 KB stays in memory, the rest spills to a temp file (mode 0600)
let message = MimeParser.parse(input, options: MimeParseOptions(strict: false))
let attachments = message.attachments()

// generate: allow8Bit=true when the target supports 8BITMIME
MimeWriter(target, options: MimeWriteOptions(allow8Bit: true)).write(message)
```

## Environment requirements

`CANGJIE_STDX_DYNAMIC_PATH` must point at the stdx dynamic-library directory before building:

```shell
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

### P-0 dependency probe results (2026-10-28, Linux aarch64)

| Item | Result |
|---|---|
| `stdx.net.tls` | `TlsSocket.client` connected to `smtp.163.com:465`, negotiated TLS 1.3 + `TLS_AES_256_GCM_SHA384`, the system CA chain (3 certificates) verified, default `CertificateVerifyMode.Default` works. **Not verified on the OHOS target** (no device); the designed fallback (caller-injected `TlsClientConfig` + self-signed CA) is kept, `TrustAll` is never the default. |
| `charset4cj` 1.0.5 | GBK / GB18030 / BIG5 / WINDOWS_1252 decode the Chinese samples correctly (`中文测试`, `中文測試`, `éÿ`). |
| `stdx.encoding.base64` | **Not lenient**: missing padding (`SGVsbG8`) and embedded whitespace (`SGVs bG8=\n`) both return `None`, as do illegal characters. `mime/Base64Codec` therefore strips whitespace, adds padding and handles illegal characters in lenient / strict modes itself. |
| `stdx.crypto.digest` | `MD5` / `HMAC(key, HashType.MD5)` + `toHexString` emit **lowercase** hex, usable directly for CRAM-MD5 and APOP digests. |

Verification: one-off probe tests (removed from the repository afterwards), asserting / printing the results above.

## Not yet verified

- TLS and `Spool` behaviour on OHOS (no device available).
- Dovecot / 163 extension error matrix (QQ Mail IMAP/SMTP round trip has been verified).
- Automated self-signed TLS cases (currently covered by the G6 / P-0 manual probes).

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `AddressList` (class), `AppendResult` (struct), `Base64Decoder` (class), `Base64Encoder` (class), `BodySection` (struct), `BodySource` (interface), `BodyStructure` (enum), `CharsetOptions` (struct), `ContentDisposition` (class), `ContentType` (class), `CopyResult` (struct), `DecodedText` (struct), `DotStuffWriter` (class), `DotUnstuffReader` (class), `DsnNotify` (enum), `DsnReturn` (enum), `EmailAddress` (class), `EmailBuilder` (class), `EncodedWord` (class), `Envelope` (class), `F_EMAIL_VERSION` (let), `FetchItem` (struct), `FetchMeta` (struct), `FetchResult` (struct), `FetchSink` (interface), `ImapAddress` (struct), `ImapAuthMechanism` (enum), `ImapCapabilities` (struct), `ImapClientBuilder` (class), `ImapCommandResult` (struct), `ImapCondStore` (class), `ImapDate` (struct), `ImapEnvelope` (struct), `ImapEvent` (struct), `ImapEventKind` (enum), `ImapIdleSession` (class), `ImapMove` (class), `ImapNamespace` (class), `ImapParser` (class), `ImapResponse` (struct), `ImapResponseKind` (enum), `ImapSort` (class), `ImapSpecialUse` (class), `ImapUtf7` (class), `ImapValue` (enum), `IoStage` (enum), `IoTimeout` (interface), `LeafBody` (struct), `LimitKind` (enum), `MailAttachment` (class), `MailAuthException` (class), `MailBody` (class), `MailDate` (class), `MailException` (class), `MailIoException` (class), `MailLimitException` (class), `MailMessageBuilder` (class), `MailProtocolException` (class), `MailTimeouts` (struct), `MailTlsException` (class), `MailboxInfo` (struct), `MailboxStatus` (struct), `MemoryBodySource` (class), `MimeAction` (enum), `MimeException` (class), `MimeParameter` (class), `MimeParameters` (class), `MimeVisitor` (interface), `MoveResult` (struct), `MultiBody` (struct), `Multipart` (class), `NamespaceEntry` (struct), `NamespaceInfo` (struct), `PartBody` (enum), `Pop3AuthMechanism` (enum), `Pop3Capabilities` (struct), `Pop3Capability` (struct), `Pop3ClientBuilder` (class), `Pop3ErrorKind` (enum), `Pop3MessageInfo` (struct), `Pop3Reply` (struct), `Pop3Stat` (struct), `Pop3Uidl` (struct), `QResyncParams` (struct), `QuotedPrintable` (class), `QuotedPrintableDecoder` (class), `QuotedPrintableEncoder` (class), `ReceiveProtocol` (enum), `RecipientStatus` (struct), `ScriptedTransport` (class), `SearchCriteria` (class), `Secret` (class), `SendPolicy` (enum), `SequenceSet` (struct), `SmtpAuth` (class), `SmtpAuthMechanism` (enum), `SmtpCapabilities` (class), `SmtpClientBuilder` (class), `SmtpReply` (struct), `SocketTransportFactory` (class), `SortCriterion` (enum), `SortKey` (struct), `SpecialUse` (enum), `StoreOperation` (enum), `StoreResult` (struct), `StreamBodySource` (class), `ThreadAlgorithm` (enum), `ThreadNode` (struct), `TlsMode` (enum), `TransferDecoder` (class), `TransferEncoding` (enum), `expired` (func), `isRetryable` (func), `joinValues` (func), `remaining` (func)
- `AddressList`: `isEmpty` (func), `iterator` (func)
- `AppendResult`: `let uidValidity: ?Int64`
- `Base64Codec`: `decode` (func), `decodeBytes` (func), `encode` (func), `encodeUnwrapped` (func), `encoder` (func)
- `Base64Decoder`: `read` (func)
- `Base64Encoder`: `finish` (func)
- `BodySection`: `entire` (func), `header` (func), `headerFields` (func), `part` (func)
- `BodyStructure`: `contentType` (func), `isMultipart` (func), `leafCount` (func)
- `CharsetOptions`: `let fallback: Array<Charset>`
- `CharsetResolver`: `decode` (func), `encode` (func), `isKnown` (func), `resolve` (func), `tryDecode` (func)
- `ContentDisposition`: `let disposition: String`, `isAttachment` (prop), `isInline` (prop), `parameters` (func)
- `ContentType`: `boundary` (func), `charset` (func), `charsetName` (func), `defaultText` (func), `isMultipart` (func), `isText` (func), `mediaType` (prop), `name` (func), `parameters` (prop), `let subtype: String`, `let typeName: String`
- `CopyResult`: `let destUids: ?SequenceSet`, `let sourceUids: ?SequenceSet`, `let uidValidity: ?Int64`
- `DecodedText`: `let charset: Charset`, `let lossy: Bool`
- `DotStuffWriter`: `finish` (func)
- `DotUnstuffReader`: `read` (func)
- `Email`: `isClosed` (func), `protocol` (prop)
- `EmailAddress`: `address` (prop), `name` (prop)
- `EmailBuilder`: `allowPlaintextAuth` (func), `imapTransport` (func), `pop3Transport` (func), `requireEncryption` (func), `smtpTransport` (func), `timeouts` (func)
- `EncodedWord`: `decode` (func), `encode` (func), `needsEncoding` (func)
- `Envelope`: `let recipients: Array<String>`
- `FetchItem`: `bodyStructure` (func), `internalDate` (func), `modseq` (func)
- `FetchMeta`: `let bodyStructure: ?BodyStructure`, `let internalDate: ?String`, `let modseq: ?Int64`, `let origin: ?Int64`, `let section: ?String`
- `FetchResult`: `let bodyStructure: ?BodyStructure`, `let internalDate: ?String`, `meta` (func), `let modseq: ?Int64`, `origin` (let), `section` (let)
- `FileBodySource`: `isClosed` (func), `open` (func), `reusable` (prop)
- `HeaderMap`: `MAX_LINE_OCTETS` (let), `clear` (func), `contains` (func), `entries` (func), `get` (func), `getAll` (func), `isEmpty` (func), `names` (func), `remove` (func), `set` (func)
- `ImapAddress`: `let adl: ?String`, `let host: ?String`, `let mailbox: ?String`, `let name: ?String`
- `ImapCapabilities`: `authMechanisms` (prop), `hasPrefix` (func), `isEmpty` (prop), `let raw: Array<String>`, `supports` (func), `supportsCondStore` (prop), `supportsEnable` (prop), `supportsId` (prop), `supportsIdle` (prop), `supportsListExtended` (prop), `supportsLiteralPlus` (prop), `supportsLoginDisabled` (prop), `supportsMove` (prop), `supportsNamespace` (prop), `supportsQResync` (prop), `supportsSaslIr` (prop), `supportsSort` (prop), `supportsSortDisplay` (prop), `supportsSpecialUse` (prop), `supportsStartTls` (prop), `supportsThreadOrderedSubject` (prop), `supportsThreadReferences` (prop), `supportsUidPlus` (prop), `supportsUnselect` (prop), `supportsUtf8Accept` (prop)
- `ImapClient`: `append` (func), `appendBytes` (func), `authenticate` (func), `capabilities` (prop), `closeMailbox` (func), `copy` (func), `enabledCapabilities` (prop), `examine` (func), `expunge` (func), `fetchMessage` (func), `highestModSeq` (prop), `isAuthenticated` (prop), `isClosed` (func), `isEnabled` (func), `isReadOnly` (prop), `logout` (func), `lsub` (func), `messages` (prop), `noop` (func), `recent` (prop), `search` (func), `selected` (prop), `status` (func), `store` (func), `takeExpunged` (func), `takeVanished` (func), `uidCopy` (func), `uidExpunge` (func), `uidFetch` (func), `uidFetchMessage` (func), `uidNext` (prop), `uidValidity` (prop), `unselect` (func)
- `ImapClientBuilder`: `allowPlaintextAuth` (func), `id` (func), `maxLiteralBytes` (func), `requireEncryption` (func), `timeouts` (func)
- `ImapCommandResult`: `code` (func), `codeArgs` (func), `isOk` (func), `let response: ImapResponse`, `let untagged: Array<ImapResponse>`
- `ImapCondStore`: `fetchChangedSince` (func), `requireSupported` (func), `storeUnchangedSince` (func), `takeVanished` (func), `uidFetchChangedSince` (func)
- `ImapDate`: `let day: ?Int64`, `let hour: ?Int64`, `let minute: ?Int64`, `let month: ?String`, `let raw: String`, `let year: ?Int64`, `let zone: ?String`
- `ImapEnable`: `enable` (func), `enableCondStore` (func), `enableQResync` (func)
- `ImapEnvelope`: `let bcc: Array<ImapAddress>`, `let cc: Array<ImapAddress>`, `let date: ?String`, `let inReplyTo: ?String`, `let messageId: ?String`, `let replyTo: Array<ImapAddress>`, `let sender: Array<ImapAddress>`
- `ImapEvent`: `earlier` (let), `let raw: String`
- `ImapIdle`: `withPollInterval` (func), `withRebuildAfter` (func)
- `ImapIdleSession`: `done` (func), `isClosed` (func), `isFinished` (func), `rebuildCount` (prop)
- `ImapMove`: `move` (func), `uidMove` (func)
- `ImapNamespace`: `joinPath` (func)
- `ImapParser`: `MAX_DEPTH` (let), `MAX_LINE` (let), `isSafeAtom` (func), `param` (func), `parseNumber` (func), `quoted` (func)
- `ImapResponse`: `let code: ?String`, `let codeArgs: Array<String>`, `firstList` (func), `isBad` (func), `isBye` (func), `isContinuation` (func), `isNo` (func), `isOk` (func), `isTagged` (func), `isUntagged` (func), `let name: ?String`, `numberOf` (func), `raw` (let), `let status: ?String`, `let tag: ?String`, `let values: Array<ImapValue>`
- `ImapSort`: `sort` (func), `thread` (func), `uidSort` (func), `uidThread` (func)
- `ImapSpecialUse`: `indexBySpecialUse` (func), `listSpecialUse` (func), `specialUseOf` (func)
- `ImapUtf7`: `static func decode(text: String, strict!: Bool = false): String`, `encode` (func), `isAscii` (func)
- `ImapValue`: `isNil` (func), `items` (func), `number` (func)
- `LeafBody`: `contentType` (func), `let description: ?String`, `let disposition: ?(String, Array<(String, String)>)`, `let id: ?String`, `isAttachment` (func), `let lines: ?Int64`, `let md5: ?String`, `let mediaSubtype: String`, `let mediaType: String`, `param` (func), `let params: Array<(String, String)>`
- `LineChannel`: `beginSensitive` (func), `clearDeadline` (func), `endSensitive` (func), `flush` (func), `isClosed` (func), `lastReadTimedOut` (func), `pushBack` (func), `read` (func), `readExact` (func), `readLine` (func), `readLineSoft` (func), `withDeadline` (func), `writeLine` (func)
- `MailAttachment`: `let mediaType: String`, `open` (func), `read` (func)
- `MailAuthException`: `let code: ?Int64`, `let mechanism: String`
- `MailBody`: `let html: ?String`
- `MailConnection`: `channel` (func), `isClosed` (func), `isTls` (prop), `open` (func), `remoteAddress` (prop), `setReadTimeout` (func), `setWriteTimeout` (func), `startTls` (func)
- `MailDate`: `dateTime` (prop), `now` (func), `let offsetMinutes: Int32`, `warnings` (let)
- `MailIoException`: `let stage: IoStage`
- `MailLimitException`: `let actual: Int64`
- `MailMessage`: `bcc` (func), `cc` (func), `contentType` (func), `date` (func), `headers` (prop), `html` (func), `messageId` (func), `let root: MimePart`
- `MailMessageBuilder`: `bcc` (func), `cc` (func), `date` (func), `header` (func), `html` (func)
- `MailProtocolException`: `capability` (let), `let command: ?String`, `let reply: ?String`
- `MailSummary`: `let date: ?MailDate`, `let id: Int64`, `let mailbox: String`
- `MailTimeouts`: `let command: Duration`, `let connect: Duration`, `let data: Duration`, `let greeting: Duration`, `let idle: Duration`
- `MailboxInfo`: `let attributes: Array<String>`, `let delimiter: ?String`, `hasAttribute` (func), `let name: String`
- `MailboxStatus`: `let highestModSeq: ?Int64`, `let mailbox: String`, `let messages: ?Int64`, `let permanentFlags: Array<String>`, `let readOnly: Bool`, `let recent: ?Int64`, `let uidNext: ?Int64`, `let uidValidity: ?Int64`
- `MemoryBodySource`: `isClosed` (func), `open` (func), `reusable` (prop)
- `MimeException`: `let offset: ?Int64`, `let partPath: ?String`
- `MimeParameter`: `formatValue` (func), `parseExtended` (func)
- `MimeParameters`: `contains` (func), `entries` (func), `get` (func), `isEmpty` (func)
- `MimeParseOptions`: `let defaultCharset: Charset`, `inlineTextLimit` (let), `let maxBodyBytes: Int64`, `let maxDepth: Int64`, `let maxHeaderBytes: Int64`, `let maxHeaderLine: Int64`, `let maxParts: Int64`, `let spoolDir: ?Path`, `spoolThreshold` (let)
- `MimeParser`: `walk` (func)
- `MimePart`: `charsetLossy` (prop), `charsetUsed` (prop), `children` (func), `collectAttachments` (func), `contentType` (prop), `disposition` (prop), `let headers: HeaderMap`, `isAttachment` (func), `isMultipart` (func), `markCharset` (func), `source` (func)
- `MimeWriteOptions`: `bodyLineLength` (let), `let boundaryPrefix: String`, `forceEncoding` (let), `maxBytes` (let), `maxLineLength` (let), `utf8Headers` (let)
- `MimeWriter`: `bytesWritten` (func), `flush` (func)
- `MoveResult`: `atomic` (let), `let copyUid: CopyResult`, `expunged` (let), `vanished` (let), `warnings` (let)
- `MultiBody`: `contentType` (func), `let disposition: ?(String, Array<(String, String)>)`, `let mediaSubtype: String`, `param` (func), `let params: Array<(String, String)>`, `let parts: Array<BodyStructure>`
- `Multipart`: `let boundary: String`, `epilogue` (let), `let parts: Array<MimePart>`, `preamble` (let)
- `NamespaceEntry`: `let delimiter: ?String`, `let prefix: String`
- `NamespaceInfo`: `let otherUsers: Array<NamespaceEntry>`, `let personal: Array<NamespaceEntry>`, `primaryDelimiter` (func), `primaryPrefix` (func), `let shared: Array<NamespaceEntry>`
- `Pop3Capabilities`: `args` (func), `authMechanisms` (prop), `let entries: Array<Pop3Capability>`, `expire` (prop), `get` (func), `implementation` (prop), `isEmpty` (prop), `supports` (func), `supportsPipelining` (prop), `supportsRespCodes` (prop), `supportsStls` (prop), `supportsTop` (prop), `supportsUidl` (prop), `supportsUser` (prop)
- `Pop3Capability`: `let args: Array<String>`, `let name: String`
- `Pop3Client`: `apop` (func), `authenticate` (func), `capabilities` (prop), `dele` (func), `greeting` (prop), `isAuthenticated` (prop), `isClosed` (func), `isDeleteCommitted` (prop), `noop` (func), `pendingDeletes` (prop), `retr` (func), `rset` (func), `stat` (func), `top` (func), `topMessage` (func), `uidl` (func)
- `Pop3ClientBuilder`: `allowPlaintextAuth` (func), `requireEncryption` (func), `timeouts` (func)
- `Pop3MessageInfo`: `let number: Int64`
- `Pop3Reply`: `errorCode` (let), `errorKind` (func), `isOk` (func), `let ok: Bool`, `read` (func)
- `Pop3Stat`: `let messages: Int64`
- `Pop3Uidl`: `let number: Int64`
- `QResyncParams`: `let knownSeqUids: ?SequenceSet`, `knownSeqs` (let), `knownUids` (let), `let modseq: Int64`, `let uidValidity: Int64`
- `QuotedPrintable`: `static let HEX =`, `decode` (func), `decoder` (func), `encode` (func), `encoder` (func)
- `QuotedPrintableDecoder`: `read` (func)
- `QuotedPrintableEncoder`: `finish` (func)
- `RecipientStatus`: `let accepted: Bool`, `let address: String`, `let code: Int64`, `let enhanced: ?String`
- `ScriptedTransport`: `clearRecorded` (func), `connect` (func), `pushServer` (func), `recorded` (func), `recordedText` (func)
- `SearchCriteria`: `all` (func), `andAll` (func), `answered` (func), `bcc` (func), `before` (func), `cc` (func), `deleted` (func), `draft` (func), `flagged` (func), `header` (func), `keyword` (func), `larger` (func), `needsUtf8` (func), `negate` (func), `newMessages` (func), `old` (func), `on` (func), `orAny` (func), `orWith` (func), `recent` (func), `seen` (func), `sentBefore` (func), `sentSince` (func), `since` (func), `smaller` (func), `unanswered` (func), `undeleted` (func), `undraft` (func), `unflagged` (func), `unkeyword` (func)
- `Secret`: `use` (func)
- `SendReport`: `let aborted: Bool`, `let accepted: Array<RecipientStatus>`, `isCompleteSuccess` (func), `isRetryable` (func), `let messageId: String`, `let reply: SmtpReply`
- `SequenceSet`: `all` (func), `single` (func)
- `SmtpAuth`: `cramMd5Response` (func), `loginPassword` (func), `loginUser` (func), `plainToken` (func), `xoauth2Token` (func)
- `SmtpCapabilities`: `authMechanisms` (prop), `has` (func), `supports8BitMime` (prop), `supportsDsn` (prop), `supportsEnhancedStatusCodes` (prop), `supportsPipelining` (prop), `supportsSmtpUtf8` (prop), `supportsStartTls` (prop), `value` (func)
- `SmtpClient`: `capabilities` (prop), `isClosed` (func), `noop` (func), `reset` (func)
- `SmtpClientBuilder`: `allowPlaintextAuth` (func), `dsn` (func), `helloName` (func), `maxMessageBytes` (func), `oauth2` (func), `precomputeSize` (func), `requireEncryption` (func), `sendPolicy` (func), `timeouts` (func)
- `SmtpReply`: `let code: Int64`, `enhanced` (let), `isIntermediate` (func), `isPermanentFailure` (func), `isSuccess` (func), `isTemporaryFailure` (func), `let lines: Array<String>`, `read` (func)
- `SocketTransportFactory`: `connect` (func)
- `SortCriterion`: `requiresDisplayCapability` (func)
- `SortKey`: `let criterion: SortCriterion`, `let reverse: Bool`
- `Spool`: `createFile` (func), `resolveDirectory` (func)
- `StoreResult`: `isPartialFailure` (func), `modified` (let), `updated` (let)
- `StreamBodySource`: `isClosed` (func), `open` (func), `reusable` (prop)
- `ThreadAlgorithm`: `capability` (func)
- `ThreadNode`: `let children: Array<ThreadNode>`, `flatten` (func)
- `TransferDecoder`: `static func stream(`
