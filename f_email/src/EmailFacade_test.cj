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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*
import fountain::f_email.transport.*
import fountain::f_email.imap.*
import fountain::f_email.pop3.*
import fountain::f_email.smtp.*

/** IMAP 的问候 + 能力 + 登录，供各用例拼接后续脚本。 */
func facadeImapPrefix(): String {
    "* OK ready\r\n" +
        "* CAPABILITY IMAP4rev1 UIDPLUS\r\n" +
        "A0000 OK done\r\n" +
        "A0001 OK LOGIN completed\r\n"
}

func facadeImapEmail(server: String): (Email, ScriptedTransport) {
    let transport = ScriptedTransport(server: facadeImapPrefix() + server)
    let email = Email.builder()
        .imap("localhost", port: 143)
        .tls(TlsMode.None)
        .requireEncryption(false)
        .allowPlaintextAuth(true)
        .auth("u", Secret.of("p"))
        .imapTransport(transport)
        .build()
    (email, transport)
}

func facadePop3Email(server: String): (Email, ScriptedTransport) {
    let transport = ScriptedTransport(server: server)
    let email = Email.builder()
        .pop3("localhost", port: 110)
        .receiveVia(ReceiveProtocol.Pop3)
        .tls(TlsMode.None)
        .requireEncryption(false)
        .allowPlaintextAuth(true)
        .auth("u", Secret.of("p"))
        .pop3Transport(transport)
        .build()
    (email, transport)
}

@Test
public class EmailFacade_test {
    @TestCase
    public func buildAllowsSendOnlyButRejectsProtocolMismatch(): Unit {
        // 只发信：不给收件服务器也能建
        let sendOnly = Email.builder().smtp("smtp.example.com").build()
        @Assert(sendOnly.protocol.toString(), "IMAP")
        sendOnly.close()

        // 配了 POP3 却仍用默认 IMAP，属于配置矛盾，必须当场报错
        var caught = false
        try {
            Email.builder().pop3("pop.example.com").build()
        } catch (_: IllegalArgumentException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func sendDelegatesToSmtp(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250 smtp.example.com\r\n" +
                "250 sender ok\r\n" +
                "250 recipient ok\r\n" +
                "354 go ahead\r\n" +
                "250 queued\r\n"
        )
        let email = Email.builder()
            .smtp("localhost", port: 25)
            .tls(TlsMode.None)
            .requireEncryption(false)
            .smtpTransport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .subject("门面发送")
            .text("hello")
            .build()
        let report = email.send(message)
        @Assert(report.isCompleteSuccess(), true)
        @Assert(transport.recordedText().contains("MAIL FROM"), true)
        @Assert(transport.recordedText().contains("Subject:"), true)
        email.close()
        @Assert(email.isClosed(), true)
    }

    /** 列表只用信头：标题、发件人、服务器接收时间、大小、已读状态。 */
    @TestCase
    public func listReadsHeadersAndReceivedTime(): Unit {
        let (email, _) = facadeImapEmail(
            "* 2 EXISTS\r\n" +
                "A0002 OK [READ-WRITE] SELECT completed\r\n" +
                "* 2 FETCH (UID 102 FLAGS (\\Seen) INTERNALDATE \"29-Oct-2026 07:20:00 +0800\" " +
                "RFC822.SIZE 1234 ENVELOPE (\"Thu, 29 Oct 2026 07:20:00 +0800\" \"测试标题\" " +
                "((\"A\" NIL \"a\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")) " +
                "((\"B\" NIL \"b\" \"y.com\")) NIL NIL NIL \"<m@x.com>\"))\r\n" +
                "A0003 OK FETCH completed\r\n"
        )
        let summaries = email.list(limit: 1)
        @Assert(summaries.size, 1)
        @Assert(summaries[0].subject, "测试标题")
        @Assert(summaries[0].id, 102)
        @Assert(summaries[0].size ?? 0, 1234)
        @Assert(summaries[0].isUnread(), false)

