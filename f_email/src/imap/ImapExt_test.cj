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

/** 只广告 M3 能力（没有 IDLE / MOVE / SPECIAL-USE …）。 */
let BASIC_CAPS = "* CAPABILITY IMAP4rev1 UIDPLUS\r\nA0000 OK done\r\n"

func openBasicSelected(server: String): (ImapClient, ScriptedTransport) {
    let transport = ScriptedTransport(
        server: "* OK ready\r\n" + BASIC_CAPS +
            "A0001 OK LOGIN completed\r\n" +
            "* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n" + server
    )
    let client = ImapClient.builder("localhost", port: 143)
        .requireEncryption(false)
        .allowPlaintextAuth(true)
        .transport(transport)
        .build()
    client.login("a", Secret.of("b"))
    client.select("INBOX")
    (client, transport)
}

@Test
public class ImapEnable_test {
    /** 只有回显的能力才置位：`QRESYNC` 没被回显就一直"未启用"。 */
    @TestCase
    public func onlyEchoedCapabilitiesAreEnabled(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED UTF8=ACCEPT\r\nA0003 OK ENABLE completed\r\n"
        )
        let enabled = ImapEnable(client).enable(["UTF8=ACCEPT", "QRESYNC"])
        @Assert(enabled.size, 1)
        @Assert(enabled[0], "UTF8=ACCEPT")
        @Assert(client.isEnabled("UTF8=ACCEPT"), true)
        @Assert(client.isEnabled("QRESYNC"), false)
        @Assert(transport.recordedText().contains("A0003 ENABLE UTF8=ACCEPT QRESYNC"), true)
        client.close()
    }

    @TestCase
    public func enableRequiresAuthentication(): Unit {
        let (client, transport) = openImap(greeting() + CAPABILITY_LINE)
        var caught = false
        try {
            ImapEnable(client).enable(["UTF8=ACCEPT"])
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("ENABLE"), false)
        client.close()
    }

    /** QRESYNC 蕴含 CONDSTORE，两个一起发会让部分服务器回 BAD。 */
    @TestCase
    public func qresyncDoesNotAlsoEnableCondstore(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED QRESYNC\r\nA0003 OK ENABLE completed\r\n"
        )
        @Assert(ImapEnable(client).enableQResync(), true)
        @Assert(transport.recordedText().contains("A0003 ENABLE QRESYNC\r\n"), true)
        @Assert(transport.recordedText().contains("ENABLE QRESYNC CONDSTORE"), false)
        client.close()
    }

    /** 未 ENABLE 就调用扩展：必须报出具体能力名。 */
    @TestCase
    public func disabledExtensionIsRejected(): Unit {
        let (client, _) = openSelected("")
        var caught = false
        try {
            ImapCondStore(client).select("INBOX")
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "CONDSTORE"
        }
        @Assert(caught, true)
        client.close()
    }
}

@Test
public class ImapSpecialUse_test {
    @TestCase
    public func mapsKnownAttributesAndKeepsUnknown(): Unit {
        let (client, transport) = openSelected(
            "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"\r\n" +
                "* LIST (\\HasNoChildren \\Foo) \"/\" \"Custom\"\r\n" +
                "A0003 OK LIST completed\r\n"
        )
        let boxes = ImapSpecialUse(client).listSpecialUse()
        @Assert(boxes.size, 2)
        @Assert(ImapSpecialUse.specialUseOf(boxes[0]).toString(), "\\Sent")
        @Assert(ImapSpecialUse.specialUseOf(boxes[1]).toString(), "")
        @Assert(boxes[1].hasAttribute("\\Foo"), true)
        @Assert(transport.recordedText().contains("LIST (SPECIAL-USE) \"\" \"*\""), true)
        client.close()
    }

    /** 没有能力时必须抛错，不能全量 LIST 后按名字猜。 */
    @TestCase
    public func withoutCapabilityItFails(): Unit {
        let (client, transport) = openBasicSelected("")
        var caught = false
        try {
            ImapSpecialUse(client).listSpecialUse()
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "SPECIAL-USE"
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("SPECIAL-USE"), false)
        client.close()
    }
}

