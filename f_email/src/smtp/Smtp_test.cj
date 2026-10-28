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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*
import fountain::f_email.transport.*

@Test
public class SmtpAuth_test {
    @TestCase
    public func plainTokenBytes(): Unit {
        let token = SmtpAuth.plainToken("user", Secret.of("pass"))
        @Assert(String.fromUtf8(Base64Codec.decode(token)).replace(String([Rune(0)]), "|"), "|user|pass")
        @Assert(token, Base64Codec.encodeUnwrapped("${String([Rune(0)])}user${String([Rune(0)])}pass".toArray()))
    }

    @TestCase
    public func cramMd5MatchesKnownVector(): Unit {
        // RFC 2195 示例：user=tim, pass=tanstaaftanstaaf, challenge="<1896.697170952@postoffice.reston.mci.net>"
        let challenge = "<1896.697170952@postoffice.reston.mci.net>"
        let response = SmtpAuth.cramMd5Response("tim", Secret.of("tanstaaftanstaaf"), challenge)
        let decoded = String.fromUtf8(Base64Codec.decode(response))
        @Assert(decoded, "tim b913a602c7eda7a495b4e6e7334d3890")
    }

    @TestCase
    public func xoauth2TokenContainsBearer(): Unit {
        let token = SmtpAuth.xoauth2Token("u@example.com", Secret.of("tok"))
        let decoded = String.fromUtf8(Base64Codec.decode(token))
        @Assert(decoded.contains("user=u@example.com"), true)
        @Assert(decoded.contains("auth=Bearer tok"), true)
    }
}

@Test
public class SmtpReply_test {
    @TestCase
    public func parsesMultilineReply(): Unit {
        let server = ScriptedTransport(server: "250-smtp.example.com\r\n250-SIZE 35882577\r\n250 AUTH PLAIN LOGIN\r\n")
        let connection = server.connect("s", 25, TlsMode.None)
        let reply = SmtpReply.read(connection.channel())
        @Assert(reply.code, 250)
        @Assert(reply.lines.size, 3)
        let capabilities = SmtpCapabilities.fromEhlo(reply.lines)
        @Assert(capabilities.size ?? 0, 35882577)
        @Assert(capabilities.authMechanisms.size, 2)
        @Assert(capabilities.supportsStartTls, false)
    }

    @TestCase
    public func extractsEnhancedCode(): Unit {
        let server = ScriptedTransport(server: "550 5.1.1 No such user\r\n")
        let reply = SmtpReply.read(server.connect("s", 25, TlsMode.None).channel())
        @Assert(reply.code, 550)
        @Assert(reply.enhanced ?? "", "5.1.1")
    }
}

@Test
public class SmtpClient_test {
    @TestCase
    public func rejectsPlaintextByDefault(): Unit {
        var caught = false
        try {
            SmtpClient.builder("localhost", port: 25).build()
        } catch (_: IllegalArgumentException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func buildNegotiatesCapabilities(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250-SIZE 35882577\r\n250-8BITMIME\r\n250 PIPELINING\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        @Assert(client.capabilities.size ?? 0, 35882577)
        @Assert(client.capabilities.supports8BitMime, true)
        @Assert(client.capabilities.supportsPipelining, true)
        @Assert(transport.recordedText().contains("EHLO "), true)
        client.close()
    }

    @TestCase
    public func ehloFallbackWithoutTlsWorks(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "502 command not implemented\r\n" +
                "250 hello\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        @Assert(transport.recordedText().contains("HELO "), true)
        @Assert(client.capabilities.authMechanisms.size, 0)
        client.close()
    }

    @TestCase
    public func sendsMessageWithDotStuffing(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250 smtp.example.com\r\n" +
                "250 sender ok\r\n" +
                "250 recipient ok\r\n" +
                "354 go ahead\r\n" +
                "250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .text(".leading dot line\r\nsecond")
            .build()
        let report = client.send(message)
        @Assert(report.isCompleteSuccess(), true)
        @Assert(report.accepted.size, 1)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("MAIL FROM:<a@x.com>"), true)
        @Assert(recorded.contains("RCPT TO:<b@y.com>"), true)
        @Assert(recorded.contains("\r\n..leading dot line"), true)
        @Assert(recorded.endsWith(".\r\n"), true)
        client.close()
    }

    @TestCase
    public func stripsBccButKeepsRecipient(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250 smtp.example.com\r\n" +
                "250 ok\r\n" +
                "250 ok\r\n" +
                "250 ok\r\n" +
                "354 go\r\n" +
                "250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .bcc("hidden@example.com")
            .text("hi")
            .build()
        client.send(message)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("RCPT TO:<hidden@example.com>"), true)
        @Assert(recorded.contains("Bcc:"), false)
        client.close()
    }

