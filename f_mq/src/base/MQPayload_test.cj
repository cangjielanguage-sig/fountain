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
package fountain::f_mq.base

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime
import fountain::f_data.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*


@Test
class MQPayloadTest {
    private static func roundtrip<T>(value: T): ?T where T <: DataFields<T> {
        let codec = DefaultCodec()
        var bytes: Array<Byte> = []
        try {
            codec.encode(value.toData())
            bytes = codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
        let decoder = DefaultCodec()
        var result: ?T = None<T>
        try {
            result = decoder.decode<T>(ByteBuffer(bytes))
        } finally {
            decoder.release()
        }
        result
    }

    @TestCase
    public func resultRoundtrip(): Unit {
        let back = roundtrip<MQResult>(MQResult(7, "nope")).getOrThrow()
        @Assert(back.code == 7)
        @Assert(back.message == "nope")
        @Assert(!back.isOk())
        @Assert(MQResult(0, "ok").isOk())
    }

    @TestCase
    public func topicAssignmentOwnerBounds(): Unit {
        let assignment = MQTopicAssignment("/t", 4, 0, [0, 1, 2, 0])
        // 规格用例
        @Assert(assignment.owner(0) == Some(0))
        @Assert(assignment.owner(3) == Some(0))
        @Assert(assignment.owner(4).isNone())
        @Assert(assignment.owner(-1).isNone())

        let back = roundtrip<MQTopicAssignment>(assignment).getOrThrow()
        @Assert(back.topic == "/t")
        @Assert(back.queueNum == 4)
        @Assert(back.startNodeIndex == 0)
        @Assert(back.owners == [0, 1, 2, 0])
    }

    @TestCase
    public func subscribePayloadRoundtrip(): Unit {
        let value = MQSubscribePayload("sid", "/t", "g1", ["a", "b"], "$.enabled", true)
        let back = roundtrip<MQSubscribePayload>(value).getOrThrow()
        @Assert(back.subscribedId == "sid")
        @Assert(back.topic == "/t")
        @Assert(back.subscribeGroup == "g1")
        @Assert(back.tags == ["a", "b"])
        @Assert(back.filter == "$.enabled")
        @Assert(back.autoAck)
    }

    @TestCase
    public func simplePayloadsRoundtrip(): Unit {
        @Assert(roundtrip<MQUnsubscribePayload>(MQUnsubscribePayload("sid")).getOrThrow().subscribedId == "sid")
        @Assert(roundtrip<MQConsumePayload>(MQConsumePayload("sid")).getOrThrow().subscribedId == "sid")
        let ack = roundtrip<MQAckPayload>(MQAckPayload("sid", 3, 7, 128)).getOrThrow()
        @Assert(ack.subscribedId == "sid" && ack.queueIndex == 3)
        @Assert(ack.segmentedIndex == 7 && ack.segmentedOffset == 128)
        let dereg = roundtrip<MQDeregisterPayload>(MQDeregisterPayload("group", "/t", subscribeGroup: "g")).getOrThrow()
        @Assert(!dereg.isTopic())
        @Assert(dereg.subscribeGroup == "g")
        let req = roundtrip<MQMetaSyncRequest>(MQMetaSyncRequest(2)).getOrThrow()
        @Assert(req.requesterIndex == 2)
    }

    @TestCase
    public func emptyRecordStaysEmpty(): Unit {
        let value = MQConsumeResult(2, 7, 128, [])
        @Assert(!value.hasMessage())
        let back = roundtrip<MQConsumeResult>(value).getOrThrow()
        @Assert(back.queueIndex == 2)
        @Assert(back.segmentedIndex == 7)
        @Assert(back.segmentedOffset == 128)
        @Assert(back.record.size() == 0)
        @Assert(!back.hasMessage())

        let withRecord = roundtrip<MQConsumeResult>(MQConsumeResult(5, 1, 2, [1u8, 2u8, 3u8])).getOrThrow()
        @Assert(withRecord.hasMessage())
        @Assert(withRecord.queueIndex == 5)
        @Assert(withRecord.record.copyBytes() == [1u8, 2u8, 3u8])
    }

    @TestCase
    public func internalMessageRoundtrip(): Unit {
        let value = MQInternalMessage(MQInternalKind.BACKUP, [9u8, 8u8])
        let back = roundtrip<MQInternalMessage>(value).getOrThrow()
        @Assert(back.kind == "backup")
        @Assert(back.payload.copyBytes() == [9u8, 8u8])
    }

    @TestCase
    public func metaSnapshotNestedRoundtrip(): Unit {
        let topics = [
            MQTopicAssignment("/a", 2, 0, [0, 1]),
            MQTopicAssignment("/b", 1, 1, [1])
        ]
        let groups = [MQSubscribeGroupMeta("/a", "g1")]
        let value = MQMetaSnapshot(topics, groups, 2)
        let back = roundtrip<MQMetaSnapshot>(value).getOrThrow()
        @Assert(back.topics.size == 2)
        @Assert(back.topics[0].topic == "/a")
        @Assert(back.topics[1].owners == [1])
        @Assert(back.groups.size == 1)
        @Assert(back.groups[0].subscribeGroup == "g1")
        @Assert(back.nextStartNode == 2)
    }

    @TestCase
    public func backupPayloadRoundtrip(): Unit {
        let value = MQBackupPayload(0, "/t", 2, [[1u8], [2u8, 3u8], []], [
            MQBackupState(1, 0, 0, false),
            MQBackupState(1, 8, 2, true),
            MQBackupState(2, 0, 1, false)
        ])
        let back = roundtrip<MQBackupPayload>(value).getOrThrow()
        @Assert(back.ownerIndex == 0)
        @Assert(back.topic == "/t")
        @Assert(back.queueIndex == 2)
        @Assert(back.records.size == 3)
        @Assert(back.records[0].copyBytes() == [1u8])
        @Assert(back.records[1].copyBytes() == [2u8, 3u8])
        @Assert(back.records[2].size() == 0)
        @Assert(back.states.size == 3)
        @Assert(back.states[1].acked)
        @Assert(back.states[1].deliverCount == 2)
    }

    @TestCase
    public func deadLetterRoundtrip(): Unit {
        let time = DateTime.now()
        let value = MQDeadLetterMessage("/t", 1, "g", 7, 128, 4, time, [1u8, 2u8])
        let back = roundtrip<MQDeadLetterMessage>(value).getOrThrow()
        @Assert(back.topic == "/t")
        @Assert(back.queueIndex == 1)
        @Assert(back.subscribeGroup == "g")
        @Assert(back.segmentedIndex == 7)
        @Assert(back.segmentedOffset == 128)
        @Assert(back.deliverCount == 4)
        @Assert(back.deadTime == time)
        @Assert(back.record.copyBytes() == [1u8, 2u8])
    }


    @TestCase
    public func topicMetaAndAssignmentCarryDelaying(): Unit {
        let meta = roundtrip<MQTopicMeta>(MQTopicMeta("/t", 2, delayingMs: 61000)).getOrThrow()
        @Assert(meta.delayingMs == 61000)
        let assignment = roundtrip<MQTopicAssignment>(MQTopicAssignment("/t", 2, 0, [0, 1],
            delayingMs: 61000)).getOrThrow()
        @Assert(assignment.delayingMs == 61000)
        @Assert(assignment.owners == [0, 1])
    }
}