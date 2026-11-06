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

// read body and attachments (read-only)
let body = email.body(summaries[0])
for (attachment in body.attachments) {
    attachment.saveTo(Path("download/${attachment.filename}"))
}

// delete: IMAP deletes by UID; POP3 commits with DELE + QUIT
email.delete(summaries[0])
email.close()
```

| Contract | Behaviour |
|---|---|
| Lazy connections | `build()` connects to nothing; `send` opens SMTP, `list` / `fetch` / `delete` open the receive protocol |
| Locate by summary | `list` returns `MailSummary`; IMAP locates by UID so an `EXPUNGE` between calls cannot delete the wrong mail |
| Reads are read-only | `list` / `body` use `EXAMINE` + `BODY.PEEK[]`; deleting is always an explicit `delete` |

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
    .build()

let report = client.send(message)   // partial rejection does not throw; inspect report.rejected
client.close()
```

### Receiving (POP3)

```cangjie
let client = Pop3Client.builder("pop.example.com", port: 995).tls(TlsMode.Implicit).build()
client.login("user", Secret.of("password"))
let message = client.retrMessage(1)   // RETR feeds MimeParser directly
client.quit()                         // deletions commit only after +OK for QUIT
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

let ids = client.uidSearch(
    SearchCriteria.unseen().andWith(SearchCriteria.from("boss@example.com"))
)
```

### IDLE

```cangjie
ImapEnable(client).enableUtf8Accept()
let session = ImapIdle(client).start()      // rebuilds IDLE before the 30-minute cap
while (true) {
    match (session.nextEvent(timeout: Duration.second * 30)) {
        case Some(event) => println("${event.kind} ${event.sequence}")
        case None => ()                     // a timeout is not an error; the connection stays open
    }
}
session.close()
```

## STDX dependency

```shell
export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx
```

## Not yet verified

- TLS and `Spool` behaviour on OHOS (no device available).
- Dovecot / 163 extension error matrix (QQ Mail IMAP/SMTP round trip has been verified).
- Automated self-signed TLS cases (currently covered by the G6 / P-0 manual probes).