@Test
public class ImapNamespace_test {
    @TestCase
    public func parsesThreeSegments(): Unit {
        let (client, _) = openSelected(
            "* NAMESPACE ((\"\" \"/\")) NIL ((\"Shared/\" \"/\"))\r\nA0003 OK NAMESPACE completed\r\n"
        )
        let info = ImapNamespace(client).fetch()
        @Assert(info.personal.size, 1)
        @Assert(info.personal[0].prefix, "")
        @Assert(info.personal[0].delimiter ?? "", "/")
        @Assert(info.otherUsers.size, 0)
        @Assert(info.shared.size, 1)
        @Assert(info.shared[0].prefix, "Shared/")
        client.close()
    }

    @TestCase
    public func allNilSegmentsYieldEmpty(): Unit {
        let (client, _) = openSelected("* NAMESPACE NIL NIL NIL\r\nA0003 OK NAMESPACE completed\r\n")
        let info = ImapNamespace(client).fetch()
        @Assert(info.personal.size, 0)
        @Assert(info.shared.size, 0)
        client.close()
    }

    @TestCase
    public func joinPathAvoidsDuplicateSeparator(): Unit {
        @Assert(ImapNamespace.joinPath("", Some("/"), "Sent"), "Sent")
        @Assert(ImapNamespace.joinPath("INBOX", Some("/"), "Sent"), "INBOX/Sent")
        @Assert(ImapNamespace.joinPath("INBOX/", Some("/"), "Sent"), "INBOX/Sent")
        @Assert(ImapNamespace.joinPath("INBOX", Some("/"), "/Sent"), "INBOX/Sent")
        @Assert(ImapNamespace.joinPath("INBOX", None<String>, "Sent"), "INBOXSent")
    }
}

@Test
public class ImapCondStore_test {
    /** `[MODIFIED]` 里的序号 MUST NOT 被当成成功。 */
    @TestCase
    public func modifiedSequencesAreNotSuccesses(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED CONDSTORE\r\nA0003 OK ENABLE completed\r\n" +
                "* 1 FETCH (UID 9 FLAGS (\\Seen) MODSEQ (5))\r\n" +
                "A0004 OK [MODIFIED 3] Store completed\r\n"
        )
        ImapEnable(client).enableCondStore()
        let result = ImapCondStore(client).storeUnchangedSince(
            SequenceSet.of([1, 3]),
            StoreOperation.Add,
            ["\\Seen"],
            4
        )
        @Assert(result.updated.size, 1)
        @Assert(result.updated[0].sequence, 1)
        @Assert(result.modified.size, 1)
        @Assert(result.modified[0], 3)
        @Assert(result.isPartialFailure(), true)
        @Assert(transport.recordedText().contains("STORE 1,3 +FLAGS (UNCHANGEDSINCE 4) (\\Seen)"), true)
        client.close()
    }

    @TestCase
    public func fetchChangedSinceAppendsModifier(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED CONDSTORE\r\nA0003 OK ENABLE completed\r\n" +
                "* 2 FETCH (UID 20 MODSEQ (9))\r\nA0004 OK FETCH completed\r\n"
        )
        ImapEnable(client).enableCondStore()
        let results = ImapCondStore(client).fetchChangedSince(
            SequenceSet.all(),
            7,
            [FetchItem.uid(), FetchItem.modseq()]
        )
        @Assert(results.size, 1)
        @Assert(results[0].modseq ?? 0, 9)
        @Assert(transport.recordedText().contains("FETCH 1:* (UID MODSEQ) (CHANGEDSINCE 7)"), true)
        client.close()
    }

    /** QRESYNC 的 SELECT 参数必须完整带出 uidvalidity 与 modseq。 */
    @TestCase
    public func qresyncSelectCarriesParameters(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED QRESYNC\r\nA0003 OK ENABLE completed\r\n" +
                "* VANISHED (EARLIER) 4:6\r\n" +
                "* OK [HIGHESTMODSEQ 100] ok\r\n" +
                "A0004 OK [READ-WRITE] SELECT completed\r\n"
        )
        ImapEnable(client).enableQResync()
        let status = ImapCondStore(client).select(
            "INBOX",
            qresync: Some(QResyncParams(42, 90, knownUids: Some(SequenceSet.range(1, 3))))
        )
        @Assert(status.highestModSeq ?? 0, 100)
        @Assert(
            transport.recordedText().contains("SELECT INBOX (QRESYNC (42 90 1:3))"),
            true
        )
        client.close()
    }
}

