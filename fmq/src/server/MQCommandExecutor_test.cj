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
package fountain::fmq.server

import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.*
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_protocol.default.*
import fountain::fmq.cluster.{BackupReplicator, MetaSyncer, NodeRegistry}
import fountain::fmq.meta.MetaStore
import fountain::fmq.queue.*
import fountain::fmq.test.TestDirs

class ExecutorFixture <: Resource {
    let root: String
    let meta: MetaStore
    let queues: QueueManager
    let cursorStore: CursorStore
    let cursors: CursorCatalog
    let dead: DeadLetterQueue
    let subscribers: SubscriberRegistry
    let consume: ConsumeService
    let executor: MQCommandExecutor
    private let registry: NodeRegistry
    private let backup: BackupReplicator

    init(name: String, selfIndex!: Int64 = 0, nodes!: Array<String> = ["127.0.0.1:1"]) {
        this.root = TestDirs.of("executor", name)
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.meta = MetaStore("${root}/metas")
        meta.load()
        this.registry = NodeRegistry(nodes, selfIndex)
        let syncer = MetaSyncer(meta, registry)
        this.queues = QueueManager("${root}/logs", 1024 * 1024, 1)
        this.cursorStore = CursorStore("${root}/metas")
        this.cursors = CursorCatalog(cursorStore, meta)
        this.dead = DeadLetterQueue("${root}/dead", 1024 * 1024, 1)
        this.subscribers = SubscriberRegistry()
        this.consume = ConsumeService(queues, cursors, subscribers, MQMatcher(), dead,
            Duration.second * 10, 3)
        this.backup = BackupReplicator(registry, 0)
        let backupStore = BackupStore("${root}/logs", 1024 * 1024, 1)
        this.executor = MQCommandExecutor(meta, syncer, queues, cursors, subscribers, consume, backup,
            backupStore, selfIndex)
    }

    func call(message: Message): Message {
        executor.execute(message).getOrThrow()
    }

    func registerTopic(topic: String, queueNum: Int64, delayingMs!: Int64 = 0): Message {
        call(MQProtocol.registerTopic(MQTopicMeta(topic, queueNum, delayingMs: delayingMs)))
    }

    func registerGroup(topic: String, group: String): Message {
        call(MQProtocol.registerGroup(MQSubscribeGroupMeta(topic, group)))
    }

    func publish(topic: String, body: Data, tags!: Array<String> = []): Message {
        let record = MQMessageRecord.encode(topic, tags, "mid", body)
        call(MQProtocol.publish(record))
    }

    func firstRecord(topic: String, queueIndex: Int64): ?Array<Byte> {
        match (queues.queueOf(topic, queueIndex)) {
            case None => None<Array<Byte>>
            case Some(log) =>
                let reader = log.openRecordsFrom(LogPosition(1, 0))
                try {
                    match (reader.next()) {
                        case Some(item) => Some(item[0])
                        case None => None<Array<Byte>>
                    }
                } finally {
                    reader.close()
                }
        }
    }

    public func isClosed(): Bool {
        false
    }

    public func close(): Unit {
        consume.close()
        queues.close()
        dead.close()
        meta.close()
        registry.close()
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }
}

@Test
class MQCommandExecutorTest {
    private static func codeOf(message: Message): Int64 {
        MQProtocol.asResult(message).code
    }

    private static func bodyOf(result: MQConsumeResult): String {
        let content = MQMessageRecord.decode(result.record.copyBytes()).getOrThrow()
        convert<String>(content.body.data).getOrThrow()
    }