        let received = summaries[0].receivedAt
        @Assert(received.isSome(), true)
        @Assert(received.getOrThrow().dateTime.year, 2026)
        @Assert(received.getOrThrow().dateTime.dayOfMonth, 29)
        email.close()
    }

    /** 正文与附件：正文解码成 String，附件保留原始字节。 */
    @TestCase
    public func bodyReturnsTextAndAttachmentBytes(): Unit {
        let mime = "From: a@x.com\r\n" +
            "To: b@y.com\r\n" +
            "Subject: hi\r\n" +
            "MIME-Version: 1.0\r\n" +
            "Content-Type: multipart/mixed; boundary=\"B\"\r\n" +
            "\r\n" +
            "--B\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "\r\n" +
            "hello\r\n" +
            "--B\r\n" +
            "Content-Type: application/octet-stream\r\n" +
            "Content-Disposition: attachment; filename=\"a.bin\"\r\n" +
            "Content-Transfer-Encoding: base64\r\n" +
            "\r\n" +
            "AAEC\r\n" +
            "--B--\r\n"
        let (email, _) = facadeImapEmail(
            "* 1 EXISTS\r\n" +
                "A0002 OK [READ-WRITE] SELECT completed\r\n" +
                "* 1 FETCH (UID 102 FLAGS (\\Seen) RFC822.SIZE 400 ENVELOPE (NIL \"hi\" " +
                "((\"A\" NIL \"a\" \"x.com\")) NIL NIL NIL NIL NIL NIL \"<m@x.com>\"))\r\n" +
                "A0003 OK FETCH completed\r\n" +
                "* 1 FETCH (UID 102 BODY[] {${mime.toArray().size}}\r\n" + mime + ")\r\n" +
                "A0004 OK FETCH completed\r\n"
        )
        let summaries = email.list()
        @Assert(summaries.size, 1)
        let body = email.body(summaries[0])
        @Assert(body.text ?? "", "hello")
        @Assert(body.attachments.size, 1)
        @Assert(body.attachments[0].filename, "a.bin")
        @Assert(body.attachments[0].size, 3)
        let bytes = body.attachments[0].read()
        @Assert(bytes.size, 3)
        @Assert(bytes[0], 0)
        @Assert(bytes[1], 1)
        @Assert(bytes[2], 2)
        email.close()
    }

    /** 删除：按 UID 定位、`STORE +FLAGS \\Deleted`、只 EXPUNGE 这一封。 */
    @TestCase
    public func deleteUsesUidStoreAndExpunge(): Unit {
        let (email, transport) = facadeImapEmail(
            "* 1 EXISTS\r\n" +
                "A0002 OK [READ-WRITE] SELECT completed\r\n" +
                "* 1 FETCH (UID 102)\r\n" +
                "A0003 OK FETCH completed\r\n" +
                "* 1 FETCH (UID 102 FLAGS (\\Deleted))\r\n" +
                "A0004 OK STORE completed\r\n" +
                "* 1 EXPUNGE\r\n" +
                "A0005 OK EXPUNGE completed\r\n"
        )
        let summary = MailSummary(102, sequence: 1, mailbox: "INBOX", subject: "待删")
        email.delete(summary)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("UID FETCH 102"), true)
        @Assert(recorded.contains("STORE 1 +FLAGS (\\Deleted)"), true)
        @Assert(recorded.contains("UID EXPUNGE 102"), true)
        email.close()
    }

    /** POP3 路径：列表靠 TOP 取信头，删除要 DELE + QUIT 提交。 */
    @TestCase
    public func pop3ListsHeadersAndCommitsDeleteOnQuit(): Unit {
        let (email, transport) = facadePop3Email(
            "+OK POP3 server ready\r\n" +
                "+OK Capability list follows\r\nTOP\r\nUIDL\r\nUSER\r\n.\r\n" +
                "+OK user accepted\r\n" +
                "+OK maildrop locked and ready\r\n" +
                "+OK 2 messages\r\n1 120\r\n2 340\r\n.\r\n" +
                "+OK 340 octets\r\n" +
                "Subject: pop3 hello\r\nDate: Thu, 29 Oct 2026 07:20:00 +0800\r\n\r\n.\r\n" +
                "+OK marked\r\n" +
                "+OK bye\r\n"
        )
        let summaries = email.list(limit: 1)
        @Assert(summaries.size, 1)
        @Assert(summaries[0].subject, "pop3 hello")
        @Assert(summaries[0].sequence, 2)
        @Assert(summaries[0].receivedAt.isNone(), true)
        @Assert(summaries[0].date.isSome(), true)

        email.delete(summaries[0])
        let recorded = transport.recordedText()
        @Assert(recorded.contains("DELE 2"), true)
        @Assert(recorded.contains("QUIT"), true)
        email.close()
    }
}