@Test
public class ImapSort_test {
    @TestCase
    public func sortSendsReversedKeysAndCharset(): Unit {
        let (client, transport) = openSelected("* SORT 3 6 1\r\nA0003 OK SORT completed\r\n")
        let order = ImapSort(client).sort(
            [SortKey(SortCriterion.Date), SortKey(SortCriterion.Subject)],
            "UTF-8",
            SearchCriteria.all()
        )
        @Assert(order.size, 3)
        @Assert(order[2], 1)
        @Assert(
            transport.recordedText().contains("A0003 SORT (DATE SUBJECT) UTF-8 ALL"),
            true
        )
        client.close()
    }

    @TestCase
    public func reversePrefixIsWritten(): Unit {
        let (client, transport) = openSelected("* SORT 1\r\nA0003 OK SORT completed\r\n")
        ImapSort(client).sort([SortKey(SortCriterion.Arrival, reverse: true)], "US-ASCII", SearchCriteria.all())
        @Assert(transport.recordedText().contains("SORT (REVERSE ARRIVAL) US-ASCII ALL"), true)
        client.close()
    }

    @TestCase
    public func sortDisplayKeysUseDisplayCapability(): Unit {
        let (client, transport) = openSelected("* SORT 2\r\nA0003 OK SORT completed\r\n")
        let order = ImapSort(client).sort(
            [SortKey(SortCriterion.DisplayFrom)],
            "UTF-8",
            SearchCriteria.all()
        )
        @Assert(order.size, 1)
        @Assert(order[0], 2)
        @Assert(
            transport.recordedText().contains("A0003 SORT (DISPLAY FROM) UTF-8 ALL"),
            true
        )
        client.close()
    }

