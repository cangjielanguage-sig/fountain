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

import std.collection.ArrayList
import std.io.OutputStream
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*
import fountain::f_email.transport.*

/** 收集字节的 sink，用于断言 `RETR` / `TOP` 的内容。 */
class Pop3Sink <: OutputStream {
    private let buffer = ArrayList<Byte>()

    public func write(bytes: Array<Byte>): Unit {
        for (b in bytes) {
            buffer.add(b)
        }
    }

    func text(): String {
        String.fromUtf8(buffer.toArray())
    }

    func size(): Int64 {
        buffer.size
    }
}

/** 一份"问候 + CAPA"的最小脚本，后面接各测试自己的响应。 */
func pop3Prefix(caps!: String = "+OK Capability list follows\r\nTOP\r\nUIDL\r\nUSER\r\n.\r\n"): String {
    "+OK POP3 server ready\r\n" + caps
}

/** 脚本里的两行登录应答：`USER` 与 `PASS` 各要一条。 */
func loginReplies(): String {
    "+OK user accepted\r\n+OK maildrop locked and ready\r\n"
}

func openClient(server: String, chunkSize!: Int64 = 0): (Pop3Client, ScriptedTransport) {
    let transport = ScriptedTransport(server: server, chunkSize: chunkSize)
    let client = Pop3Client.builder("localhost", port: 110)
        .requireEncryption(false)
        .allowPlaintextAuth(true)
        .transport(transport)
        .build()
    (client, transport)
}

@Test
public class Pop3Reply_test {
    @TestCase
    public func parsesOkAndErr(): Unit {
        let ok = Pop3Reply.parse("+OK 2 messages (320 octets)")
        @Assert(ok.isOk(), true)
        @Assert(ok.text, "2 messages (320 octets)")

        let err = Pop3Reply.parse("-ERR [AUTH] invalid credentials")
        @Assert(err.isOk(), false)
        @Assert(err.errorCode ?? "", "AUTH")
        @Assert(err.errorKind().toString(), "AUTH")
    }

    @TestCase
    public func classifiesErrorCodes(): Unit {
        @Assert(Pop3Reply.parse("-ERR [SYS/TEMP] busy").errorKind().toString(), "SYS/TEMP")
        @Assert(Pop3Reply.parse("-ERR [SYS/PERM] nope").errorKind().toString(), "SYS/PERM")
        @Assert(Pop3Reply.parse("-ERR [IN-USE] locked").errorKind().toString(), "IN-USE")
        @Assert(Pop3Reply.parse("-ERR plain").errorKind().toString(), "OTHER")
    }

    @TestCase
    public func rejectsGarbage(): Unit {
        var caught = false
        try {
            Pop3Reply.parse("220 what")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }
}

@Test
public class Pop3Capabilities_test {
    @TestCase
    public func parsesCapabilities(): Unit {
        let caps = Pop3Capabilities.fromLines(["TOP", "UIDL", "SASL PLAIN LOGIN", "IMPLEMENTATION Cyrus POP3", "STLS"])
        @Assert(caps.supportsTop, true)
        @Assert(caps.supportsUidl, true)
        @Assert(caps.supportsStls, true)
        @Assert(caps.supportsUser, false)
        @Assert(caps.authMechanisms.size, 2)
        @Assert(caps.implementation ?? "", "Cyrus POP3")
    }

    /**
     * RFC 2449 之前的老服务器对 `CAPA` 回 `-ERR`：这不是失败，只是能力表为空。
     * 把它当异常会让"只实现最小命令集"的服务器直接不可用。
     */
    @TestCase
    public func errOnCapaYieldsEmptyTable(): Unit {
        let (client, _) = openClient("+OK ready\r\n-ERR unknown command\r\n")
        @Assert(client.capabilities.isEmpty, true)
        @Assert(client.capabilities.supportsTop, false)
        client.close()
    }
}

@Test
public class Pop3Client_test {
    @TestCase
    public func greetingAndCapabilities(): Unit {
        let (client, transport) = openClient(pop3Prefix())
        @Assert(client.greeting, "POP3 server ready")
        @Assert(client.capabilities.supportsTop, true)
        @Assert(transport.recordedText().contains("CAPA\r\n"), true)
        @Assert(client.isAuthenticated, false)
        client.close()
    }

    @TestCase
    public func loginWritesUserAndPass(): Unit {
        let (client, transport) = openClient(
            pop3Prefix() + "+OK user accepted\r\n+OK maildrop locked and ready\r\n"
        )
        client.login("alice", Secret.of("s3cret"))
        @Assert(client.isAuthenticated, true)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("USER alice\r\n"), true)
        @Assert(recorded.contains("PASS s3cret\r\n"), true)
        client.close()
    }

