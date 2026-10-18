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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_mq.base.{MQErrorCode, MQFilter, MQMessageRecord}
import fountain::f_mq.base.payload.{MQAckPayload, MQConsumeResult, MQResult}
import fountain::f_mq.base.payload.MQTopicAssignment
import fountain::f_net.SocketBuffer
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
    let service: ConsumeService
    private let topic = "/t"

    init(name: String) {
        this.root = "/tmp/fmq_test_consume/${name}"
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        this.queues = QueueManager("${root}/logs", 1024 * 1024, 1)
        this.store = CursorStore(root)
        this.deadLetter = DeadLetterQueue("${root}/dead", 1024 * 1024, 1)
        this.queues.openTopic(MQTopicAssignment(topic, 1, 0, [0]), 0)
        this.service = ConsumeService(queues, store, registry, MQMatcher(), deadLetter,
            Duration.second * 10, 3)
    }

    func append(tags: Array<String>, body: String) {
        let record = MQMessageRecord.encode(topic, tags, "mid-${body}", body.toData())
        queues.queueOf(topic, 0).getOrThrow().append(record)
    }

    func appendObject(enabled: Bool) {
        let record = MQMessageRecord.encode(topic, [], "mid-obj", ConsumeBody(enabled).toData())
        queues.queueOf(topic, 0).getOrThrow().append(record)
    }

    func register(id: String, group!: String = "g", tags!: Array<String> = [], filter!: String = '',
        autoAck!: Bool = false): MQSubscriptionInfo {
        let info = MQSubscriptionInfo(id, topic, group, tags, MQFilter.compile(filter), autoAck,
            None<SocketBuffer>)
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
            @Assert(fixture.service.ack(info, MQAckPayload("s1", result.segmentedIndex,
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
            let payload = MQAckPayload("s2", result.segmentedIndex, result.segmentedOffset)
            @Assert(fixture.service.ack(s2, payload).code == MQErrorCode.ACK_UNKNOWN)
            @Assert(fixture.service.ack(s1, MQAckPayload("s1", result.segmentedIndex,
                result.segmentedOffset)).code == 0)
            // 已越过
            @Assert(fixture.service.ack(s1, MQAckPayload("s1", result.segmentedIndex,
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
            let ack = fixture.service.ack(info, MQAckPayload("s1", first.segmentedIndex,
                first.segmentedOffset))
            @Assert(ack.code == MQErrorCode.ACK_UNKNOWN)
            let second = fixture.service.consume(info).getOrThrow()
            @Assert(second.segmentedIndex != first.segmentedIndex ||
                second.segmentedOffset != first.segmentedOffset)
        } finally {
            fixture.close()
        }
    }
}
