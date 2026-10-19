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
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.queue.*

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
    let deadLetter: DeadLetterQueue
    let registry = SubscriberRegistry()
    let metrics = MQMetrics()
    let service: ConsumeService
    private let topic = "/t"

    init(name: String, queueCount!: Int64 = 1) {
        this.root = "/tmp/fmq_test_consume/${name}"
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.queues = QueueManager("${root}/logs", 1024 * 1024, 1)
        this.store = CursorStore(root)
        this.deadLetter = DeadLetterQueue("${root}/dead", 1024 * 1024, 1)
        let owners = Array<Int64>(queueCount) {_ => 0}
        this.queues.openTopic(MQTopicAssignment(topic, queueCount, 0, owners), 0)
        this.service = ConsumeService(queues, store, registry, MQMatcher(), deadLetter,
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
        autoAck!: Bool = false): MQSubscriptionInfo {
        let info = MQSubscriptionInfo(id, topic, group, tags, MQFilter.compile(filter), autoAck,
            EMPTY_SOCKET_BUFFER)
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
        let content = MQMessageRecord.decode(result.record).getOrThrow()
        convert<String>(content.body.data).getOrThrow()
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
            let content = MQMessageRecord.decode(result.record).getOrThrow()
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
    private static func statsRow(text: String, topic: String, group: String): Array<String> {
        for (line in text.split("\n")) {
            let fields = line.split("\t")
            if (fields.size >= 10 && fields[0] == "R" && fields[1] == topic && fields[2] == group) {
                return fields
            }
        }
        Array<String>()
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
            let before = fixture.queues.queueOf("/t", 0).getOrThrow().countAll()
            let text = fixture.service.stats("/t", 0, {_ => ["g"]})
            @Assert(text.contains("R\t/t\tg\t"))
            @Assert(fixture.store.load("/t", 0, "g").isNone())
            @Assert(fixture.queues.queueOf("/t", 0).getOrThrow().countAll() == before)
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
}