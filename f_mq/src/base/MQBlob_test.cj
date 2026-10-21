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

import std.fs.*
import std.sync.AtomicInt64
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.payload.*
import fountain::f_protocol.default.*

/**
 * 大载荷字节字段（A01/A07）。
 *
 * `DefaultCodec` 在 4096 字节以上把 `INPUTSTREAM` 还原成临时文件形态；字段类型
 * 必须是 `MQBlob` 才能读回，否则会被静默降级成空数组（=「本次没有消息」）。
 */
@Test
class MQBlobTest {
    private static func bytesOf(size: Int64): Array<Byte> {
        Array<Byte>(size) {i => UInt8(i % 251)}
    }

    private static func encodeToBytes<T>(value: T): Array<Byte> where T <: ToData {
        let codec = DefaultCodec()
        try {
            codec.encode(value.toData())
            codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
    }

    private static func decodeFromBytes<T>(bytes: Array<Byte>): ?T where T <: FromToData {
        let codec = DefaultCodec()
        try {
            codec.decode<T>(ByteBuffer(bytes))
        } finally {
            codec.release()
        }
    }

    private static func blobOf(data: Data): ?MQBlob {
        match (MQBlob.tryFromData(data, SILENCE)) {
            case x: ?MQBlob => x
            case b: MQBlob => Some(b)
            case _ => None<MQBlob>
        }
    }

    private static func countTempEntries(): Int64 {
        let count = AtomicInt64(0)
        if (!exists("/tmp")) {
            return 0
        }
        Directory.walk("/tmp") {info: FileInfo =>
            if (info.name.startsWith("tmpFile")) {
                count.fetchAdd(1)
            }
            true
        }
        count.load()
    }

    @TestCase
    public func consumeResultRoundtripsAtThresholds(): Unit {
        for (size in [0, 4096, 4097, 16 * 1024, 1024 * 1024]) {
            let record = bytesOf(size)
            let value = MQConsumeResult(3, 7, 128, record)
            let back = decodeFromBytes<MQConsumeResult>(encodeToBytes(value)).getOrThrow()
            @Assert(back.queueIndex == 3)
            @Assert(back.segmentedIndex == 7)
            @Assert(back.segmentedOffset == 128)
            @Assert(back.record.size() == size)
            @Assert(back.record.copyBytes() == record)
            @Assert(back.hasMessage() == (size > 0))
        }
    }

    @TestCase
    public func backupAndDeadLetterRoundtripLargeRecords(): Unit {
        let record = bytesOf(16 * 1024)
        let backup = MQBackupPayload(1, "/t", 2, [record], [MQBackupState(1, 0, 0, false)])
        let envelope = MQInternalMessage(MQInternalKind.BACKUP, MQProtocol.encodePayload<MQBackupPayload>(backup))
        let backEnvelope = decodeFromBytes<MQInternalMessage>(encodeToBytes(envelope)).getOrThrow()
        @Assert(backEnvelope.kind == MQInternalKind.BACKUP)
        @Assert(backEnvelope.payload.size() > 0)
        let backBackup = MQProtocol.decodePayload<MQBackupPayload>(backEnvelope.payload).getOrThrow()
        @Assert(backBackup.records.size == 1)
        @Assert(backBackup.records[0].copyBytes() == record)

        let letter = MQDeadLetterMessage("/t", 1, "g", 3, 0, 2, DateTime.now(), record)
        let backLetter = decodeFromBytes<MQDeadLetterMessage>(encodeToBytes(letter)).getOrThrow()
        @Assert(backLetter.record.size() == record.size)
        @Assert(backLetter.record.copyBytes() == record)
    }

    @TestCase
    public func decodingLargeRecordLeavesNoTempFiles(): Unit {
        let before = countTempEntries()
        let record = bytesOf(16 * 1024)
        let back = decodeFromBytes<MQConsumeResult>(encodeToBytes(MQConsumeResult(0, 0, 0, record))).getOrThrow()
        @Assert(back.record.size() == record.size)
        @Assert(countTempEntries() == before)
    }

    @TestCase
    public func nonFileStreamIsNotTreatedAsEmpty(): Unit {
        // 非文件形态的 DataInputStream 没有长度语义：必须失败，不能降级成「空字节」
        @Assert(blobOf(DataInputStream(ByteBuffer([1u8, 2u8]))).isNone())
        @Assert(MQBytes.fromData(DataInputStream(ByteBuffer([1u8, 2u8]))).isNone())
    }

    @TestCase
    public func blobEncodesExactlyLikeArray(): Unit {
        for (size in [0, 4096, 4097, 16 * 1024]) {
            let record = bytesOf(size)
            let asArray = encodeToBytes<Array<Byte>>(record)
            let asBlob = encodeToBytes<MQBlob>(MQBlob(record))
            @Assert(asArray == asBlob)

            // 旧字节 → 新类型
            let blobBack = decodeFromBytes<MQBlob>(asArray).getOrThrow()
            @Assert(blobBack.copyBytes() == record)
            // 新字节 → 旧类型：只有内存形态（<= 4096）可以还原，
            // 超过阈值时 `Array<Byte>` 字段仍然会降级成空数组（旧节点的已知缺陷）
            let arrayBack = decodeFromBytes<Array<Byte>>(asBlob).getOrThrow()
            @Assert(arrayBack == (if (size <= 4096) {record} else {Array<Byte>()}))
        }
    }

    @TestCase
    public func dataNoneIsAnEmptyBlob(): Unit {
        let blob = blobOf(DataNone.INSTANCE).getOrThrow()
        @Assert(blob.isEmpty())
        @Assert(blob.size() == 0)
    }

    @TestCase
    public func asConsumeResultSeparatesFailureFromEmpty(): Unit {
        let empty = MQProtocol.asConsumeResult(Message.build<MQConsumeResult>(Command.CONSUME(0), MessageID(),
            Some(MQConsumeResult(1, 2, 3, [])))).getOrThrow()
        @Assert(!empty.hasMessage())

        // 类型不对 → None（不是「没有消息」）
        @Assert(MQProtocol.asConsumeResult(Message.build<DataString>(Command.CONSUME(0), MessageID(),
            Some(DataString("oops")))).isNone())
        @Assert(MQProtocol.asConsumeResult(Message.build<MQTopicAssignment>(Command.CONSUME(0), MessageID(),
            Some(MQTopicAssignment("/t", 1, 0, [0])))).isNone())
    }
}
