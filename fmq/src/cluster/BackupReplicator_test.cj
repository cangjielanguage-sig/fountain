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
package fountain::fmq.cluster

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.MQBackupPayload
import fountain::f_protocol.default.Message

@Test
class BackupReplicatorTest {
    private static func payloadOf(message: Message): MQBackupPayload {
        let internal = MQProtocol.asInternal(message).getOrThrow()
        MQProtocol.decodePayload<MQBackupPayload>(internal.payload).getOrThrow()
    }

    @TestCase
    public func backupZeroSendsNothing(): Unit {
        let transport = FakeTransport(3, 0)
        let replicator = BackupReplicator(transport, 0)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flush()
        @Assert(transport.sentCount() == 0)
        replicator.close()
    }

    @TestCase
    public func sendsToRingSuccessors(): Unit {
        let transport = FakeTransport(3, 0)
        let replicator = BackupReplicator(transport, 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        replicator.flush()
        @Assert(transport.sentCount() == 2)
        let toNode1 = transport.messagesSentTo(1)
        let toNode2 = transport.messagesSentTo(2)
        @Assert(toNode1.size == 1)
        @Assert(toNode2.size == 1)
        let payload = payloadOf(toNode1[0])
        @Assert(payload.records.size == 2)
        @Assert(payload.states[0].offset == 0)
        @Assert(payload.states[1].offset == 8)
        replicator.close()
    }

    @TestCase
    public func batchOfSixtyFourTriggersImmediately(): Unit {
        let transport = FakeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        for (i in 0..64) {
            replicator.record("/t", 0, LogPosition(1, i), [UInt8(i)])
        }
        // 累积到 64 条时已自动 flush，无需手动调用
        @Assert(transport.sentCount() == 1)
        let payload = payloadOf(transport.messagesSentTo(1)[0])
        @Assert(payload.records.size == 64)
        replicator.close()
    }

    @TestCase
    public func fullQueueDropsWithoutBlocking(): Unit {
        let transport = FakeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1, capacity: 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        // 第三条被丢弃
        replicator.record("/t", 0, LogPosition(1, 16), [3u8])
        replicator.flush()
        let payload = payloadOf(transport.messagesSentTo(1)[0])
        @Assert(payload.records.size == 2)
        replicator.close()
    }

    @TestCase
    public func onePeerFailureDoesNotBlockOthers(): Unit {
        let transport = FakeTransport(3, 0)
        transport.available[1] = false
        let replicator = BackupReplicator(transport, 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flush()
        @Assert(transport.messagesSentTo(1).size == 0)
        @Assert(transport.messagesSentTo(2).size == 1)
        replicator.close()
    }

    @TestCase
    public func closeFlushesPending(): Unit {
        let transport = FakeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.close()
        @Assert(transport.messagesSentTo(1).size == 1)
    }

    @TestCase
    public func timerFlushesBeforeBatchIsFull(): Unit {
        let transport = FakeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.start()
        try {
            replicator.record("/t", 0, LogPosition(1, 0), [1u8])
            // 只等定时器（100ms），不手动 flush；超时 3s 轮询
            var waited = 0
            while (transport.sentCount() == 0 && waited < 300) {
                sleep(Duration.millisecond * 10)
                waited++
            }
            @Assert(transport.sentCount() == 1)
            let payload = payloadOf(transport.messagesSentTo(1)[0])
            @Assert(payload.records.size == 1)
        } finally {
            replicator.close()
        }
    }
}