    @TestCase
    public func partialRejectionInBestEffort(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250 smtp.example.com\r\n" +
                "250 sender ok\r\n" +
                "250 first ok\r\n" +
                "550 no such user\r\n" +
                "354 go\r\n" +
                "250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("ok@y.com")
            .to("bad@y.com")
            .text("hi")
            .build()
        let report = client.send(message)
        @Assert(report.accepted.size, 1)
        @Assert(report.rejected.size, 1)
        @Assert(report.isCompleteSuccess(), false)
        @Assert(report.reply.code, 250)
        client.close()
    }

    @TestCase
    public func allOrNothingAbortsWithoutData(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250 smtp.example.com\r\n" +
                "250 sender ok\r\n" +
                "250 first ok\r\n" +
                "550 no such user\r\n" +
                "250 reset ok\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .sendPolicy(SendPolicy.AllOrNothing)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("ok@y.com")
            .to("bad@y.com")
            .text("hi")
            .build()
        let report = client.send(message)
        @Assert(report.aborted, true)
        @Assert(report.accepted.size, 0)
        @Assert(report.rejected.size, 2)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("RSET"), true)
        @Assert(recorded.contains("DATA"), false)
        client.close()
    }

    @TestCase
    public func sizeLimitFailsBeforeMailFrom(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" + "250 smtp.example.com\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .maxMessageBytes(16)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .text("this body is definitely longer than sixteen bytes")
            .build()
        var caught = false
        try {
            client.send(message)
        } catch (e: MailLimitException) {
            caught = e.kind.toString() == "Size"
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("MAIL FROM"), false)
        client.close()
    }

    @TestCase
    public func authPlainIsWrittenAfterTlsOrExplicitAllow(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250 AUTH PLAIN LOGIN\r\n" +
                "235 authenticated\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .auth(SmtpAuthMechanism.Plain, "user", Secret.of("pass"))
            .transport(transport)
            .build()
        let expected = "AUTH PLAIN " + SmtpAuth.plainToken("user", Secret.of("pass"))
        @Assert(transport.recordedText().contains(expected), true)
        client.close()
    }

    @TestCase
    public func authFailureThrows(): Unit {
        var caught = false
        try {
            let transport = ScriptedTransport(
                server: "220 ready\r\n" +
                    "250-smtp.example.com\r\n250 AUTH LOGIN\r\n" +
                    "535 authentication failed\r\n"
            )
            SmtpClient.builder("localhost", port: 25)
                .requireEncryption(false)
                .allowPlaintextAuth(true)
                .auth(SmtpAuthMechanism.Plain, "user", Secret.of("pass"))
                .transport(transport)
                .build()
        } catch (_: MailAuthException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func pipelinedRepliesConsumedInOrder(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250 PIPELINING\r\n" +
                "250 sender ok\r\n" +
                "250 first ok\r\n" +
                "550 rejected\r\n" +
                "354 go\r\n" +
                "250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("ok@y.com")
            .to("bad@y.com")
            .text("hi")
            .build()
        let report = client.send(message)
        @Assert(report.accepted.size, 1)
        @Assert(report.rejected.size, 1)
        let recorded = transport.recordedText()
        let mailIndex = recorded.indexOf("MAIL FROM") ?? -1
        let firstRcpt = recorded.indexOf("RCPT TO:<ok@y.com>") ?? -1
        let dataIndex = recorded.indexOf("DATA") ?? -1
        @Assert(mailIndex < firstRcpt, true)
        @Assert(firstRcpt < dataIndex, true)
        client.close()
    }
}

@Test
public class SmtpAuthDialogue_test {
    /** LOGIN 是两段 base64：先用户名、后密码，顺序不能反。 */
    @TestCase
    public func loginWritesUserThenPassword(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250 AUTH LOGIN\r\n" +
                "334 VXNlcm5hbWU6\r\n" +
                "334 UGFzc3dvcmQ6\r\n" +
                "235 authenticated\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .auth(SmtpAuthMechanism.Login, "user", Secret.of("pass"))
            .transport(transport)
            .build()
        let recorded = transport.recordedText()
        let userIndex = recorded.indexOf(Base64Codec.encodeUnwrapped("user".toArray())) ?? -1
        let passIndex = recorded.indexOf(Base64Codec.encodeUnwrapped("pass".toArray())) ?? -1
        @Assert(userIndex >= 0, true)
        @Assert(userIndex < passIndex, true)
        client.close()
    }

    /** CRAM-MD5 的挑战是 base64 原文，响应里不能出现明文密码。 */
    @TestCase
    public func cramMd5RespondsWithDigest(): Unit {
        let challenge = "<1896.697170952@postoffice.reston.mci.net>"
        let encoded = Base64Codec.encodeUnwrapped(challenge.toArray())
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250 AUTH CRAM-MD5\r\n" +
                "334 ${encoded}\r\n" +
                "235 authenticated\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .auth(SmtpAuthMechanism.CramMd5, "tim", Secret.of("tanstaaftanstaaf"))
            .transport(transport)
            .build()
        let expected = SmtpAuth.cramMd5Response("tim", Secret.of("tanstaaftanstaaf"), challenge)
        @Assert(transport.recordedText().contains(expected), true)
        @Assert(transport.recordedText().contains("tanstaaftanstaaf"), false)
        client.close()
    }

    /** XOAUTH2 失败时服务器先回 334，必须补空行才能读到最终 reply。 */
    @TestCase
    public func xoauth2FailureSendsEmptyLine(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n" +
                "250-smtp.example.com\r\n250 AUTH XOAUTH2\r\n" +
                "334 eyJzdGF0dXMiOiI0MDEifQ==\r\n" +
                "535 authentication failed\r\n"
        )
        var caught = false
        try {
            SmtpClient.builder("localhost", port: 25)
                .requireEncryption(false)
                .allowPlaintextAuth(true)
                .oauth2("u@example.com", Secret.of("tok"))
                .transport(transport)
                .build()
        } catch (_: MailAuthException) {
            caught = true
        }
        @Assert(caught, true)
        // 334 之后必须写出一行空内容（CRLF 紧跟 CRLF）
        @Assert(transport.recordedText().contains("\r\n\r\n"), true)
    }
}

