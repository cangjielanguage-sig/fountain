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
