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

Per-task progress and acceptance criteria: `openspec/changes/add-f-email-client/tasks.md`.

## Usage

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
- Real-server interoperability (Postfix / Dovecot / 163): the G6 manual items in `tasks.md`
  are still outstanding.
- The IDLE 25-minute rebuild is covered by implementation only; the scripted transport cannot
  simulate a server that stays silent for 25 minutes.
