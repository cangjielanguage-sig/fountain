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

import std.collection.ArrayList
import std.fs.*
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.{MQErrorCode, MQFilter, MQMessageRecord}
import fountain::f_mq.base.payload.{MQAckPayload, MQConsumeResult, MQResult}
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::f_mq.exception.MQServiceException
import fountain::fmq.cluster.LogCleaner
import fountain::fmq.meta.{MQFileNames, MetaApplyResult, MetaStore}
import fountain::f_mq.base.model.MQSubscribeGroupMeta
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.queue.*
import fountain::fmq.test.TestDirs

@DataAssist[props fields]
public class ConsumeBody {
    private var enabled: Bool = false

    public init() {}

    public init(enabled: Bool) {
        this.enabled = enabled
    }
}

class ConsumeFixture <: Resource {
    let root: String
    let queues: QueueManager
    let store: CursorStore
    let meta: MetaStore
    let catalog: CursorCatalog
    let deadLetter: DeadLetterQueue
    let registry = SubscriberRegistry()
    let metrics = MQMetrics()
    let service: ConsumeService
    private let topic = "/t"

    init(name: String, queueCount!: Int64 = 1, maxFileSize!: Int64 = 1024 * 1024) {
        this.root = TestDirs.of("consume", name)
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.queues = QueueManager("${root}/logs", maxFileSize, 1)
        this.store = CursorStore(root)
        this.meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        meta.applyGroup(MQSubscribeGroupMeta("/t", "g"))
        this.catalog = CursorCatalog(store, meta)
        this.deadLetter = DeadLetterQueue("${root}/dead", maxFileSize, 1)
        let owners = Array<Int64>(queueCount) {_ => 0}
        this.queues.openTopic(MQTopicAssignment(topic, queueCount, 0, owners), 0)
        this.service = ConsumeService(queues, catalog, registry, MQMatcher(), deadLetter,
            Duration.second * 10, 3, metrics: metrics)
    }

    func append(tags: Array<String>, body: String): LogPosition {
        appendTo(0, tags, body)
    }

    func appendTo(queueIndex: Int64, tags: Array<String>, body: String): LogPosition {
        let record = MQMessageRecord.encode(topic, tags, "mid-${body}", body.toData())
        queues.queueOf(topic, queueIndex).getOrThrow().append(record)
    }

    func appendAt(queueIndex: Int64, tags: Array<String>, body: String, at: DateTime): LogPosition {
        let id = "1_2_3_${at.format("yyyyMMddHHmmssSSS")}"
        let record = MQMessageRecord.encode(topic, tags, id, body.toData())
        queues.queueOf(topic, queueIndex).getOrThrow().append(record)
    }

    func appendObject(enabled: Bool) {
        let record = MQMessageRecord.encode(topic, [], "mid-obj", ConsumeBody(enabled).toData())
        queues.queueOf(topic, 0).getOrThrow().append(record)
    }

    func register(id: String, group!: String = "g", tags!: Array<String> = [], filter!: String = '',
        autoAck!: Bool = false, alive!: ?() -> Bool = None): MQSubscriptionInfo {
        let info = MQSubscriptionInfo(id, topic, group, tags, MQFilter.compile(filter), autoAck,
            EMPTY_SOCKET_BUFFER, alive: alive)
        registry.register(info)
        info
    }

    public func isClosed(): Bool {
        false
    }

    public func close(): Unit {
        service.close()
        queues.close()
        deadLetter.close()
        if (exists(root)) {
            remove(root, recursive: true)
        }
    }
}

@Test
class ConsumeServiceTest {
    private static func bodyOf(result: MQConsumeResult): String {
        let content = MQMessageRecord.decode(result.record.copyBytes()).getOrThrow()
        convert<String>(content.body.data).getOrThrow()
    }

