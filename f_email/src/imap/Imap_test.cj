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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*
import fountain::f_email.transport.*

let CAPABILITY_LINE = "* CAPABILITY IMAP4rev1 IDLE MOVE UIDPLUS LITERAL+ SPECIAL-USE NAMESPACE " +
    "ENABLE UTF8=ACCEPT CONDSTORE QRESYNC SORT SORT=DISPLAY THREAD=REFERENCES AUTH=PLAIN\r\n" +
    "A0000 OK CAPABILITY completed\r\n"

func greeting(): String {
    "* OK IMAP4rev1 server ready\r\n"
}

func openImap(server: String, chunkSize!: Int64 = 0): (ImapClient, ScriptedTransport) {
    let transport = ScriptedTransport(server: server, chunkSize: chunkSize)
    let client = ImapClient.builder("localhost", port: 143)
        .requireEncryption(false)
        .allowPlaintextAuth(true)
        .transport(transport)
        .build()
    (client, transport)
}

/** 已登录 + 已选中 INBOX 的客户端，标签消耗到 A0002。 */
func openSelected(server: String, chunkSize!: Int64 = 0): (ImapClient, ScriptedTransport) {
    let (client, transport) = openImap(
        greeting() + CAPABILITY_LINE +
            "A0001 OK LOGIN completed\r\n" +
            "* 3 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 3857529045] ok\r\n" +
            "* OK [UIDNEXT 4392] ok\r\n* OK [HIGHESTMODSEQ 1234] ok\r\n" +
            "A0002 OK [READ-WRITE] SELECT completed\r\n" + server,
        chunkSize: chunkSize
    )
    client.login("alice", Secret.of("pw"))
    client.select("INBOX")
    (client, transport)
}

/** 收集正文块的 sink。 */
class CollectingSink <: FetchSink {
    let chunks = ArrayList<Byte>()
    var meta: ?FetchMeta = None

    public func onBodyChunk(chunk: Array<Byte>): Unit {
        for (b in chunk) {
            chunks.add(b)
        }
    }

    public func onComplete(completedMeta: FetchMeta): Unit {
        meta = Some(completedMeta)
    }

    func text(): String {
        String.fromUtf8(chunks.toArray())
    }
}

@Test
public class ImapParser_test {
    @TestCase
    public func tokenizesFetchResponse(): Unit {
        let tokens = ImapParser.parse("* 3 FETCH (UID 9 FLAGS (\\Seen \\Flagged))")
        @Assert(tokens.size, 4)
        @Assert(tokens[1].number() ?? 0, 3)
        @Assert(tokens[2].text().toAsciiUpper(), "FETCH")
        let list = tokens[3].items()
        @Assert(list.size, 4)
        @Assert(list[0].text().toAsciiUpper(), "UID")
        @Assert(list[3].items().size, 2)
    }

    /** 方括号里带空格与括号：按空白切词会把它拆成三个 token。 */
    @TestCase
    public func keepsSectionKeyAsOneAtom(): Unit {
        let tokens = ImapParser.parse("BODY[HEADER.FIELDS (FROM TO)]")
        @Assert(tokens.size, 1)
        @Assert(tokens[0].text(), "BODY[HEADER.FIELDS (FROM TO)]")
    }

    @TestCase
    public func decodesQuotedEscapes(): Unit {
        let tokens = ImapParser.parse("\"a\\\"b\\\\c\"")
        @Assert(tokens.size, 1)
        @Assert(tokens[0].text(), "a\"b\\c")
    }

    @TestCase
    public func recordsLiteralLength(): Unit {
        let tokens = ImapParser.parse("(BODY[] {10})")
        @Assert(tokens.size, 1)
        let list = tokens[0].items()
        @Assert(list.size, 2)
        @Assert(list[1].toString(), "{10}")
    }

    @TestCase
    public func literalPlusIsDistinguished(): Unit {
        let tokens = ImapParser.parse("{12+}")
        @Assert(tokens[0].toString(), "{12+}")
    }

