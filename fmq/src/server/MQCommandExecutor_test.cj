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
import fountain::fmq.metrics.MQMetrics
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
    let metrics: MQMetrics
    let consume: ConsumeService
    let executor: MQCommandExecutor
    let syncer: MetaSyncer
    private let registry: NodeRegistry
    let backup: BackupReplicator
    let backupStore: BackupStore

    init(name: String, selfIndex!: Int64 = 0, nodes!: Array<String> = ["127.0.0.1:1"],
        backupCount!: Int64 = 0) {
        this.root = TestDirs.of("executor", name)
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.meta = MetaStore("${root}/metas")
        meta.load()
        this.registry = NodeRegistry(nodes, selfIndex)
        this.syncer = MetaSyncer(meta, registry)
        this.queues = QueueManager("${root}/logs", 1024 * 1024, 1)
        this.cursorStore = CursorStore("${root}/metas")
        this.cursors = CursorCatalog(cursorStore, meta)
        this.dead = DeadLetterQueue("${root}/dead", 1024 * 1024, 1)
        this.subscribers = SubscriberRegistry()
        let metrics = MQMetrics()
        this.metrics = metrics
        this.consume = ConsumeService(queues, cursors, subscribers, MQMatcher(), dead,
            Duration.second * 10, 3, metrics: metrics)
        this.backup = BackupReplicator(registry, backupCount)
        let backupStore = BackupStore("${root}/logs", 1024 * 1024, 1)
        this.backupStore = backupStore
        this.executor = MQCommandExecutor(meta, syncer, queues, cursors, subscribers, consume, backup,
            backupStore, selfIndex)
        // 与 `MQServer` 的装配保持一致：peer 墓碑生效后清理本机状态（A25）
        let commandExecutor = this.executor
        syncer.onDeleted = {payload => commandExecutor.cleanupAfterDelete(payload)}
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

    /** `backup >= 1` 时发布一条记录，备份替身恰好收到一次入队（R4-G14）。 */
    @TestCase
    public func publishWithBackupEnqueuesOnce(): Unit {
        let fixture = ExecutorFixture("backup_enqueue", backupCount: 1)
        try {
            fixture.registerTopic("/t", 1)
            @Assert(codeOf(fixture.publish("/t", 1i64.toData())) == 0)
            @Assert(fixture.backup.pendingCount == 1)
        } finally {
            fixture.close()
        }
    }

    /** 命令矩阵的六条错误分支：都必须给出确定的错误码，不能挂起（R4-G13）。 */
    @TestCase
    public func commandMatrixReturnsDeterministicErrors(): Unit {
        let fixture = ExecutorFixture("matrix")
        try {
            fixture.registerTopic("/t", 1)
            fixture.registerGroup("/t", "g")

            // 1. SUBSCRIBE 的 tags 非法
            @Assert(codeOf(fixture.call(MQProtocol.subscribe(
                MQSubscribePayload("sid", "/t", "g", ["bad tag"], "", false)))) == MQErrorCode.INVALID_TAGS)

            // 2. SUBSCRIBE 时本机没有该主题队列
            let other = ExecutorFixture("matrix_owner", selfIndex: 1, nodes: ["127.0.0.1:1", "127.0.0.1:2"])
            try {
                other.registerTopic("/u", 1)
                other.registerGroup("/u", "g")
                @Assert(codeOf(other.call(MQProtocol.subscribe(
                    MQSubscribePayload("sid2", "/u", "g", [], "", false)))) == MQErrorCode.NOT_OWNER)
            } finally {
                other.close()
            }

            // 3. REGISTER 收到意外载荷
            @Assert(codeOf(fixture.call(Message(Command.REGISTER, MQResult(0, "ok").toData()))) ==
                MQErrorCode.INTERNAL)

            // 4. 内部信封的未知 kind
            @Assert(codeOf(fixture.call(Message.register<MQInternalMessage>(
                data: MQInternalMessage("weird", Array<Byte>())))) == MQErrorCode.INTERNAL)

            // 5. PUBLISH 收到非 backup 的内部信封
            @Assert(codeOf(fixture.call(Message.publish<MQInternalMessage>(dup: false, qos: QoS.AtMostOnce,
                retain: false, data: MQInternalMessage(MQInternalKind.META_SYNC, Array<Byte>())))) ==
                MQErrorCode.INTERNAL)

            // 6. META_SYNC 收到未知子载荷
            @Assert(codeOf(fixture.call(Message.register<MQInternalMessage>(
                data: MQInternalMessage(MQInternalKind.META_SYNC,
                    MQProtocol.encodePayload<String>("not-a-sub-payload"))))) == MQErrorCode.INTERNAL)
        } finally {
            fixture.close()
        }
    }

    /** 备份批次的状态数与记录数不匹配：记录照常落盘，位点不更新且留 WARN（R2-G5）。 */
    @TestCase
    public func backupStatesMismatchSkipsCursors(): Unit {
        CapturingAppender.install()
        let fixture = ExecutorFixture("backup_mismatch")
        try {
            fixture.registerTopic("/t", 1)
            let payload = MQBackupPayload(0, "/t", 0, [[1u8], [2u8]], [MQBackupState(1, 0, 0, true)],
                cursors: [MQBackupCursor("g", 1, 0)])
            @Assert(codeOf(fixture.call(MQProtocol.publishBackup(payload))) == 0)
            @Assert(exists("${fixture.root}/logs/backup/0/%2Ft/0"))
            @Assert(fixture.backupStore.loadCursor(0, "/t", 0, "g").isNone())
            @Assert(CapturingAppender.waitFor(["2 records", "1 states"]))
        } finally {
            fixture.close()
        }
    }

    /** 状态数匹配时位点才落盘（R2-G5）。 */
    @TestCase
    public func backupCursorsAppliedWhenStatesMatch(): Unit {
        let fixture = ExecutorFixture("backup_cursors")
        try {
            fixture.registerTopic("/t", 1)
            let payload = MQBackupPayload(0, "/t", 0, [[1u8], [2u8]],
                [MQBackupState(1, 0, 0, true), MQBackupState(1, 8, 0, false)],
                cursors: [MQBackupCursor("g", 1, 8)])
            @Assert(codeOf(fixture.call(MQProtocol.publishBackup(payload))) == 0)
            let cursor = fixture.backupStore.loadCursor(0, "/t", 0, "g").getOrThrow()
            @Assert(cursor.seq == 1)
            @Assert(cursor.offset == 8)
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

    /** 内部 metaSync 的三条变更分支（主题 / 组 / 墓碑）都能落地并生效（A67）。 */
    @TestCase
    public func internalMetaSyncAppliesTopicGroupAndTombstone(): Unit {
        let fixture = ExecutorFixture("internal_apply")
        try {
            @Assert(codeOf(fixture.call(MQProtocol.metaSync(
                MQTopicAssignment("/t", 1, 0, [0], revision: 1)))) == 0)
            @Assert(fixture.meta.topicOf("/t").isSome())
            // 广播路径也要为本机打开队列，否则发布得到 NOT_OWNER
            @Assert(fixture.queues.queueOf("/t", 0).isSome())

            @Assert(codeOf(fixture.call(MQProtocol.metaSync(
                MQSubscribeGroupMeta("/t", "g", revision: 2)))) == 0)
            @Assert(fixture.meta.groupExists("/t", "g"))

            let tombstone = MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 9, 0, 0)
            @Assert(codeOf(fixture.call(MQProtocol.metaSync(tombstone))) == 0)
            @Assert(fixture.meta.topicOf("/t").isNone())
            @Assert(!fixture.meta.groupExists("/t", "g"))
        } finally {
            fixture.close()
        }
    }

    /** peer 的主题墓碑生效后，队列目录 / 游标文件 / 订阅 / 计数器全部清空（A25/F1）。 */
    @TestCase
    public func topicTombstoneFromPeerClearsLocalState(): Unit {
        let fixture = ExecutorFixture("tombstone_topic_cleanup")
        try {
            @Assert(MQProtocol.asPayload<MQTopicAssignment>(fixture.registerTopic("/t", 1)).isSome())
            @Assert(codeOf(fixture.registerGroup("/t", "g")) == 0)
            let sid = "sid-tomb-topic"
            @Assert(codeOf(fixture.call(
                MQProtocol.subscribe(MQSubscribePayload(sid, "/t", "g", [], "", false)))) == 0)
            fixture.publish("/t", "one".toData())
            let message = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid)))).getOrThrow()
            @Assert(codeOf(fixture.call(MQProtocol.ack(
                MQAckPayload(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)))) == 0)

            let queueDir = "${fixture.root}/logs/%2Ft"
            let cursorFile = "${fixture.root}/metas/offsets/%2Ft/0/g.cursor"
            @Assert(exists(queueDir))
            @Assert(exists(cursorFile))
            @Assert(fixture.subscribers.of(sid).isSome())
            @Assert(fixture.metrics.deliveredOf("/t", "g") > 0)

            // peer 广播的墓碑（origin != 本机下标）
            @Assert(codeOf(fixture.call(MQProtocol.metaSync(
                MQMetaTombstone(MQMetaTombstone.KIND_TOPIC, "/t", "", 99, 1, 0)))) == 0)

            @Assert(!exists(queueDir))
            @Assert(!exists(cursorFile))
            @Assert(fixture.subscribers.of(sid).isNone())
            @Assert(fixture.metrics.deliveredOf("/t", "g") == 0)
            @Assert(fixture.metrics.ackedOf("/t", "g") == 0)
        } finally {
            fixture.close()
        }
    }

    /** peer 的组墓碑生效后，只清该组的游标/订阅/计数器，主题队列保留（A25/F1）。 */
    @TestCase
    public func groupTombstoneFromPeerClearsGroupStateOnly(): Unit {
        let fixture = ExecutorFixture("tombstone_group_cleanup")
        try {
            @Assert(MQProtocol.asPayload<MQTopicAssignment>(fixture.registerTopic("/t", 1)).isSome())
            @Assert(codeOf(fixture.registerGroup("/t", "g1")) == 0)
            @Assert(codeOf(fixture.registerGroup("/t", "g2")) == 0)
            let sid1 = "sid-tomb-g1"
            let sid2 = "sid-tomb-g2"
            @Assert(codeOf(fixture.call(
                MQProtocol.subscribe(MQSubscribePayload(sid1, "/t", "g1", [], "", false)))) == 0)
            @Assert(codeOf(fixture.call(
                MQProtocol.subscribe(MQSubscribePayload(sid2, "/t", "g2", [], "", true)))) == 0)
            fixture.publish("/t", "one".toData())
            let first = MQProtocol.asConsumeResult(
                fixture.call(MQProtocol.consume(MQConsumePayload(sid1)))).getOrThrow()
            @Assert(codeOf(fixture.call(MQProtocol.ack(
                MQAckPayload(sid1, first.queueIndex, first.segmentedIndex, first.segmentedOffset)))) == 0)

            let g1Cursor = "${fixture.root}/metas/offsets/%2Ft/0/g1.cursor"
            @Assert(exists(g1Cursor))
            @Assert(fixture.metrics.deliveredOf("/t", "g1") > 0)

            @Assert(codeOf(fixture.call(MQProtocol.metaSync(
                MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g1", 99, 1, 0)))) == 0)

            @Assert(!exists(g1Cursor))
            @Assert(fixture.subscribers.of(sid1).isNone())
            @Assert(fixture.metrics.deliveredOf("/t", "g1") == 0)
            // 主题与另一个组不受影响
            @Assert(exists("${fixture.root}/logs/%2Ft"))
            @Assert(fixture.meta.topicOf("/t").isSome())
            @Assert(fixture.meta.groupExists("/t", "g2"))
            @Assert(fixture.subscribers.of(sid2).isSome())
        } finally {
            fixture.close()
        }
    }

    /** 未知命令回 `ERROR(INTERNAL)`，不能静默丢弃（A67）。 */
    @TestCase
    public func unknownCommandReturnsInternalError(): Unit {
        let fixture = ExecutorFixture("unknown_cmd")
        try {
            let response = fixture.call(Message(Command.PING(0)))
            @Assert(response.command == Command.ERROR)
            @Assert(codeOf(response) == MQErrorCode.INTERNAL)
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