@Test
public class SmtpExtensions_test {
    @TestCase
    public func eightBitMimeAddsBodyParameter(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n250-smtp.example.com\r\n250-8BITMIME\r\n250 PIPELINING\r\n" +
                "250 sender ok\r\n250 rcpt ok\r\n354 go\r\n250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
        client.send(message)
        @Assert(transport.recordedText().contains("MAIL FROM:<a@x.com> BODY=8BITMIME"), true)
        client.close()
    }

    @TestCase
    public func withoutEightBitMimeNoBodyParameter(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n250-smtp.example.com\r\n" +
                "250 sender ok\r\n250 rcpt ok\r\n354 go\r\n250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
        client.send(message)
        @Assert(transport.recordedText().contains("BODY=8BITMIME"), false)
        client.close()
    }

    /** 非 ASCII 信封地址没有 SMTPUTF8 时必须报错，绝不能把裸 UTF-8 发出去。 */
    @TestCase
    public func nonAsciiAddressWithoutSmtpUtf8Fails(): Unit {
        let transport = ScriptedTransport(server: "220 ready\r\n250 smtp.example.com\r\n")
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder().from("a@x.com").to("张三@example.com").text("hi").build()
        var caught = false
        try {
            client.send(message)
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("MAIL FROM"), false)
        client.close()
    }