    /**
     * 备份状态以「全部组的最小 committed」为准，且 committed 必须严格越过该位置（R2-G8）。
     */
    @TestCase
    public func backupStatesUseSmallestCommittedStrictlyGreater(): Unit {
        let fixture = ConsumeFixture("backup_states")
        try {
            let p0 = fixture.append([], "a")
            let p1 = fixture.append([], "b")
            let p2 = fixture.append([], "c")
            let p3 = fixture.append([], "d")
            @Assert(fixture.meta.applyGroup(MQSubscribeGroupMeta("/t", "slow")) == MetaApplyResult.Applied)
            // 快组越过 p3；慢组刚好停在 p2 之后
            fixture.store.save("/t", 0, "g", LogPosition(p3.seq, p3.offset + 1))
            fixture.store.save("/t", 0, "slow", LogPosition(p2.seq, p2.offset + 1))
            let states = fixture.service.backupStates("/t", 0, [p0, p1, p2, p3])
            @Assert(states.size == 4)
            @Assert(states[0].acked)
            @Assert(states[1].acked)
            @Assert(states[2].acked)
            // p3 还没被慢组越过
            @Assert(!states[3].acked)
        } finally {
            fixture.close()
        }
    }

    /** 组位点恰好等于记录位置时不算确认；主题没有组时全部未确认（R2-G8）。 */
    @TestCase
    public func backupStatesBoundaryAndNoGroupAreUnacked(): Unit {
        let fixture = ConsumeFixture("backup_boundary")
        try {
            let position = fixture.append([], "a")
            fixture.store.save("/t", 0, "g", LogPosition(position.seq, position.offset))
            let states = fixture.service.backupStates("/t", 0, [position])
            @Assert(!states[0].acked)

            // 无组主题
            fixture.meta.applyTopic(MQTopicAssignment("/u", 1, 0, [0]))
            fixture.queues.openTopic(MQTopicAssignment("/u", 1, 0, [0]), 0)
            let record = MQMessageRecord.encode("/u", [], "mid-u", "x".toData())
            let orphan = fixture.queues.queueOf("/u", 0).getOrThrow().append(record)
            let orphanStates = fixture.service.backupStates("/u", 0, [orphan])
            @Assert(orphanStates.size == 1)
            @Assert(!orphanStates[0].acked)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func consumeReturnsMatchingMessage(): Unit {
        let fixture = ConsumeFixture("match")
        try {
            fixture.append([], "hello")
            let info = fixture.register("s1")
            let result = fixture.service.consume(info).getOrThrow()
            @Assert(bodyOf(result) == "hello")
            @Assert(result.segmentedIndex >= 1)
            @Assert(fixture.service.ack(info, MQAckPayload("s1", result.queueIndex, result.segmentedIndex,
                result.segmentedOffset)).code == 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func emptyQueueReturnsNone(): Unit {
        let fixture = ConsumeFixture("empty")
        try {
            let info = fixture.register("s1")
            @Assert(fixture.service.consume(info).isNone())
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func sameGroupDoesNotDuplicate(): Unit {
        let fixture = ConsumeFixture("same_group")
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            let s1 = fixture.register("s1")
            let s2 = fixture.register("s2")
            let r1 = fixture.service.consume(s1).getOrThrow()
            let r2 = fixture.service.consume(s2).getOrThrow()
            @Assert(!(r1.segmentedIndex == r2.segmentedIndex && r1.segmentedOffset == r2.segmentedOffset))
            @Assert(bodyOf(r1) != bodyOf(r2))
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func ackChecksSubscriptionOwnership(): Unit {
        let fixture = ConsumeFixture("ack_owner")
        try {
            fixture.append([], "one")
            let s1 = fixture.register("s1")
            let s2 = fixture.register("s2")
            let result = fixture.service.consume(s1).getOrThrow()
            let payload = MQAckPayload("s2", result.queueIndex, result.segmentedIndex, result.segmentedOffset)
            @Assert(fixture.service.ack(s2, payload).code == MQErrorCode.ACK_UNKNOWN)
            @Assert(fixture.service.ack(s1, MQAckPayload("s1", result.queueIndex, result.segmentedIndex,
                result.segmentedOffset)).code == 0)
            // 已越过
            @Assert(fixture.service.ack(s1, MQAckPayload("s1", result.queueIndex, result.segmentedIndex,
                result.segmentedOffset)).code == MQErrorCode.ACK_UNKNOWN)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func filterRestrictsDelivery(): Unit {
        let fixture = ConsumeFixture("filter")
        try {
            fixture.appendObject(true)
            fixture.appendObject(false)
            let info = fixture.register("s1", filter: "$.enabled")
            let result = fixture.service.consume(info).getOrThrow()
            let content = MQMessageRecord.decode(result.record.copyBytes()).getOrThrow()
            @Assert(convert<ConsumeBody>(content.body.data).getOrThrow().enabled)
            // 第二条被过滤器挡住
            @Assert(fixture.service.consume(info).isNone())
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func releaseReturnsDeliveryToGroup(): Unit {
        let fixture = ConsumeFixture("release")
        try {
            fixture.append([], "one")
            let s1 = fixture.register("s1")
            let s2 = fixture.register("s2")
            let first = fixture.service.consume(s1).getOrThrow()
            fixture.service.releaseSubscription(s1)
            let second = fixture.service.consume(s2).getOrThrow()
            @Assert(second.segmentedIndex == first.segmentedIndex)
            @Assert(second.segmentedOffset == first.segmentedOffset)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func unregisterStopsDeliveryForSubscription(): Unit {
        let fixture = ConsumeFixture("unregister")
        try {
            fixture.append([], "one")
            let info = fixture.register("s1")
            fixture.registry.unregister("s1")
            let result = fixture.service.consume(info)
            // 订阅已不在组内 ⇒ 组内无人在线，返回 None
            @Assert(result.isNone())
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func autoAckSubscriptionNeedsNoAck(): Unit {
        let fixture = ConsumeFixture("auto_ack")
        try {
            fixture.append([], "one")
            fixture.append([], "two")
            let info = fixture.register("s1", autoAck: true)
            let first = fixture.service.consume(info).getOrThrow()
            // 已被服务端自动确认
            let ack = fixture.service.ack(info, MQAckPayload("s1", first.queueIndex, first.segmentedIndex,
                first.segmentedOffset))
            @Assert(ack.code == MQErrorCode.ACK_UNKNOWN)
            let second = fixture.service.consume(info).getOrThrow()
            @Assert(second.segmentedIndex != first.segmentedIndex ||
                second.segmentedOffset != first.segmentedOffset)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func ackTargetsExactQueueAndRejectsUnknownQueue(): Unit {
        let fixture = ConsumeFixture("queue_route", queueCount: 2)
        try {
            // 两个独立队列的首条记录位置相同 (1, 0)
            let p0 = fixture.appendTo(0, [], "zero")
            let p1 = fixture.appendTo(1, [], "one")
            @Assert(p0.seq == p1.seq && p0.offset == p1.offset)
            let info = fixture.register("s1")
            let r0 = fixture.service.consume(info).getOrThrow()
            let r1 = fixture.service.consume(info).getOrThrow()
            @Assert(r0.queueIndex == 0)
            @Assert(r1.queueIndex == 1)
            @Assert(r0.segmentedIndex == r1.segmentedIndex)
            @Assert(r0.segmentedOffset == r1.segmentedOffset)

            // 不存在的队列身份 → ACK_UNKNOWN，两个游标都不变
            @Assert(fixture.service.ack(info, MQAckPayload("s1", 9, r0.segmentedIndex,
                r0.segmentedOffset)).code == MQErrorCode.ACK_UNKNOWN)
            @Assert(fixture.service.cursorOf("/t", 0, "g").pendingCount == 1)
            @Assert(fixture.service.cursorOf("/t", 1, "g").pendingCount == 1)

            // 只确认队列 1：队列 0 的同位置记录必须保持未决
            @Assert(fixture.service.ack(info, MQAckPayload("s1", 1, r1.segmentedIndex,
                r1.segmentedOffset)).code == 0)
            @Assert(fixture.service.cursorOf("/t", 0, "g").pendingCount == 1)
            @Assert(fixture.service.cursorOf("/t", 1, "g").pendingCount == 0)

            @Assert(fixture.service.ack(info, MQAckPayload("s1", 0, r0.segmentedIndex,
                r0.segmentedOffset)).code == 0)
            @Assert(fixture.service.cursorOf("/t", 0, "g").pendingCount == 0)
        } finally {
            fixture.close()
        }
    }
    /** committed 段缺失且未修复 → `stats` 报 INTERNAL；修复后正常，尾部三列是跳过计数（R3-M4/M8）。 */
    @TestCase
    public func statsRejectsMissingCommittedSegmentUntilRepaired(): Unit {
        let fixture = ConsumeFixture("stats_missing_segment", maxFileSize: 50)
        try {
            fixture.append([], "a")
            fixture.append([], "b")
            fixture.append([], "c")
            // 人为删掉 committed 所在的段，且不修复位点
            fixture.queues.queueOf("/t", 0).getOrThrow().removeById(1)
            fixture.catalog.save("/t", 0, "g", LogPosition(1, 0))
            var code = -1i64
            try {
                fixture.service.stats("/t", 0, {_ => ["g"]})
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)

            // 消费路径把位点前移后，统计恢复正常
            fixture.catalog.save("/t", 0, "g", LogPosition(2, 0))
            let text = fixture.service.stats("/t", 0, {_ => ["g"]})
            @Assert(text.contains("skippedUnreadable"))
            let row = statsRow(text, "/t", "g")
            @Assert(row.size == 14)
            @Assert(row[11] == "0")
            @Assert(row[12] == "0")
            @Assert(row[13] == "0")
        } finally {
            fixture.close()
        }
    }

    /** 记录总数：从现存编号最小的现存段扫一遍（替代生产侧已删除的 `countAll`）。 */
    private static func countOf(log: QueueLog): Int64 {
        let segs = log.segmentsOrEmpty()
        if (segs.size == 0) {
            return 0
        }
        log.scanAfter(LogPosition(segs[0].index, 0))[0]
    }

    private static func statsRow(text: String, topic: String, group: String): Array<String> {
        for (line in text.split("\n")) {
            let fields = line.split("\t")
            if (fields.size >= 10 && fields[0] == "R" && fields[1] == topic && fields[2] == group) {
                return fields
            }
        }
        Array<String>()
    }

    /** 不可评估 BODY：报一次错并越过，组不再停摆（A46/A57）。 */
    @TestCase
    public func unsupportedBodyIsReportedOnceAndSkipped(): Unit {
        let fixture = ConsumeFixture("unsupported")
        try {
            // BODY 段被截断：topic/tags 可解，BODY 解不出 ⇒ filter 无法评估
            let full = MQMessageRecord.encode("/t", [], "1_2_3_${DateTime.nowUTC().format("yyyyMMddHHmmssSSS")}",
                "one".toData())
            fixture.queues.queueOf("/t", 0).getOrThrow().append(full[0..full.size - 2])
            let filtered = fixture.register("s1", filter: "$.enabled")
            var code = -1i64
            try {
                fixture.service.consume(filtered)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.FILTER_UNSUPPORTED_BODY)
            // 同一位置不重复报错（已越过）
            @Assert(fixture.service.consume(filtered).isNone())
            // 后续消息照常消费（组未停摆）
            fixture.append([], "two")
            let plain = fixture.register("s2", filter: "")
            @Assert(fixture.service.consume(plain).isSome())
        } finally {
            fixture.close()
        }
    }

    /** 组内无匹配记录时越过，不进入死信（A57）。 */
    @TestCase
    public func noMatchIsSkippedWithoutDeadLetter(): Unit {
        let fixture = ConsumeFixture("no_match_skip")
        try {
            fixture.append([], "one")
            let s1 = fixture.register("s1", tags: ["never"])
            @Assert(fixture.service.consume(s1).isNone())
            // 已越过：再消费不会重复看到它，也不产生死信
            @Assert(fixture.service.consume(s1).isNone())
            @Assert(fixture.metrics.deadLetteredOf("/t", "g") == 0)
        } finally {
            fixture.close()
        }
    }

    /** 断链订阅名下已分配的记录必须退回组内，其它匹配订阅下一轮可取到（A55）。 */
    @TestCase
    public func disconnectedSubscriptionDoesNotBlockGroup(): Unit {
        let fixture = ConsumeFixture("disconnected")
        try {
            fixture.append(["b"], "one")
            // s1 不匹配；s2 匹配但连接已断；s3 匹配且在线
            let s1 = fixture.register("s1", tags: ["a"])
            fixture.register("s2", tags: ["b"], alive: {=> false})
            let s3 = fixture.register("s3", tags: ["b"])
            // 首轮由 s1 扫描：记录被分配给 s2（delivered = false）
            @Assert(fixture.service.consume(s1).isNone())
            // s2 不在活跃集合里 ⇒ sweep 退回组内 ⇒ s3 取到
            @Assert(fixture.service.consume(s3).isSome())
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func statsReportsBacklogLagAndCounters(): Unit {
        let fixture = ConsumeFixture("stats")
        try {
            let base = DateTime.nowUTC() - Duration.second * 5
            fixture.appendAt(0, [], "one", base)
            fixture.appendAt(0, [], "two", base + Duration.second)
            fixture.appendAt(0, [], "three", base + Duration.second * 2)
            let info = fixture.register("s1")
            let first = fixture.service.consume(info).getOrThrow()
            @Assert(fixture.service.ack(info, MQAckPayload("s1", first.queueIndex, first.segmentedIndex,
                first.segmentedOffset)).code == 0)

            let text = fixture.service.stats("/t", 3, {_ => ["g"]})
            @Assert(text.startsWith("#\t3\t"))
            let row = statsRow(text, "/t", "g")
            @Assert(row.size >= 10)
            @Assert(Int64.parse(row[5]) == 2)      // backlog
            @Assert(Int64.parse(row[6]) >= 3000)   // lagMs
            @Assert(Int64.parse(row[7]) == 1)      // delivered
            @Assert(Int64.parse(row[8]) == 1)      // acked

            // 全部确认后 backlog 与 lag 归零
            for (_ in 0..2) {
                let rest = fixture.service.consume(info).getOrThrow()
                @Assert(fixture.service.ack(info, MQAckPayload("s1", rest.queueIndex, rest.segmentedIndex,
                    rest.segmentedOffset)).code == 0)
            }
            let emptyRow = statsRow(fixture.service.stats("/t", 3, {_ => ["g"]}), "/t", "g")
            @Assert(Int64.parse(emptyRow[5]) == 0)
            @Assert(Int64.parse(emptyRow[6]) == 0)
        } finally {
            fixture.close()
        }
    }

    /** autoAck 的投递也要计入 acked，且不产生 backlog（A61）。 */
    @TestCase
    public func autoAckCountsAckedAndClearsBacklog(): Unit {
        let fixture = ConsumeFixture("auto_ack")
        try {
            for (i in 0..3) {
                fixture.append([], "m-${i}")
            }
            let info = fixture.register("s1", autoAck: true)
            for (_ in 0..3) {
                @Assert(fixture.service.consume(info).isSome())
            }
            let row = statsRow(fixture.service.stats("/t", 0, {_ => ["g"]}), "/t", "g")
            @Assert(Int64.parse(row[5]) == 0)      // backlog
            @Assert(Int64.parse(row[8]) == 3)      // acked
        } finally {
            fixture.close()
        }
    }

    /** 删除主题/组后计数器清零，同名重建不复用旧值（A61）。 */
    @TestCase
    public func removingTopicAndGroupClearsCounters(): Unit {
        let fixture = ConsumeFixture("clear_counters")
        try {
            fixture.append([], "one")
            let info = fixture.register("s1", autoAck: true)
            fixture.service.consume(info)
            @Assert(fixture.metrics.ackedOf("/t", "g") == 1)
            fixture.service.removeGroup("/t", "g")
            @Assert(fixture.metrics.ackedOf("/t", "g") == 0)
            fixture.service.removeTopic("/t")
            @Assert(fixture.metrics.size == 0)
        } finally {
            fixture.close()
        }
    }

    /** 多队列 backlog 与逐队列求和一致（A62）。 */
    @TestCase
    public func backlogAggregatesAcrossQueues(): Unit {
        let fixture = ConsumeFixture("multi_queue", queueCount: 2)
        try {
            fixture.appendTo(0, [], "a")
            fixture.appendTo(1, [], "b")
            fixture.appendTo(1, [], "c")
            let row = statsRow(fixture.service.stats("/t", 0, {_ => ["g"]}), "/t", "g")
            @Assert(Int64.parse(row[5]) == 3)
        } finally {
            fixture.close()
        }
    }

    /** 单趟扫描：每个队列只开一次读流，与组数无关（A62/T23.6）。 */
    @TestCase
    public func statsScansEachQueueOnceRegardlessOfGroupCount(): Unit {
        let fixture = ConsumeFixture("stats_single_pass", queueCount: 3)
        try {
            for (queueIndex in 0..3) {
                fixture.appendTo(queueIndex, [], "m${queueIndex}")
            }
            let groups: Array<String> = ["g1", "g2", "g3", "g4"]
            let before = fixture.service.statsScans
            let text = fixture.service.stats("/t", 0, {_ => groups})
            // 3 个队列 × 4 个组：读流只开 3 次（每组各扫一遍就是 12 次）
            @Assert(fixture.service.statsScans - before == 3)
            for (group in groups) {
                @Assert(Int64.parse(statsRow(text, "/t", group)[5]) == 3)
            }
        } finally {
            fixture.close()
        }
    }

    /** 扫描失败时 stats 必须报错，不能伪造 backlog=0（A62）。 */
    @TestCase
    public func statsPropagatesScanFailure(): Unit {
        let fixture = ConsumeFixture("stats_corrupt")
        try {
            fixture.append([], "one")
            let dir = MQFileNames.queueDir("${fixture.root}/logs", "/t", 0)
            let corrupted = Array<Bool>(1, repeat: false)
            Directory.walk(dir) {info: FileInfo =>
                if (!corrupted[0] && !info.isDirectory() && info.name.startsWith("log_")) {
                    let file = File(info.path.toString(), OpenMode.Write)
                    file.write([0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8])
                    file.close()
                    corrupted[0] = true
                }
                true
            }
            @Assert(corrupted[0])
            var code = -1i64
            try {
                fixture.service.stats("/t", 0, {_ => ["g"]})
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)
        } finally {
            fixture.close()
        }
    }

    /** 段被清理/目录不可读时 stats 必须报错，不得输出 backlog=0（A61）。 */
    @TestCase
    public func statsFailsWhenSegmentsAreGone(): Unit {
        let fixture = ConsumeFixture("stats_no_segment")
        try {
            fixture.append([], "one")
            let dir = MQFileNames.queueDir("${fixture.root}/logs", "/t", 0)
            let victims = ArrayList<String>()
            Directory.walk(dir) {info: FileInfo =>
                if (!info.isDirectory() && info.name.startsWith("log_")) {
                    victims.add(info.path.toString())
                }
                true
            }
            @Assert(victims.size > 0)
            for (path in victims) {
                remove(path)
            }
            var code = -1i64
            try {
                fixture.service.stats("/t", 0, {_ => ["g"]})
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)
        } finally {
            fixture.close()
        }
    }

    /** 发布时间在未来（旧版本地时区按 UTC 解释）时，`lagMs` 不得为负（A02）。 */
    @TestCase
    public func statsClampsNegativeLag(): Unit {
        let fixture = ConsumeFixture("stats_future")
        try {
            fixture.appendAt(0, [], "future", DateTime.nowUTC() + Duration.hour * 8)
            let row = statsRow(fixture.service.stats("/t", 0, {_ => ["g"]}), "/t", "g")
            @Assert(Int64.parse(row[6]) == 0)
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func statsUnknownTopicReturnsEmpty(): Unit {
        let fixture = ConsumeFixture("stats_unknown")
        try {
            let text = fixture.service.stats("/missing", 0, {_ => []})
            @Assert(!text.contains("R\t"))
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func statsWithoutTopicListsAllLocalTopics(): Unit {
        let fixture = ConsumeFixture("stats_all")
        try {
            fixture.append([], "one")
            let text = fixture.service.stats("", 1, {_ => ["g"]})
            let row = statsRow(text, "/t", "g")
            @Assert(row.size >= 10)
            @Assert(Int64.parse(row[5]) == 1)
            // 首条 messageId 不含时间戳：lag 未知，固定为 0
            @Assert(Int64.parse(row[6]) == 0)
        } finally {
            fixture.close()
        }
    }
    @TestCase
    public func statsAllTopicsAndFiltering(): Unit {
        let fixture = ConsumeFixture("stats_two")
        try {
            fixture.append([], "one")
            fixture.queues.openTopic(MQTopicAssignment("/u", 1, 0, [0]), 0)
            let record = MQMessageRecord.encode("/u", [], "mid-u", "u".toData())
            fixture.queues.queueOf("/u", 0).getOrThrow().append(record)

            let all = fixture.service.stats("", 0, {topic => if (topic == "/t") {["g"]} else {["h"]}})
            @Assert(all.contains("R\t/t\tg\t"))
            @Assert(all.contains("R\t/u\th\t"))

            let only = fixture.service.stats("/t", 0, {_ => ["g"]})
            @Assert(only.contains("R\t/t\tg\t"))
            @Assert(!only.contains("R\t/u\t"))

            // 本节点不持有队列的主题：全量与按主题都不出现
            fixture.queues.openTopic(MQTopicAssignment("/remote", 1, 0, [1]), 0)
            let reopenedAll = fixture.service.stats("", 0, {_ => ["g"]})
            @Assert(!reopenedAll.contains("/remote"))
            let remoteOnly = fixture.service.stats("/remote", 0, {_ => ["g"]})
            @Assert(!remoteOnly.contains("R\t"))
        } finally {
            fixture.close()
        }
    }

    @TestCase
    public func statsDoesNotCreateCursorOrChangeLog(): Unit {
        let fixture = ConsumeFixture("stats_pure")
        try {
            fixture.append([], "one")
            @Assert(fixture.store.load("/t", 0, "g").isNone())
            let before = countOf(fixture.queues.queueOf("/t", 0).getOrThrow())
            let text = fixture.service.stats("/t", 0, {_ => ["g"]})
            @Assert(text.contains("R\t/t\tg\t"))
            @Assert(fixture.store.load("/t", 0, "g").isNone())
            @Assert(countOf(fixture.queues.queueOf("/t", 0).getOrThrow()) == before)
        } finally {
            fixture.close()
        }
    }
    @TestCase
    public func statsEmitsEmptyGroupRow(): Unit {
        let fixture = ConsumeFixture("stats_no_group")
        try {
            fixture.append([], "one")
            let text = fixture.service.stats("/t", 0, {_ => []})
            @Assert(text.contains("R\t/t\t\t"))
        } finally {
            fixture.close()
        }
    }

    /** 段清理边界取自「真实 ConsumeService + CursorCatalog」而不是替身回调。 */
    @TestCase
    public func consumedGroupRaisesCleanerFloor(): Unit {
        let root = TestDirs.of("consume", "cleaner_floor")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let queues = QueueManager("${root}/logs", 32, 1)
        queues.openTopic(MQTopicAssignment("/t", 1, 0, [0]), 0)
        let meta = MetaStore("${root}/metas")
        meta.load()
        meta.applyTopic(MQTopicAssignment("/t", 1, 0, [0]))
        let store = CursorStore("${root}/metas")
        let dead = DeadLetterQueue("${root}/dead", 32, 1)
        let registry = SubscriberRegistry()
        try {
            @Assert(meta.applyGroup(MQSubscribeGroupMeta("/t", "g")) == MetaApplyResult.Applied)
            let catalog = CursorCatalog(store, meta)
            let service = ConsumeService(queues, catalog, registry, MQMatcher(), dead,
                Duration.second * 10, 3)
            let log = queues.queueOf("/t", 0).getOrThrow()
            for (i in 0..5) {
                log.append(MQMessageRecord.encode("/t", [], "mid-${i}", i.toData()))
            }
            let before = log.segments().size
            @Assert(before >= 3)
            let info = MQSubscriptionInfo("s1", "/t", "g", [], MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER)
            registry.register(info)
            while (let Some(result) <- service.consume(info)) {
                @Assert(service.ack(info, MQAckPayload("s1", result.queueIndex, result.segmentedIndex,
                    result.segmentedOffset)).code == 0)
            }
            // 未清理前段都还在
            @Assert(log.segments().size == before)
            let cleaner = LogCleaner(queues, dead, {topic, queueIndex => service.floorOf(topic, queueIndex)},
                Duration.second * -1, Duration.hour * 72)
            try {
                @Assert(cleaner.cleanOnce(DateTime.now()) >= 1)
            } finally {
                cleaner.close()
            }
            @Assert(log.segments().size < before)
            service.close()
        } finally {
            meta.close()
            queues.close()
            dead.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }

    /** 不同订阅组各自维护游标：同一条记录两组都能取到（A56）。 */
    @TestCase
    public func differentGroupsConsumeIndependently(): Unit {
        let fixture = ConsumeFixture("cross_group")
        try {
            fixture.append([], "shared")
            fixture.meta.applyGroup(MQSubscribeGroupMeta("/t", "g2"))
            let first = fixture.register("s1")
            let second = fixture.register("s2", group: "g2")
            let one = fixture.service.consume(first).getOrThrow()
            let two = fixture.service.consume(second).getOrThrow()
            @Assert(one.segmentedIndex == two.segmentedIndex)
            @Assert(one.segmentedOffset == two.segmentedOffset)
            @Assert(bodyOf(one) == "shared")
            @Assert(bodyOf(two) == "shared")
            // 一组确认不影响另一组的未决状态
            @Assert(fixture.service.ack(first,
                MQAckPayload("s1", one.queueIndex, one.segmentedIndex, one.segmentedOffset)).code == 0)
            @Assert(fixture.service.consume(second).isNone())
        } finally {
            fixture.close()
        }
    }

    /** 组内无人在线时不推进：没有活跃订阅时游标不会越过未投递记录（A57）。 */
    @TestCase
    public func groupWithoutOnlineSubscriberKeepsPosition(): Unit {
        let fixture = ConsumeFixture("offline_group")
        try {
            fixture.append([], "pending")
            let info = fixture.register("s1")
            let message = fixture.service.consume(info).getOrThrow()
            // 释放并注销：记录回到组内，游标不得越过
            fixture.service.releaseSubscription(info)
            fixture.registry.unregister("s1")
            @Assert(fixture.catalog.floorOf("/t", 0) == 1)
            // 重新订阅后仍能取到同一条
            let again = fixture.register("s2")
            let redelivered = fixture.service.consume(again).getOrThrow()
            @Assert(redelivered.segmentedIndex == message.segmentedIndex)
            @Assert(redelivered.segmentedOffset == message.segmentedOffset)
        } finally {
            fixture.close()
        }
    }
}
