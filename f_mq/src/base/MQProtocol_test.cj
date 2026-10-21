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
import fountain::f_data.*
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_protocol.default.*

@Test
class MQProtocolTest {
    private static func roundtripFrame(message: Message): Message {
        let encoded = message.encode()
        // 预留足够容量，避免 ByteBuffer 的扩容上限
        let buffer = ByteBuffer(initialCapacity: 64 * 1024)
        encoded.copy(to: buffer)
        Message.decode<DataAny>(buffer)
    }

    private static func commandIs(message: Message, expected: Command): Bool {
        message.command == expected
    }

    @TestCase
    public func factoriesUseExpectedCommands(): Unit {
        let record = MQMessageRecord.encode("/t", [], "m", 1i64.toData())
        @Assert(commandIs(MQProtocol.publish(record), PUBLISH(0)))
        @Assert(commandIs(MQProtocol.subscribe(MQSubscribePayload("s", "/t", "", [], "", false)), SUBSCRIBE))
        @Assert(commandIs(MQProtocol.unsubscribe(MQUnsubscribePayload("s")), UNSUBSCRIBE))
        match (MQProtocol.consume(MQConsumePayload("s")).command) {
            case CONSUME(_) => @Assert(true)
            case _ => @Assert(false)
        }
        @Assert(commandIs(MQProtocol.ack(MQAckPayload("s", 0, 1, 2)), Command.ACK))
        @Assert(commandIs(MQProtocol.registerTopic(MQTopicMeta("/t", 1)), REGISTER))
        @Assert(commandIs(MQProtocol.registerGroup(MQSubscribeGroupMeta("/t", "g")), REGISTER))
        @Assert(commandIs(MQProtocol.deregister(MQDeregisterPayload("topic", "/t")), DEREGISTER))
        @Assert(commandIs(MQProtocol.metaSync(MQMetaSyncRequest(0)), REGISTER))

        let backup = MQBackupPayload(0, "/t", 0, [[1u8]], [MQBackupState(1, 0, 0, false)])
        @Assert(commandIs(MQProtocol.publishBackup(backup), PUBLISH(0)))
    }

    @TestCase
    public func recordTravelsByteForByte(): Unit {
        let record = MQMessageRecord.encode("/order", ["a", "b"], "mid", "body".toData())
        let message = MQProtocol.publish(record)
        @Assert(MQProtocol.kindOf(message) == MQPayloadKind.Record)
        @Assert(MQProtocol.asRecord(message) == Some(record))

        let decoded = roundtripFrame(message)
        let restored = MQProtocol.asRecord(decoded).getOrThrow()
        @Assert(restored == record)
    }

    @TestCase
    public func largeRecordSurvivesFrameRoundtrip(): Unit {
        let big = Array<Byte>(16 * 1024, repeat: 0x5Au8)
        let record = MQMessageRecord.encode("/big", [], "m", big.toData())
        @Assert(record.size > 16 * 1024)
        let decoded = roundtripFrame(MQProtocol.publish(record))
        @Assert(MQProtocol.asRecord(decoded) == Some(record))
    }

    @TestCase
    public func payloadKindsAreClassified(): Unit {
        @Assert(MQProtocol.kindOf(MQProtocol.registerTopic(MQTopicMeta("/t", 1))) == MQPayloadKind.TopicMeta)
        @Assert(MQProtocol.kindOf(MQProtocol.registerGroup(MQSubscribeGroupMeta("/t", "g"))) ==
            MQPayloadKind.GroupMeta)
        @Assert(MQProtocol.kindOf(MQProtocol.metaSync(MQMetaSyncRequest(0))) == MQPayloadKind.Internal)
        @Assert(MQProtocol.kindOf(Message(Command.RESP(0))) == MQPayloadKind.Empty)
        @Assert(MQProtocol.kindOf(Message(Command.RESP(0), MQResult(0, "ok").toData())) == MQPayloadKind.Unknown)
    }