    @TestCase
    public func smtpUtf8IsAdvertisedInMailFrom(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n250-smtp.example.com\r\n250-SMTPUTF8\r\n250 PIPELINING\r\n" +
                "250 sender ok\r\n250 rcpt ok\r\n354 go\r\n250 queued\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder().from("a@x.com").to("张三@example.com").text("hi").build()
        let report = client.send(message)
        @Assert(report.isCompleteSuccess(), true)
        @Assert(transport.recordedText().contains("SMTPUTF8"), true)
        @Assert(transport.recordedText().contains("RCPT TO:<张三@example.com>"), true)
        client.close()
    }

    @TestCase
    public func precomputeWritesSizeParameter(): Unit {
        let transport = ScriptedTransport(server: "220 ready\r\n250 smtp.example.com\r\n")
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .precomputeSize(true)
            .transport(transport)
            .build()
        var caught = false
        try {
            // 服务器没有后续应答，MANIFEST 之前就会因 SIZE 计算完成而写出 MAIL FROM；
            // 这里只关心命令里带 SIZE=，所以吞掉后续异常
            let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
            client.send(message)
        } catch (_: Exception) {
            caught = true
        }
        @Assert(transport.recordedText().contains("MAIL FROM:<a@x.com> SIZE="), true)
        client.close()
    }

    /** 421 中途断开：不抛异常，落在 SendReport 里。 */
    @TestCase
    public func server421MidTransactionYieldsFailedReport(): Unit {
        let transport = ScriptedTransport(
            server: "220 ready\r\n250 smtp.example.com\r\n421 service not available\r\n"
        )
        let client = SmtpClient.builder("localhost", port: 25)
            .requireEncryption(false)
            .transport(transport)
            .build()
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
        let report = client.send(message)
        @Assert(report.isCompleteSuccess(), false)
        @Assert(report.rejected.size, 1)
        @Assert(report.reply.code, 421)
        client.close()
    }

    @TestCase
    public func startTlsNotAdvertisedIsRejected(): Unit {
        let transport = ScriptedTransport(server: "220 ready\r\n250 smtp.example.com\r\n")
        var caught = false
        try {
            SmtpClient.builder("localhost", port: 25)
                .tls(TlsMode.StartTls)
                .transport(transport)
                .build()
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }
}

@Test
public class RetryClassification_test {
    @TestCase
    public func classifiesExceptions(): Unit {
        @Assert(isRetryable(MailIoException(IoStage.Timeout, "t")), true)
        @Assert(isRetryable(MailIoException(IoStage.Read, "r")), false)
        @Assert(isRetryable(MailTlsException("tls")), true)
        @Assert(isRetryable(MailAuthException("PLAIN", None<Int64>, "auth")), false)
        @Assert(isRetryable(MailProtocolException("bad")), false)
        @Assert(isRetryable(MailLimitException(LimitKind.Size, 1, 2)), false)
    }

    @TestCase
    public func classifiesReports(): Unit {
        let retryable = SendReport(
            "mid",
            rejected: [RecipientStatus("a@b", 451, text: "try later")],
            reply: SmtpReply(451, ["try later"])
        )
        @Assert(retryable.isRetryable(), true)
        let permanent = SendReport(
            "mid",
            rejected: [RecipientStatus("a@b", 550, text: "no user")],
            reply: SmtpReply(550, ["no user"])
        )
        @Assert(permanent.isRetryable(), false)
        let success = SendReport("mid", accepted: [RecipientStatus("a@b", 250, accepted: true)], reply: SmtpReply(250, ["ok"]))
        @Assert(success.isRetryable(), false)
    }
}