    @TestCase
    public func rejectsUnclosedList(): Unit {
        var caught = false
        try {
            ImapParser.parse("(A B")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func rejectsDeepNesting(): Unit {
        var text = ""
        for (_ in 0..70) {
            text = text + "("
        }
        var caught = false
        try {
            ImapParser.parse(text)
        } catch (e: MailLimitException) {
            caught = e.kind.toString() == "Depth"
        }
        @Assert(caught, true)
    }

    @TestCase
    public func appliesQuotingAndAtoms(): Unit {
        @Assert(ImapParser.param("INBOX"), "INBOX")
        @Assert(ImapParser.param("My Mailbox"), "\"My Mailbox\"")
        @Assert(ImapParser.quoted("a\"b"), "\"a\\\"b\"")
    }
}

@Test
public class ImapUtf7_test {
    /** RFC 3501 第 5.1.3 节的例子。 */
    @TestCase
    public func decodesRfcExample(): Unit {
        @Assert(ImapUtf7.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-"), "~peter/mail/台北/日本語")
    }

    @TestCase
    public func encodesRfcExample(): Unit {
        @Assert(ImapUtf7.encode("~peter/mail/台北/日本語"), "~peter/mail/&U,BTFw-/&ZeVnLIqe-")
    }

    @TestCase
    public func roundTripsChineseMailbox(): Unit {
        let name = "收件箱/已发送"
        @Assert(ImapUtf7.decode(ImapUtf7.encode(name)), name)
    }

    @TestCase
    public func ampersandIsEscaped(): Unit {
        @Assert(ImapUtf7.encode("A&B"), "A&-B")
        @Assert(ImapUtf7.decode("A&-B"), "A&B")
    }

    @TestCase
    public func strictModeRejectsBrokenSequence(): Unit {
        var caught = false
        try {
            ImapUtf7.decode("&!!!-", strict: true)
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        // 宽容模式保留原文，不丢邮箱
        @Assert(ImapUtf7.decode("&!!!-").size > 0, true)
    }
}

@Test
public class ImapCapabilities_test {
    @TestCase
    public func parsesCapabilityLine(): Unit {
        let response = ImapResponse.parse("* CAPABILITY IMAP4rev1 IDLE UTF8=ACCEPT AUTH=PLAIN SORT=DISPLAY")
        let caps = ImapCapabilities.fromValues(response.values)
        @Assert(caps.supportsIdle, true)
        @Assert(caps.supportsUtf8Accept, true)
        @Assert(caps.supportsSortDisplay, true)
        @Assert(caps.supportsSort, true)
        @Assert(caps.authMechanisms.size, 1)
        @Assert(caps.authMechanisms[0], "PLAIN")
        @Assert(caps.supportsMove, false)
    }
}

@Test
public class ImapResponse_test {
    @TestCase
    public func parsesTaggedWithCode(): Unit {
        let response = ImapResponse.parse("A0001 OK [READ-WRITE] SELECT completed")
        @Assert(response.isTagged(), true)
        @Assert(response.tag ?? "", "A0001")
        @Assert(response.isOk(), true)
        @Assert(response.code ?? "", "READ-WRITE")
    }

    @TestCase
    public func parsesUntaggedNumbered(): Unit {
        let response = ImapResponse.parse("* 12 EXISTS")
        @Assert(response.isUntagged(), true)
        @Assert(response.name ?? "", "EXISTS")
        @Assert(response.numberOf() ?? 0, 12)
    }

    @TestCase
    public func parsesUntaggedWithCode(): Unit {
        let response = ImapResponse.parse("* OK [HIGHESTMODSEQ 12345] modseq")
        @Assert(response.name ?? "", "OK")
        @Assert(response.code ?? "", "HIGHESTMODSEQ")
        @Assert(response.codeArgs.size, 1)
        @Assert(response.codeArgs[0], "12345")
    }

    @TestCase
    public func parsesContinuation(): Unit {
        let response = ImapResponse.parse("+ idling")
        @Assert(response.isContinuation(), true)
    }

    @TestCase
    public func parsesCopyUidCode(): Unit {
        let response = ImapResponse.parse("A0002 OK [COPYUID 1 1:3 10:12] copied")
        @Assert(response.code ?? "", "COPYUID")
        @Assert(response.codeArgs.size, 3)
        @Assert(response.codeArgs[2], "10:12")
    }
}

@Test
public class ImapEnvelope_test {
    @TestCase
    public func decodesSubjectAndAddresses(): Unit {
        let value = ImapParser.parse(
            "(NIL \"=?UTF-8?B?5L2g5aW9?=\" " +
                "((\"Alice\" NIL \"alice\" \"example.com\")) " +
                "((\"Alice\" NIL \"alice\" \"example.com\")) " +
                "((\"Alice\" NIL \"alice\" \"example.com\")) " +
                "((\"Bob\" NIL \"bob\" \"example.com\")) NIL NIL NIL \"<mid@example.com>\")"
        )[0]
        let envelope = ImapEnvelope.parse(value)
        @Assert(envelope.subject ?? "", "你好")
        @Assert(envelope.from.size, 1)
        @Assert(envelope.from[0].mailbox ?? "", "alice")
        @Assert(envelope.from[0].host ?? "", "example.com")
        @Assert(envelope.to[0].toString(), "\"Bob\" <bob@example.com>")
        @Assert(envelope.messageId ?? "", "<mid@example.com>")
    }
}

@Test
public class ImapBodyStructure_test {
    @TestCase
    public func parsesNestedMultipart(): Unit {
        let text = "((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 10 1 NIL NIL NIL NIL)" +
            "(\"APPLICATION\" \"PDF\" (\"NAME\" \"a.pdf\") NIL NIL \"BASE64\" 100 NIL " +
            "(\"ATTACHMENT\" (\"FILENAME\" \"a.pdf\")) NIL NIL) " +
            "\"MIXED\" (\"BOUNDARY\" \"b1\") NIL NIL NIL)"
        let value = ImapParser.parse(text)[0]
        let structure = BodyStructure.parse(value)
        @Assert(structure.isMultipart(), true)
        @Assert(structure.leafCount(), 2)
        match (structure) {
            case Multi(body) =>
                @Assert(body.mediaSubtype, "MIXED")
                @Assert(body.param("BOUNDARY") ?? "", "b1")
                @Assert(body.parts.size, 2)
                match (body.parts[0]) {
                    case Leaf(leaf) =>
                        @Assert(leaf.contentType(), "TEXT/PLAIN")
                        @Assert(leaf.param("CHARSET") ?? "", "UTF-8")
                        @Assert(leaf.size, 10)
                        @Assert(leaf.lines ?? 0, 1)
                    case _ => @Assert("expected leaf", "")
                }
                match (body.parts[1]) {
                    case Leaf(leaf) =>
                        @Assert(leaf.isAttachment(), true)
                        @Assert(leaf.filename() ?? "", "a.pdf")
                    case _ => @Assert("expected leaf", "")
                }
            case _ => @Assert("expected multipart", "")
        }
    }

    @TestCase
    public func parsesLeafWithoutLines(): Unit {
        let value = ImapParser.parse("(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" 20 2 NIL NIL NIL NIL)")[0]
        match (BodyStructure.parse(value)) {
            case Leaf(leaf) =>
                @Assert(leaf.mediaSubtype, "HTML")
                @Assert(leaf.encoding, "8BIT")
                @Assert(leaf.lines ?? 0, 2)
            case _ => @Assert("expected leaf", "")
        }
    }
}

@Test
public class ImapDate_test {
    @TestCase
    public func parsesInternalDate(): Unit {
        let date = ImapDate.parse("\"17-Jul-1996 02:44:25 -0700\"")
        @Assert(date.day ?? 0, 17)
        @Assert(date.month ?? "", "JUL")
        @Assert(date.year ?? 0, 1996)
        @Assert(date.hour ?? 0, 2)
        @Assert(date.minute ?? 0, 44)
        @Assert(date.zone ?? "", "-0700")
    }

    @TestCase
    public func toleratesGarbage(): Unit {
        let date = ImapDate.parse("not a date")
        @Assert(date.raw, "not a date")
        @Assert(date.day.isNone(), true)
    }
}

@Test
public class ImapSearch_test {
    @TestCase
    public func buildsNestedCriteria(): Unit {
        let criteria = SearchCriteria.unseen().andWith(SearchCriteria.from("a@b.com"))
        @Assert(criteria.toString(), "UNSEEN FROM \"a@b.com\"")
        @Assert(criteria.needsUtf8(), false)
        @Assert(SearchCriteria.subject("你好").needsUtf8(), true)
        @Assert(SearchCriteria.all().negate().toString(), "NOT ALL")
        @Assert(
            SearchCriteria.orAny([SearchCriteria.seen(), SearchCriteria.flagged()]).toString(),
            "OR SEEN FLAGGED"
        )
    }

    @TestCase
    public func rejectsMalformedDate(): Unit {
        var caught = false
        try {
            SearchCriteria.since("2020-01-01")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }
}

@Test
public class ImapClient_test {
    @TestCase
    public func buildNegotiatesCapabilities(): Unit {
        let (client, transport) = openImap(greeting() + CAPABILITY_LINE)
        @Assert(client.capabilities.supportsIdle, true)
        @Assert(client.isAuthenticated, false)
        @Assert(transport.recordedText().contains("A0000 CAPABILITY"), true)
        client.close()
    }

    @TestCase
    public func loginWritesTaggedCommand(): Unit {
        let (client, transport) = openImap(
            greeting() + CAPABILITY_LINE + "A0001 OK LOGIN completed\r\n"
        )
        client.login("alice", Secret.of("pw"))
        @Assert(client.isAuthenticated, true)
        @Assert(transport.recordedText().contains("A0001 LOGIN alice pw"), true)
        client.close()
    }

    @TestCase
    public func plaintextLoginRequiresExplicitAllow(): Unit {
        let transport = ScriptedTransport(server: greeting() + CAPABILITY_LINE)
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .transport(transport)
            .build()
        var caught = false
        try {
            client.login("alice", Secret.of("pw"))
        } catch (_: MailAuthException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func selectUpdatesMailboxState(): Unit {
        let (client, _) = openSelected("")
        @Assert(client.selected ?? "", "INBOX")
        @Assert(client.messages, 3)
        @Assert(client.uidValidity ?? 0, 3857529045)
        @Assert(client.uidNext ?? 0, 4392)
        @Assert(client.highestModSeq ?? 0, 1234)
        @Assert(client.isReadOnly, false)
        client.close()
    }

    @TestCase
    public func listDecodesModifiedUtf7(): Unit {
        let encoded = ImapUtf7.encode("收件箱")
        let (client, _) = openSelected(
            "* LIST (\\HasNoChildren) \"/\" \"${encoded}\"\r\nA0003 OK LIST completed\r\n"
        )
        let boxes = client.list("", "*")
        @Assert(boxes.size, 1)
        @Assert(boxes[0].name, "收件箱")
        @Assert(boxes[0].delimiter ?? "", "/")
        @Assert(boxes[0].hasAttribute("\\HasNoChildren"), true)
        client.close()
    }

    @TestCase
    public func byeDuringCommandFailsAndCloses(): Unit {
        let transport = ScriptedTransport(
            server: greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n" +
                "* BYE server shutting down\r\nA0003 OK NOOP completed\r\n"
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        client.select("INBOX")
        var caught = false
        try {
            client.noop()
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        @Assert(client.isClosed(), true)
    }

    @TestCase
    public func selectFillsFullMailboxStatus(): Unit {
        let transport = ScriptedTransport(
            server: greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n" +
                "* 12 EXISTS\r\n* 2 RECENT\r\n* OK [UNSEEN 3] first unseen\r\n" +
                "* OK [UIDVALIDITY 1] ok\r\n* OK [UIDNEXT 13] ok\r\n" +
                "* FLAGS (\\Seen \\Answered)\r\n" +
                "* OK [PERMANENTFLAGS (\\Seen \\Deleted)] ok\r\n" +
                "A0002 OK [READ-ONLY] SELECT completed\r\n"
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        let status = client.select("INBOX")
        @Assert(status.messages ?? 0, 12)
        @Assert(status.recent ?? 0, 2)
        @Assert(status.unseen ?? 0, 3)
        @Assert(status.uidNext ?? 0, 13)
        @Assert(status.uidValidity ?? 0, 1)
        @Assert(status.flags.size, 2)
        @Assert(status.flags[0], "\\Seen")
        @Assert(status.permanentFlags.size, 2)
        @Assert(status.readOnly, true)
        client.close()
    }

    @TestCase
    public func statusParsesKeyValuePairs(): Unit {
        let (client, _) = openSelected(
            "* STATUS \"INBOX\" (MESSAGES 231 UIDNEXT 44292 UNSEEN 0 UIDVALIDITY 1 HIGHESTMODSEQ 7)\r\n" +
                "A0003 OK STATUS completed\r\n"
        )
        let status = client.status("INBOX")
        @Assert(status.messages ?? 0, 231)
        @Assert(status.unseen ?? 1, 0)
        @Assert(status.uidNext ?? 0, 44292)
        @Assert(status.highestModSeq ?? 0, 7)
        client.close()
    }

    /** literal 把一条响应拆成多行：解析必须跨片段拼接。 */
    @TestCase
    public func fetchWithLiteralReadsBody(): Unit {
        let (client, _) = openSelected(
            "* 1 FETCH (UID 9 FLAGS (\\Seen) RFC822.SIZE 120 BODY[] {5}\r\n" +
                "hello)\r\n" +
                "A0003 OK FETCH completed\r\n"
        )
        let results = client.fetch(SequenceSet.single(1), [FetchItem.uid(), FetchItem.flags(), FetchItem.size()])
        @Assert(results.size, 1)
        @Assert(results[0].uid ?? 0, 9)
        @Assert(results[0].flags.size, 1)
        @Assert(results[0].size ?? 0, 120)
        @Assert(String.fromUtf8(results[0].body.getOrThrow()), "hello")
        client.close()
    }

    @TestCase
    public func fetchKeepsSectionKey(): Unit {
        let (client, _) = openSelected(
            "* 1 FETCH (BODY[HEADER.FIELDS (FROM TO)] {11}\r\n" +
                "From: a@x\r\n" +
                ")\r\n" +
                "A0003 OK FETCH completed\r\n"
        )
        let results = client.fetch(
            SequenceSet.single(1),
            [FetchItem.body(section: BodySection.headerFields(["FROM", "TO"]), peek: true)]
        )
        @Assert(results[0].section ?? "", "HEADER.FIELDS (FROM TO)")
        @Assert(String.fromUtf8(results[0].body.getOrThrow()).contains("From: a@x"), true)
        client.close()
    }

    @TestCase
    public func fetchParsesEnvelopeAndStructure(): Unit {
        let (client, _) = openSelected(
            "* 1 FETCH (UID 9 ENVELOPE (NIL \"hi\" ((\"A\" NIL \"a\" \"x.com\")) " +
                "((\"A\" NIL \"a\" \"x.com\")) ((\"A\" NIL \"a\" \"x.com\")) ((\"B\" NIL \"b\" \"y.com\")) " +
                "NIL NIL NIL \"<m@x.com>\") BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") " +
                "NIL NIL \"7BIT\" 9 1 NIL NIL NIL NIL))\r\n" +
                "A0003 OK FETCH completed\r\n"
        )
        let results = client.fetch(SequenceSet.single(1), [FetchItem.envelope(), FetchItem.bodyStructure()])
        @Assert(results[0].envelope.getOrThrow().subject ?? "", "hi")
        @Assert(results[0].bodyStructure.getOrThrow().contentType(), "TEXT/PLAIN")
        client.close()
    }

    @TestCase
    public func fetchStreamsToSink(): Unit {
        let (client, _) = openSelected(
            "* 1 FETCH (UID 9 BODY[] {11}\r\n" +
                "hello world" +
                ")\r\n" +
                "A0003 OK FETCH completed\r\n"
        )
        let sink = CollectingSink()
        let metas = client.fetch(SequenceSet.single(1), [FetchItem.uid(), FetchItem.body()], sink)
        @Assert(metas.size, 1)
        @Assert(metas[0].uid ?? 0, 9)
        @Assert(sink.text(), "hello world")
        client.close()
    }

    @TestCase
    public func searchUsesCharsetOnlyWhenNeeded(): Unit {
        let (client, transport) = openSelected(
            "* SEARCH 2 84 882\r\nA0003 OK SEARCH completed\r\n" +
                "* SEARCH 5\r\nA0004 OK SEARCH completed\r\n"
        )
        let result = client.search(SearchCriteria.all())
        @Assert(result.size, 3)
        @Assert(result[1], 84)
        let chinese = client.search(SearchCriteria.subject("你好"))
        @Assert(chinese.size, 1)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("A0003 SEARCH ALL"), true)
        @Assert(recorded.contains("A0004 SEARCH CHARSET UTF-8 SUBJECT"), true)
        client.close()
    }

    @TestCase
    public func storeReturnsUpdatedFlags(): Unit {
        let (client, transport) = openSelected(
            "* 1 FETCH (UID 9 FLAGS (\\Deleted \\Seen))\r\nA0003 OK STORE completed\r\n"
        )
        let result = client.store(SequenceSet.single(1), StoreOperation.Add, ["\\Deleted"])
        @Assert(result.updated.size, 1)
        @Assert(result.updated[0].flags.size, 2)
        @Assert(transport.recordedText().contains("STORE 1 +FLAGS (\\Deleted)"), true)
        @Assert(result.isPartialFailure(), false)
        client.close()
    }

    /** 序号移动的代价由调用方承担：返回删掉的原始序号。 */
    @TestCase
    public func expungeReturnsOriginalSequences(): Unit {
        let (client, _) = openSelected(
            "* 2 EXPUNGE\r\n* 2 EXPUNGE\r\nA0003 OK EXPUNGE completed\r\n"
        )
        let removed = client.expunge()
        @Assert(removed.size, 2)
        @Assert(removed[0], 2)
        client.close()
    }

    @TestCase
    public func copyParsesCopyUid(): Unit {
        let (client, _) = openSelected(
            "A0003 OK [COPYUID 1 1:3 10:12] copied\r\n"
        )
        let result = client.uidCopy(SequenceSet.range(1, 3), "Archive")
        @Assert(result.uidValidity ?? 0, 1)
        @Assert((result.destUids.getOrThrow()).toString(), "10:12")
        client.close()
    }

    /** 服务器广告 `LITERAL+` 时不发 `+`，直接把字节写出去。 */
    @TestCase
    public func appendUsesLiteralPlus(): Unit {
        let (client, transport) = openSelected(
            "A0003 OK [APPENDUID 1 5] appended\r\n"
        )
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
        let result = client.append("INBOX", message)
        @Assert(result.uid ?? 0, 5)
        let recorded = transport.recordedText()
        @Assert(recorded.contains("A0003 APPEND INBOX {"), true)
        // LITERAL+ 可用时用 {n+} 并且不等继续请求
        @Assert(recorded.contains("+}"), true)
        client.close()
    }

    @TestCase
    public func appendWithoutLiteralPlusWaits(): Unit {
        let transport = ScriptedTransport(
            server: greeting() +
                "* CAPABILITY IMAP4rev1\r\nA0000 OK done\r\n" +
                "A0001 OK LOGIN completed\r\n" +
                "A0002 OK [READ-WRITE] SELECT completed\r\n" +
                "+ go ahead\r\nA0003 OK APPEND completed\r\n"
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("a", Secret.of("b"))
        client.select("INBOX")
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").text("hi").build()
        client.append("INBOX", message)
        @Assert(transport.recordedText().contains("A0003 APPEND INBOX {"), true)
        @Assert(transport.recordedText().contains("+}"), false)
        client.close()
    }

    @TestCase
    public func logoutConsumesBye(): Unit {
        let (client, _) = openSelected("* BYE logging out\r\nA0003 OK LOGOUT completed\r\n")
        client.logout()
        @Assert(client.isClosed(), true)
    }

    /**
     * 每次 `read` 只返回 1 字节：暴露"依赖一次读满一行/一个 literal"的实现。
     */
    @TestCase
    public func slowStreamCompletesFullSession(): Unit {
        let (client, _) = openSelected(
            "* 1 FETCH (UID 9 BODY[] {5}\r\n" +
                "hello)\r\n" +
                "A0003 OK FETCH completed\r\n",
            chunkSize: 1
        )
        let results = client.fetch(SequenceSet.single(1), [FetchItem.uid(), FetchItem.body()])
        @Assert(results.size, 1)
        @Assert(String.fromUtf8(results[0].body.getOrThrow()), "hello")
        client.close()
    }

    @TestCase
    public func chineseMailboxIsEncodedOnWire(): Unit {
        let (client, transport) = openSelected(
            "* 3 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n"
        )
        client.select("收件箱")
        @Assert(transport.recordedText().contains(ImapUtf7.encode("收件箱")), true)
        client.close()
    }

    @TestCase
    public func commandsRequireSelection(): Unit {
        let (client, _) = openImap(greeting() + CAPABILITY_LINE + "A0001 OK LOGIN completed\r\n")
        client.login("a", Secret.of("b"))
        var caught = false
        try {
            client.fetch(SequenceSet.single(1), [FetchItem.uid()])
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func tagsIncrementMonotonically(): Unit {
        let (client, transport) = openImap(
            greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n" +
                "A0002 OK NOOP completed\r\n"
        )
        client.login("a", Secret.of("b"))
        transport.clearRecorded()
        client.noop()
        @Assert(transport.recordedText().contains("A0002 NOOP"), true)
        client.close()
    }
}