    @TestCase
    public func typeMismatchReturnsNone(): Unit {
        let record = MQMessageRecord.encode("/t", [], "m", 1i64.toData())
        let message = MQProtocol.publish(record)
        @Assert(MQProtocol.asPayload<MQSubscribePayload>(message).isNone())
        @Assert(MQProtocol.asConsumeResult(message).isNone())
    }

    @TestCase
    public func responsesEchoRequestId(): Unit {
        let request = MQProtocol.subscribe(MQSubscribePayload("s", "/t", "", [], "", false))
        let response = MQProtocol.respond<MQResult>(request, MQResult(0, "ok"))
        @Assert(response.id == request.id)
        match (response.command) {
            case RESP(_) => @Assert(true)
            case _ => @Assert(false)
        }
        @Assert(MQProtocol.asResult(response).code == 0)

        let empty = MQProtocol.respondEmpty(request)
        @Assert(empty.id == request.id)
        @Assert(MQProtocol.asResult(empty).code == 0)
    }

    @TestCase
    public func failUsesErrorCommandAndPayload(): Unit {
        let request = MQProtocol.consume(MQConsumePayload("s"))
        let error = MQProtocol.fail(request, MQErrorCode.TOPIC_NOT_EXIST, "nope")
        @Assert(error.id == request.id)
        @Assert(error.command == Command.ERROR)
        let result = MQProtocol.asPayload<MQResult>(error).getOrThrow()
        @Assert(result.code == 1)
        @Assert(result.message == "nope")
    }

    @TestCase
    public func consumeResultParsing(): Unit {
        let request = MQProtocol.consume(MQConsumePayload("s"))
        let payload = MQConsumeResult(3, 7, 128, [1u8, 2u8])
        let response = MQProtocol.respond<MQConsumeResult>(request, payload)
        let parsed = MQProtocol.asConsumeResult(response).getOrThrow()
        @Assert(parsed.queueIndex == 3)
        @Assert(parsed.segmentedIndex == 7)
        @Assert(parsed.segmentedOffset == 128)
        @Assert(parsed.record.copyBytes() == [1u8, 2u8])
    }

    @TestCase
    public func ackPayloadCarriesQueueIdentity(): Unit {
        let request = MQProtocol.ack(MQAckPayload("s", 2, 7, 128))
        let decoded = roundtripFrame(request)
        let payload = MQProtocol.asPayload<MQAckPayload>(decoded).getOrThrow()
        @Assert(payload.subscribedId == "s")
        @Assert(payload.queueIndex == 2)
        @Assert(payload.segmentedIndex == 7)
        @Assert(payload.segmentedOffset == 128)
    }

    @TestCase
    public func internalEnvelopeCarriesSubPayload(): Unit {
        let assignment = MQTopicAssignment("/t", 2, 0, [0, 1])
        let message = MQProtocol.metaSync(assignment)
        let internal = MQProtocol.asInternal(message).getOrThrow()
        @Assert(internal.kind == MQInternalKind.META_SYNC)
        let decoded = MQProtocol.decodePayload<MQTopicAssignment>(internal.payload).getOrThrow()
        @Assert(decoded.topic == "/t")
        @Assert(decoded.owners == [0, 1])

        let backup = MQBackupPayload(1, "/b", 2, [[9u8]], [MQBackupState(1, 0, 1, false)])
        let backupInternal = MQProtocol.asInternal(MQProtocol.publishBackup(backup)).getOrThrow()
        @Assert(backupInternal.kind == MQInternalKind.BACKUP)
        let backupDecoded = MQProtocol.decodePayload<MQBackupPayload>(backupInternal.payload).getOrThrow()
        @Assert(backupDecoded.ownerIndex == 1)
        @Assert(backupDecoded.records.size == 1)
        @Assert(backupDecoded.records[0].copyBytes() == [9u8])
    }

    @TestCase
    public func statsRequestUsesRegisterAndInternalKind(): Unit {
        let message = MQProtocol.stats("/order")
        @Assert(message.command == Command.REGISTER)
        let internal = MQProtocol.asInternal(message).getOrThrow()
        @Assert(internal.kind == MQInternalKind.STATS)
        let decoded = MQProtocol.decodePayload<String>(internal.payload).getOrThrow()
        @Assert(decoded == "/order")
    }