    /** RFC 1939 第 7 节的 APOP 示例摘要。 */
    @TestCase
    public func apopMatchesRfcExample(): Unit {
        let greeting = "+OK POP3 server ready <1896.697170952@dbc.mtview.ca.us>\r\n"
        let caps = "+OK Capability list follows\r\nUSER\r\n.\r\n"
        let (client, transport) = openClient(greeting + caps + "+OK maildrop has 1 message (369 octets)\r\n")
        client.apop("mrose", Secret.of("tanstaaf"))
        @Assert(client.isAuthenticated, true)
        @Assert(
            transport.recordedText().contains("APOP mrose c4c9334bac560ecc979e58001b3e22fb\r\n"),
            true
        )
        client.close()
    }

    /** 没有时间戳时必须报错，不能悄悄退回明文密码。 */
    @TestCase
    public func apopWithoutTimestampThrows(): Unit {
        let (client, _) = openClient(pop3Prefix())
        var caught = false
        try {
            client.apop("mrose", Secret.of("tanstaaf"))
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func authPlainUsesSaslContinuation(): Unit {
        let (client, transport) = openClient(pop3Prefix() + "+\r\n+OK maildrop ready\r\n")
        client.authenticate(Pop3AuthMechanism.Plain, "alice", Secret.of("pw"))
        let recorded = transport.recordedText()
        @Assert(recorded.contains("AUTH PLAIN\r\n"), true)
        let nul = String([Rune(0)])
        @Assert(recorded.contains(Base64Codec.encodeUnwrapped((nul + "alice" + nul + "pw").toArray())), true)
        client.close()
    }

    @TestCase
    public func authLoginSendsBothSecrets(): Unit {
        let (client, transport) = openClient(
            pop3Prefix() + "+ VXNlcm5hbWU6\r\n+ UGFzc3dvcmQ6\r\n+OK done\r\n"
        )
        client.authenticate(Pop3AuthMechanism.Login, "alice", Secret.of("pw"))
        let recorded = transport.recordedText()
        @Assert(recorded.contains("AUTH LOGIN\r\n"), true)
        @Assert(recorded.contains(Base64Codec.encodeUnwrapped("alice".toArray()) + "\r\n"), true)
        @Assert(recorded.contains(Base64Codec.encodeUnwrapped("pw".toArray()) + "\r\n"), true)
        client.close()
    }

    @TestCase
    public func statAndList(): Unit {
        let (client, _) = openClient(
            pop3Prefix() + loginReplies() +
                "+OK 2 messages (320 octets)\r\n" +
                "+OK 2 messages (320 octets)\r\n1 120\r\n2 200\r\n.\r\n" +
                "+OK 1 120\r\n" +
                "+OK 2 messages (320 octets)\r\n1 whqtswO00WBw418f9t5JxYwZ\r\n2 QhdPYR:00WBw1Ph7x7\r\n.\r\n" +
                "+OK 2 QhdPYR:00WBw1Ph7x7\r\n"
        )
        client.login("u", Secret.of("p"))
        let stat = client.stat()
        @Assert(stat.messages, 2)
        @Assert(stat.size, 320)
        let all = client.list()
        @Assert(all.size, 2)
        @Assert(all[1].size, 200)
        let one = client.list(1)
        @Assert(one.number, 1)
        @Assert(one.size, 120)
        let uids = client.uidl()
        @Assert(uids.size, 2)
        @Assert(uids[0].uid, "whqtswO00WBw418f9t5JxYwZ")
        @Assert(client.uidl(2), "QhdPYR:00WBw1Ph7x7")
        client.close()
    }

    /**
     * 正文的 dot-unstuffing：行首 `..` 还原成 `.`，单独一行 `.` 结束，
     * 超长行（10 KB）不受 `maxLine` 限制。
     */
    @TestCase
    public func retrUnstuffsAndHandlesLongLines(): Unit {
        var long = ""
        for (_ in 0..10000) {
            long = long + "x"
        }
        let body = "Subject: hi\r\n\r\n..dotted\r\n" + long + "\r\n.\r\n"
        let (client, _) = openClient(pop3Prefix() + loginReplies() + "+OK 120 octets\r\n" + body)
        client.login("u", Secret.of("p"))
        let sink = Pop3Sink()
        let written = client.retr(1, sink)
        @Assert(written, Int64(sink.size()))
        let text = sink.text()
        @Assert(text.contains(".dotted\r\n"), true)
        @Assert(text.contains(long), true)
        @Assert(text.contains("..dotted"), false)
        client.close()
    }

    @TestCase
    public func retrMessageParsesMime(): Unit {
        let message = "From: a@x.com\r\nTo: b@y.com\r\nSubject: =?UTF-8?B?5L2g5aW9?=\r\n" +
            "Content-Type: text/plain; charset=UTF-8\r\n\r\nhello\r\n"
        let (client, _) = openClient(pop3Prefix() + loginReplies() + "+OK 120 octets\r\n" + message + ".\r\n")
        client.login("u", Secret.of("p"))
        let parsed = client.retrMessage(1)
        @Assert(parsed.subject() ?? "", "你好")
        @Assert((parsed.text() ?? "").trimAscii(), "hello")
        client.close()
    }

    @TestCase
    public func topZeroReturnsHeadersOnly(): Unit {
        let body = "Subject: hi\r\n\r\n.\r\n"
        let (client, _) = openClient(pop3Prefix() + loginReplies() + "+OK top follows\r\n" + body)
        client.login("u", Secret.of("p"))
        let sink = Pop3Sink()
        client.top(1, 0, sink)
        @Assert(sink.text(), "Subject: hi\r\n\r\n")
        client.close()
    }

    @TestCase
    public func topWithoutCapabilityThrows(): Unit {
        let (client, transport) = openClient(
            "+OK ready\r\n+OK Capability list follows\r\nUIDL\r\n.\r\n" + loginReplies()
        )
        client.login("u", Secret.of("p"))
        var caught = false
        try {
            client.top(1, 0, Pop3Sink())
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "TOP"
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("TOP "), false)
        client.close()
    }

    @TestCase
    public func deleteCommitsOnlyAfterQuit(): Unit {
        let (client, transport) = openClient(pop3Prefix() + loginReplies() + "+OK marked\r\n+OK bye\r\n")
        client.login("u", Secret.of("p"))
        client.dele(2)
        @Assert(client.pendingDeletes.size, 1)
        @Assert(client.isDeleteCommitted, false)
        client.quit()
        @Assert(client.isDeleteCommitted, true)
        @Assert(transport.recordedText().contains("QUIT\r\n"), true)
    }

    @TestCase
    public func closeDoesNotCommitDeletes(): Unit {
        let (client, _) = openClient(pop3Prefix() + loginReplies() + "+OK marked\r\n")
        client.login("u", Secret.of("p"))
        client.dele(1)
        client.close()
        @Assert(client.isDeleteCommitted, false)
        @Assert(client.isClosed(), true)
    }

    @TestCase
    public func rsetClearsPendingDeletes(): Unit {
        let (client, _) = openClient(pop3Prefix() + loginReplies() + "+OK marked\r\n+OK reset\r\n")
        client.login("u", Secret.of("p"))
        client.dele(1)
        client.rset()
        @Assert(client.pendingDeletes.size, 0)
        client.close()
    }

    @TestCase
    public func errAuthBecomesMailAuthException(): Unit {
        let (client, _) = openClient(pop3Prefix() + "+OK user\r\n-ERR [AUTH] invalid password\r\n")
        var caught = false
        try {
            client.login("u", Secret.of("bad"))
        } catch (e: MailAuthException) {
            caught = e.message.contains("[AUTH]")
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func plaintextAuthRequiresExplicitAllow(): Unit {
        let transport = ScriptedTransport(server: pop3Prefix())
        let client = Pop3Client.builder("localhost", port: 110)
            .requireEncryption(false)
            .transport(transport)
            .build()
        var caught = false
        try {
            client.login("u", Secret.of("p"))
        } catch (_: MailAuthException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func transactionRequiresLogin(): Unit {
        let (client, _) = openClient(pop3Prefix())
        var caught = false
        try {
            client.stat()
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    /** 每次 `read` 只返回 1 字节：暴露"依赖一次读满一行"的实现。 */
    @TestCase
    public func slowStreamParsesEverything(): Unit {
        let body = "Subject: hi\r\n\r\n..dotted\r\n.\r\n"
        let (client, _) = openClient(
            pop3Prefix() + loginReplies() +
                "+OK 2 messages (320 octets)\r\n" +
                "+OK 2 messages (320 octets)\r\n1 10\r\n2 20\r\n.\r\n" +
                "+OK 120 octets\r\n" + body,
            chunkSize: 1
        )
        client.login("u", Secret.of("p"))
        @Assert(client.stat().messages, 2)
        @Assert(client.list().size, 2)
        let sink = Pop3Sink()
        client.retr(1, sink)
        @Assert(sink.text(), "Subject: hi\r\n\r\n.dotted\r\n")
        client.close()
    }

    @TestCase
    public func missingStlsIsRejected(): Unit {
        let transport = ScriptedTransport(server: "+OK ready\r\n+OK Capability list follows\r\nTOP\r\n.\r\n")
        var caught = false
        try {
            Pop3Client.builder("localhost", port: 110)
                .requireEncryption(false)
                .tls(TlsMode.StartTls)
                .transport(transport)
                .build()
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "STLS"
        }
        @Assert(caught, true)
    }

    @TestCase
    public func requiresEncryptionByDefault(): Unit {
        var caught = false
        try {
            Pop3Client.builder("localhost", port: 110).build()
        } catch (_: IllegalArgumentException) {
            caught = true
        }
        @Assert(caught, true)
    }
}