    /** 非法组名在注册入口被拒，且不落盘、不建目录（A05）。 */
    @TestCase
    public func registerGroupRejectsInvalidName(): Unit {
        let fixture = ExecutorFixture("bad_group")
        try {
            @Assert(MQProtocol.asPayload<MQTopicAssignment>(fixture.registerTopic("/t", 1)).isSome())
            for (name in ["g 1", "g:1", "g/1", "g%2F", ".g", "g."]) {
                @Assert(codeOf(fixture.registerGroup("/t", name)) == MQErrorCode.INVALID_GROUP)
            }
            @Assert(!fixture.meta.groupExists("/t", "g 1"))
            let dir = "${fixture.root}/metas/groups"
            // 用数组做盒子：闭包不能捕获可变局部变量
            let files = Array<Int64>(1, repeat: 0)
            if (exists(dir)) {
                Directory.walk(dir) {info: FileInfo =>
                    if (!info.isDirectory()) {
                        files[0] = files[0] + 1
                    }
                    true
                }
            }
            @Assert(files[0] == 0)
        } finally {
            fixture.close()
        }
    }

    /** `kind` 拼错/大小写变体不得落到「删除订阅组」分支，也不得删任何东西（A10）。 */
    @TestCase
    public func deregisterWithUnknownKindDeletesNothing(): Unit {
        let fixture = ExecutorFixture("bad_kind")
        try {
            @Assert(MQProtocol.asPayload<MQTopicAssignment>(fixture.registerTopic("/t", 1)).isSome())
            @Assert(codeOf(fixture.registerGroup("/t", "g")) == 0)
            for (kind in ["", "Topic", "GROUP", "subscriber", "topics"]) {
                let response = fixture.call(
                    MQProtocol.deregister(MQDeregisterPayload(kind, "/t", subscribeGroup: "g")))
                @Assert(codeOf(response) == MQErrorCode.INTERNAL)
            }
            @Assert(fixture.meta.topicOf("/t").isSome())
            @Assert(fixture.meta.groupExists("/t", "g"))
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func registerTopicReturnsAssignment(): Unit {
        let fixture = ExecutorFixture("register_topic")
        try {
            let response = fixture.registerTopic("/t", 2)
            match (response.command) {
                case RESP(_) => @Assert(true)
                case _ => @Assert(false)
            }
            let assignment = MQProtocol.asPayload<MQTopicAssignment>(response).getOrThrow()
            @Assert(assignment.topic == "/t")
            @Assert(assignment.owners == [0, 0])
            @Assert(fixture.meta.topicOf("/t").getOrThrow().queueNum == 2)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func invalidTopicIsRejected(): Unit {
        let fixture = ExecutorFixture("invalid_topic")
        try {
            let response = fixture.registerTopic("order", 1)
            @Assert(response.command == Command.ERROR)
            @Assert(codeOf(response) == MQErrorCode.INVALID_TOPIC)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func duplicateTopicIsRejected(): Unit {
        let fixture = ExecutorFixture("duplicate_topic")
        try {
            fixture.registerTopic("/t", 1)
            @Assert(codeOf(fixture.registerTopic("/t", 1)) == MQErrorCode.TOPIC_ALREADY_EXIST)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func registerGroupAndRejectUnknownGroup(): Unit {
        let fixture = ExecutorFixture("group")
        try {
            @Assert(codeOf(fixture.registerGroup("/t", "g")) == MQErrorCode.TOPIC_NOT_EXIST)
            fixture.registerTopic("/t", 1)
            @Assert(codeOf(fixture.registerGroup("/t", "")) == 0)
            @Assert(codeOf(fixture.registerGroup("/t", "")) == MQErrorCode.GROUP_ALREADY_EXIST)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func publishStoresRecordByteForByte(): Unit {
        let fixture = ExecutorFixture("publish")
        try {
            fixture.registerTopic("/t", 1)
            @Assert(codeOf(fixture.publish("/t", "hello".toData(), tags: ["a"])) == 0)
            let stored = fixture.firstRecord("/t", 0).getOrThrow()
            let content = MQMessageRecord.decode(stored).getOrThrow()
            @Assert(content.topic == "/t")
            @Assert(content.tags == ["a"])
            @Assert(convert<String>(content.body.data) == Some("hello"))
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func largeRecordIsStoredWithoutLoss(): Unit {
        let fixture = ExecutorFixture("large")
        try {
            fixture.registerTopic("/t", 1)
            let big = Array<Byte>(16 * 1024, repeat: 0x5Au8)
            @Assert(codeOf(fixture.publish("/t", big.toData())) == 0)
            let stored = fixture.firstRecord("/t", 0).getOrThrow()
            let content = MQMessageRecord.decode(stored).getOrThrow()
            @Assert(MQBytes.fromData(content.body.data).getOrThrow() == big)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func publishToUnknownTopicFails(): Unit {
        let fixture = ExecutorFixture("unknown_topic")
        try {
            @Assert(codeOf(fixture.publish("/missing", 1i64.toData())) == MQErrorCode.TOPIC_NOT_EXIST)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func publishToNonOwnerFails(): Unit {
        let fixture = ExecutorFixture("not_owner", selfIndex: 1, nodes: ["127.0.0.1:1", "127.0.0.1:2"])
        try {
            fixture.registerTopic("/t", 1)
            // start=0、1 个队列 ⇒ owner 0，本机 1 没有队列
            @Assert(codeOf(fixture.publish("/t", 1i64.toData())) == MQErrorCode.NOT_OWNER)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func unsupportedBodyIsRejectedBeforeAppend(): Unit {
        let fixture = ExecutorFixture("filter_unsupported")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")
            @Assert(codeOf(fixture.call(MQProtocol.subscribe(
                MQSubscribePayload("sid-filter", "/t", "g", [], "$.enabled", false)))) == 0)
            // BODY 无法解码（模拟未注册对象 / 损坏）：topic 与 tags 仍可解，filter 无法评估
            let full = MQMessageRecord.encode("/t", [], "mid", "body".toData())
            let truncated = full[0..full.size - 3]
            let rejected = fixture.call(MQProtocol.publish(truncated))
            @Assert(rejected.command == Command.ERROR)
            @Assert(codeOf(rejected) == MQErrorCode.FILTER_UNSUPPORTED_BODY)
            // 不得落盘，也不得入备份队列
            @Assert(fixture.queues.queueOf("/t", 0).getOrThrow().size == 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func emptyFilterPublishesWithoutDecodingBody(): Unit {
        let fixture = ExecutorFixture("filter_empty")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")
            @Assert(codeOf(fixture.call(MQProtocol.subscribe(
                MQSubscribePayload("sid-empty", "/t", "g", [], "", false)))) == 0)
            let full = MQMessageRecord.encode("/t", [], "mid", "body".toData())
            let truncated = full[0..full.size - 3]
            // 空 filter 不需要服务端解码 BODY，照常发布
            @Assert(codeOf(fixture.call(MQProtocol.publish(truncated))) == 0)
            @Assert(fixture.queues.queueOf("/t", 0).getOrThrow().size > 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func subscribeConsumeAckFlow(): Unit {
        let fixture = ExecutorFixture("flow")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")
            let sid = "sid-flow"
            @Assert(codeOf(fixture.call(MQProtocol.subscribe(MQSubscribePayload(sid, "/t", "g", [], "", false)))) == 0)
            fixture.publish("/t", "one".toData())
            fixture.publish("/t", "two".toData())

            let first = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid)))).getOrThrow()
            @Assert(bodyOf(first) == "one")
            @Assert(fixture.consume.ack(fixture.subscribers.of(sid).getOrThrow(),
                MQAckPayload(sid, first.queueIndex, first.segmentedIndex, first.segmentedOffset)).code == 0)

            let second = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid)))).getOrThrow()
            @Assert(bodyOf(second) == "two")
            @Assert(fixture.consume.ack(fixture.subscribers.of(sid).getOrThrow(),
                MQAckPayload(sid, second.queueIndex, second.segmentedIndex, second.segmentedOffset)).code == 0)

            // 空消费不是错误
            let empty = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid)))).getOrThrow()
            @Assert(empty.record.size() == 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func ackUnknownPositionFails(): Unit {
        let fixture = ExecutorFixture("ack_unknown")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")
            let sid = "sid-ack"
            fixture.call(MQProtocol.subscribe(MQSubscribePayload(sid, "/t", "g", [], "", false)))
            let response = fixture.call(MQProtocol.ack(MQAckPayload(sid, 0, 999, 999)))
            @Assert(codeOf(response) == MQErrorCode.ACK_UNKNOWN)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func subscribeWithUnknownGroupFails(): Unit {
        let fixture = ExecutorFixture("unknown_group")
        try {
            fixture.registerTopic("/t", 1)
            let response = fixture.call(MQProtocol.subscribe(MQSubscribePayload("s", "/t", "missing", [], "", false)))
            @Assert(codeOf(response) == MQErrorCode.GROUP_NOT_EXIST)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func metaSyncRequestReturnsSnapshot(): Unit {
        let fixture = ExecutorFixture("snapshot")
        try {
            fixture.registerTopic("/t", 2)
            let response = fixture.call(MQProtocol.metaSync(MQMetaSyncRequest(1)))
            let snapshot = MQProtocol.asPayload<MQMetaSnapshot>(response).getOrThrow()
            @Assert(snapshot.topics.size == 1)
            @Assert(snapshot.topics[0].topic == "/t")
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func backupPayloadOnlyWritesCopy(): Unit {
        let fixture = ExecutorFixture("backup")
        try {
            fixture.registerTopic("/t", 1)
            let payload = MQBackupPayload(0, "/t", 0, [[1u8, 2u8]], [MQBackupState(1, 0, 0, false)])
            @Assert(codeOf(fixture.call(MQProtocol.publishBackup(payload))) == 0)
            @Assert(exists("${fixture.root}/logs/backup/0/%2Ft/0"))
            // 副本不进入本队列
            @Assert(fixture.queues.queueOf("/t", 0).getOrThrow().size == 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func garbagePayloadReturnsInternalError(): Unit {
        let fixture = ExecutorFixture("garbage")
        try {
            let response = fixture.call(Message(Command.PUBLISH(0), DataNone.INSTANCE))
            @Assert(response.command == Command.ERROR)
            @Assert(codeOf(response) == MQErrorCode.INTERNAL)
            // 连接仍可用：后续正常请求成功
            fixture.registerTopic("/t", 1)
            @Assert(fixture.meta.topicOf("/t").isSome())
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func deregisterTopicDeletesFilesAndMetadata(): Unit {
        let fixture = ExecutorFixture("deregister")
        try {
            fixture.registerTopic("/t", 1)
            fixture.publish("/t", 1i64.toData())
            let response = fixture.call(MQProtocol.deregister(MQDeregisterPayload("topic", "/t")))
            @Assert(codeOf(response) == 0)
            @Assert(!exists("${fixture.root}/logs/%2Ft"))
            @Assert(fixture.meta.topicOf("/t").isNone())
            @Assert(codeOf(fixture.publish("/t", 2i64.toData())) == MQErrorCode.TOPIC_NOT_EXIST)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func unsubscribeReleasesDelivery(): Unit {
        let fixture = ExecutorFixture("unsubscribe")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")
            let sid = "sid-unsub"
            fixture.call(MQProtocol.subscribe(MQSubscribePayload(sid, "/t", "g", [], "", false)))
            fixture.publish("/t", "one".toData())
            let message = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid)))).getOrThrow()
            @Assert(message.record.size() > 0)
            @Assert(codeOf(fixture.call(MQProtocol.unsubscribe(MQUnsubscribePayload(sid)))) == 0)
            @Assert(fixture.subscribers.of(sid).isNone())
            // 未知订阅退订
            @Assert(codeOf(fixture.call(MQProtocol.unsubscribe(MQUnsubscribePayload(sid)))) ==
                MQErrorCode.SUBSCRIBE_NOT_EXIST)
        } finally {
            fixture.close()
        }
    }
    @TestCase
    public func statsInternalReturnsSnapshot(): Unit {
        let fixture = ExecutorFixture("stats")
        try {
            fixture.registerTopic("/s", 2)
            fixture.registerGroup("/s", "g")
            fixture.publish("/s", "one".toData())
            let response = fixture.call(MQProtocol.stats("/s"))
            let text = convert<String>(response.data).getOrThrow()
            @Assert(text.startsWith("#\t0\t"))
            @Assert(text.contains("R\t/s\tg\t"))
        } finally {
            fixture.close()
        }
    }
}