    @TestCase
    public func sortDisplayKeysRequireSortDisplayCapability(): Unit {
        let transport = ScriptedTransport(
            server: greeting() + "* CAPABILITY IMAP4rev1 SORT\r\nA0000 OK CAPABILITY completed\r\n" +
                "A0001 OK LOGIN completed\r\n* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n"
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        client.select("INBOX")
        var capability: ?String = None
        try {
            ImapSort(client).sort([SortKey(SortCriterion.DisplayTo)], "UTF-8", SearchCriteria.all())
        } catch (e: MailProtocolException) {
            capability = e.capability
        }
        @Assert(capability ?? "", "SORT=DISPLAY")
        @Assert(transport.recordedText().contains("DISPLAY TO"), false)
        client.close()
    }

    /** 只允许 US-ASCII 与 UTF-8，别的字符集本地就拒掉。 */
    @TestCase
    public func otherCharsetsAreRejected(): Unit {
        let (client, _) = openSelected("")
        var caught = false
        try {
            ImapSort(client).sort([SortKey(SortCriterion.Date)], "GBK", SearchCriteria.all())
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    /** `(3 6 (4 23)(44 7 96))`：6 是 3 的子节点，(4 23) 与 (44 7 96) 是 6 的子线程。 */
    @TestCase
    public func threadTreeMatchesRfcShape(): Unit {
        let (client, _) = openSelected(
            "* THREAD (2)(3 6 (4 23)(44 7 96))\r\nA0003 OK THREAD completed\r\n"
        )
        let roots = ImapSort(client).thread(
            ThreadAlgorithm.References,
            "UTF-8",
            SearchCriteria.all()
        )
        @Assert(roots.size, 2)
        @Assert(roots[0].sequence, 2)
        let flattened = roots[1].flatten()
        @Assert(flattened.size, 7)
        @Assert(flattened[0], 3)
        @Assert(flattened[1], 6)
        @Assert(roots[1].children.size, 1)
        @Assert(roots[1].children[0].children.size, 2)
        client.close()
    }

    @TestCase
    public func threadHandlesThousandSiblings(): Unit {
        var raw = "* THREAD"
        for (i in 1..=1000) {
            raw = raw + "(${i})"
        }
        raw = raw + "\r\nA0003 OK THREAD completed\r\n"
        let (client, _) = openSelected(raw)
        let roots = ImapSort(client).thread(
            ThreadAlgorithm.References,
            "UTF-8",
            SearchCriteria.all()
        )
        @Assert(roots.size, 1000)
        @Assert(roots[999].flatten()[0], 1000)
        client.close()
    }

    @TestCase
    public func threadAlgorithmMustBeAdvertised(): Unit {
        let (client, _) = openBasicSelected("")
        var caught = false
        try {
            ImapSort(client).thread(ThreadAlgorithm.References, "UTF-8", SearchCriteria.all())
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "THREAD=REFERENCES"
        }
        @Assert(caught, true)
        client.close()
    }
}

@Test
public class ImapMove_test {
    @TestCase
    public func atomicMoveParsesCopyUidAndVanished(): Unit {
        let (client, _) = openSelected(
            "* VANISHED 1:2\r\n" +
                "A0003 OK [COPYUID 1 1:2 11:12] MOVE completed\r\n"
        )
        let result = ImapMove(client).uidMove(SequenceSet.range(1, 2), "Archive")
        @Assert(result.atomic, true)
        @Assert((result.copyUid.destUids.getOrThrow()).toString(), "11:12")
        @Assert(result.vanished.size, 1)
        @Assert(result.vanished[0], "1:2")
        client.close()
    }

    /** 默认不回退：没广告 MOVE 时必须报错，且一个 COPY 都不发。 */
    @TestCase
    public func nonAtomicFallbackIsOptIn(): Unit {
        let (client, transport) = openBasicSelected("")
        var caught = false
        try {
            ImapMove(client).uidMove(SequenceSet.range(1, 2), "Archive")
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "MOVE"
        }
        @Assert(caught, true)
        @Assert(transport.recordedText().contains("COPY"), false)
        client.close()
    }

    @TestCase
    public func nonAtomicFallbackRunsThreeStepsInOrder(): Unit {
        let (client, transport) = openBasicSelected(
            "A0003 OK [COPYUID 1 1:2 11:12] copied\r\n" +
                "A0004 OK STORE completed\r\n" +
                "* 1 EXPUNGE\r\n* 1 EXPUNGE\r\n" +
                "A0005 OK UID EXPUNGE completed\r\n"
        )
        let result = ImapMove(client).uidMove(SequenceSet.range(1, 2), "Archive", allowNonAtomic: true)
        @Assert(result.atomic, false)
        @Assert(result.expunged.size, 2)
        let recorded = transport.recordedText()
        let copyIndex = recorded.indexOf("UID COPY 1:2 Archive") ?? -1
        let storeIndex = recorded.indexOf("STORE 1:2 +FLAGS.SILENT (\\Deleted)") ?? -1
        let expungeIndex = recorded.indexOf("UID EXPUNGE 1:2") ?? -1
        @Assert(copyIndex >= 0, true)
        @Assert(copyIndex < storeIndex, true)
        @Assert(storeIndex < expungeIndex, true)
        client.close()
    }
}

@Test
public class ImapUtf8Accept_test {
    /** 启用后邮箱名直传 UTF-8，不再走 modified UTF-7。 */
    @TestCase
    public func mailboxIsSentRawAfterEnable(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED UTF8=ACCEPT\r\nA0003 OK ENABLE completed\r\n" +
                "* 1 EXISTS\r\nA0004 OK [READ-WRITE] SELECT completed\r\n"
        )
        ImapEnable(client).enableUtf8Accept()
        client.select("收件箱")
        @Assert(transport.recordedText().contains("收件箱"), true)
        @Assert(transport.recordedText().contains(ImapUtf7.encode("收件箱")), false)
        client.close()
    }

    /** 启用后 SEARCH 省略 CHARSET（字符串本身就是 UTF-8）。 */
    @TestCase
    public func searchOmitsCharsetAfterEnable(): Unit {
        let (client, transport) = openSelected(
            "* ENABLED UTF8=ACCEPT\r\nA0003 OK ENABLE completed\r\n" +
                "* SEARCH 1\r\nA0004 OK SEARCH completed\r\n"
        )
        ImapEnable(client).enableUtf8Accept()
        client.search(SearchCriteria.subject("你好"))
        @Assert(transport.recordedText().contains("A0004 SEARCH SUBJECT \"你好\""), true)
        @Assert(transport.recordedText().contains("CHARSET"), false)
        client.close()
    }

    /** 未启用时必须完整走 UTF-7 路径，不做"能发就发 UTF-8"的尝试式降级。 */
    @TestCase
    public func withoutEnableItStaysOnUtf7(): Unit {
        let (client, transport) = openSelected(
            "* 1 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n"
        )
        client.select("收件箱")
        @Assert(transport.recordedText().contains(ImapUtf7.encode("收件箱")), true)
        @Assert(transport.recordedText().contains("收件箱"), false)
        client.close()
    }
}

@Test
public class ImapIdle_test {
    @TestCase
    public func pushesBecomeEvents(): Unit {
        let (client, transport) = openSelected(
            "+ idling\r\n* 5 EXISTS\r\n* 2 EXPUNGE\r\nA0003 OK IDLE terminated\r\n"
        )
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        let first = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(first.isSome(), true)
        @Assert(first.getOrThrow().kind.toString(), "EXISTS")
        @Assert(first.getOrThrow().sequence ?? 0, 5)
        let second = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(second.getOrThrow().kind.toString(), "EXPUNGE")
        session.done()
        @Assert(transport.recordedText().contains("A0003 IDLE"), true)
        @Assert(transport.recordedText().contains("DONE"), true)
        client.close()
    }

    /** IDLE 期间调用普通命令必须立即失败，不排队。 */
    @TestCase
    public func commandsAreRejectedWhileIdle(): Unit {
        let (client, _) = openSelected("+ idling\r\n")
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        var caught = false
        try {
            client.noop()
        } catch (e: MailProtocolException) {
            caught = e.message.contains("idle")
        }
        @Assert(caught, true)
        session.done()
        client.close()
    }

    /** `* BYE` 先作为事件投递，再结束会话；之后 nextEvent 抛错而不是返回 None。 */
    @TestCase
    public func byeIsDeliveredThenSessionEnds(): Unit {
        let (client, _) = openSelected("+ idling\r\n* BYE server shutting down\r\n")
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        let event = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(event.getOrThrow().kind.toString(), "BYE")
        var caught = false
        try {
            session.nextEvent(timeout: Duration.millisecond * 50)
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        client.close()
    }

    @TestCase
    public func rebuildsIdleAfterSilence(): Unit {
        let transport = ScriptedTransport(
            server: greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n" +
                "+ idling\r\n",
            blockAtEnd: true
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        client.select("INBOX")
        let session = ImapIdle(client)
            .withRebuildAfter(Duration.millisecond * 30)
            .withPollInterval(Duration.millisecond * 5)
            .start()
        sleep(Duration.millisecond * 60)
        transport.pushServer("A0003 OK IDLE terminated\r\n+ idling\r\n")
        sleep(Duration.millisecond * 60)
        @Assert(session.rebuildCount >= 1, true)
        session.done()
        client.close()
    }

    @TestCase
    public func enableEmptyListIsNoop(): Unit {
        let (client, transport) = openSelected("")
        let enabled = ImapEnable(client).enable([])
        @Assert(enabled.size, 0)
        @Assert(transport.recordedText().contains("ENABLE"), false)
        client.close()
    }

    @TestCase
    public func sortKeepsDuplicateSequences(): Unit {
        let (client, _) = openSelected("* SORT 3 3 1\r\nA0003 OK SORT completed\r\n")
        let order = ImapSort(client).sort([SortKey(SortCriterion.Date)], "UTF-8", SearchCriteria.all())
        @Assert(order.size, 3)
        @Assert(order[0], 3)
        @Assert(order[1], 3)
        @Assert(order[2], 1)
        client.close()
    }

    @TestCase
    public func sortWorksWithOneByteStream(): Unit {
        let (client, transport) = openSelected(
            "* SORT 2 1\r\nA0003 OK SORT completed\r\n",
            chunkSize: 1
        )
        let order = ImapSort(client).sort([SortKey(SortCriterion.Arrival)], "US-ASCII", SearchCriteria.all())
        @Assert(order.size, 2)
        @Assert(transport.recordedText().contains("SORT (ARRIVAL) US-ASCII ALL"), true)
        client.close()
    }

    @TestCase
    public func vanishedEarlierIsDistinguished(): Unit {
        let (client, _) = openSelected(
            "+ idling\r\n* VANISHED (EARLIER) 1:3\r\n* VANISHED 4:5\r\nA0003 OK IDLE terminated\r\n"
        )
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        let first = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(first.getOrThrow().kind.toString(), "VANISHED")
        @Assert(first.getOrThrow().earlier, true)
        let second = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(second.getOrThrow().earlier, false)
        session.done()
        client.close()
    }

    @TestCase
    public func crossThreadCloseEndsIdle(): Unit {
        let transport = ScriptedTransport(
            server: greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n" +
                "+ idling\r\n",
            blockAtEnd: true
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        client.select("INBOX")
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        spawn {
            =>
                sleep(Duration.millisecond * 30)
                session.close()
        }
        sleep(Duration.millisecond * 120)
        @Assert(session.isFinished(), true)
        client.close()
    }

    @TestCase
    public func untaggedAroundDoneIsStillQueued(): Unit {
        let (client, transport) = openSelected("+ idling\r\n")
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        transport.pushServer("* 7 EXISTS\r\nA0003 OK IDLE terminated\r\n")
        session.done()
        let event = session.nextEvent(timeout: Duration.millisecond * 500)
        @Assert(event.isSome(), true)
        @Assert(event.getOrThrow().kind.toString(), "EXISTS")
        @Assert(event.getOrThrow().sequence ?? 0, 7)
        client.close()
    }

    @TestCase
    public func idleLinesAreTraced(): Unit {
        let trace = IdleTrace()
        let transport = ScriptedTransport(
            server: greeting() + CAPABILITY_LINE +
                "A0001 OK LOGIN completed\r\n* 1 EXISTS\r\nA0002 OK [READ-WRITE] SELECT completed\r\n" +
                "+ idling\r\n* 5 EXISTS\r\nA0003 OK IDLE terminated\r\n",
            trace: trace
        )
        let client = ImapClient.builder("localhost", port: 143)
            .requireEncryption(false)
            .allowPlaintextAuth(true)
            .transport(transport)
            .build()
        client.login("alice", Secret.of("pw"))
        client.select("INBOX")
        let session = ImapIdle(client).withPollInterval(Duration.millisecond * 5).start()
        @Assert(session.nextEvent(timeout: Duration.millisecond * 500).isSome(), true)
        session.done()
        @Assert(trace.lines.contains("* 5 EXISTS"), true)
        @Assert(trace.lines.contains("DONE"), true)
        client.close()
    }

    @TestCase
    public func idleWithoutCapabilityFails(): Unit {
        let (client, _) = openBasicSelected("")
        var caught = false
        try {
            ImapIdle(client).start()
        } catch (e: MailProtocolException) {
            caught = (e.capability ?? "") == "IDLE"
        }
        @Assert(caught, true)
        client.close()
    }
}

class IdleTrace <: MailTrace {
    let lines = ArrayList<String>()

    public func onLine(direction: Rune, line: String): Unit {
        lines.add(line)
    }

    public func onBytes(direction: Rune, count: Int64): Unit {}
}