    /** 标量/异类载荷不能被宽松转成「字段全默认」的对象（A03）。 */
    @TestCase
    public func decodePayloadRejectsScalarForObjectPayload(): Unit {
        @Assert(MQProtocol.decodePayload<MQMetaSyncRequest>(MQProtocol.encodePayload<String>("not-a-request")).isNone())
        @Assert(MQProtocol.decodePayload<MQMetaSyncRequest>(MQProtocol.encodePayload<Float64>(1.5)).isNone())
        @Assert(MQProtocol.decodePayload<MQTopicAssignment>(MQProtocol.encodePayload<Int64>(7)).isNone())
        // 正例：同类型的自描述对象仍可解出
        let request = MQProtocol.decodePayload<MQMetaSyncRequest>(
            MQProtocol.encodePayload<MQMetaSyncRequest>(MQMetaSyncRequest(3))).getOrThrow()
        @Assert(request.requesterIndex == 3)
    }

    /** 四个 `metaSync` 重载：命令、内部 kind、子载荷类型都要能经帧往返还原（A06）。 */
    @TestCase
    public func allMetaSyncOverloadsRoundtrip(): Unit {
        let request = roundtripFrame(MQProtocol.metaSync(MQMetaSyncRequest(2)))
        @Assert(request.command == REGISTER)
        let requestInternal = MQProtocol.asInternal(request).getOrThrow()
        @Assert(requestInternal.kind == MQInternalKind.META_SYNC)
        @Assert(MQProtocol.decodePayload<MQMetaSyncRequest>(requestInternal.payload).getOrThrow().requesterIndex == 2)

        let topic = roundtripFrame(MQProtocol.metaSync(MQTopicAssignment("/t", 2, 1, [1, 2])))
        @Assert(topic.command == REGISTER)
        let topicInternal = MQProtocol.asInternal(topic).getOrThrow()
        @Assert(MQProtocol.decodePayload<MQTopicAssignment>(topicInternal.payload).getOrThrow().owners == [1, 2])

        let group = roundtripFrame(MQProtocol.metaSync(MQSubscribeGroupMeta("/t", "g")))
        @Assert(group.command == REGISTER)
        let groupInternal = MQProtocol.asInternal(group).getOrThrow()
        @Assert(MQProtocol.decodePayload<MQSubscribeGroupMeta>(groupInternal.payload).getOrThrow().subscribeGroup ==
            "g")

        let tombstone = roundtripFrame(MQProtocol.metaSync(
            MQMetaTombstone(MQMetaTombstone.KIND_GROUP, "/t", "g", 9, 1, 123)))
        @Assert(tombstone.command == DEREGISTER)
        let tombstoneInternal = MQProtocol.asInternal(tombstone).getOrThrow()
        @Assert(tombstoneInternal.kind == MQInternalKind.META_SYNC)
        let decodedTombstone = MQProtocol.decodePayload<MQMetaTombstone>(tombstoneInternal.payload).getOrThrow()
        @Assert(decodedTombstone.revision == 9)
        @Assert(decodedTombstone.subscribeGroup == "g")
    }

    /** `publish(record, id!)`：帧 id 必须等于传入的 id，记录里的 MESSAGE_ID 不被改写（A08）。 */
    @TestCase
    public func publishWithExplicitIdKeepsFrameAndRecordIds(): Unit {
        let record = MQMessageRecord.encode("/t", [], "record-mid", 1i64.toData())
        let mid = MessageID()
        let message = MQProtocol.publish(record, id: mid)
        @Assert(message.id == mid)
        @Assert(message.command == PUBLISH(0))
        let decoded = roundtripFrame(message)
        @Assert(decoded.id == mid)
        let restored = MQProtocol.asRecord(decoded).getOrThrow()
        @Assert(restored == record)
        @Assert(MQMessageRecord.messageId(restored) == Some("record-mid"))
    }
}
