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

import std.collection.HashSet
import std.sync.{AtomicBool, AtomicInt64}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_io.LogPosition
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.{MQBackupCursor, MQBackupPayload, MQBackupState}
import fountain::f_protocol.default.Message

@Test
class BackupReplicatorTest {
    /** 备份用例的传输：send 返回成功响应（None 才表示失败）。 */
    private static func makeTransport(nodeCount: Int64, selfIndex: Int64): FakeTransport {
        let transport = FakeTransport(nodeCount, selfIndex)
        transport.responder = {_, message =>
            Some(MQProtocol.respond<MQBackupPayload>(message, MQBackupPayload()))
        }
        transport
    }

    private static func payloadOf(message: Message): MQBackupPayload {
        let internal = MQProtocol.asInternal(message).getOrThrow()
        MQProtocol.decodePayload<MQBackupPayload>(internal.payload).getOrThrow()
    }

    @TestCase
    public func backupZeroSendsNothing(): Unit {
        let transport = makeTransport(3, 0)
        let replicator = BackupReplicator(transport, 0)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flushOnce()
        @Assert(transport.sentCount() == 0)
        replicator.close()
    }

    @TestCase
    public func sendsToRingSuccessors(): Unit {
        let transport = makeTransport(3, 0)
        let replicator = BackupReplicator(transport, 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        replicator.flushOnce()
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
    public func recordOnlyEnqueuesAndFlushSendsOneBatch(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        for (i in 0..64) {
            replicator.record("/t", 0, LogPosition(1, i), [UInt8(i)])
        }
        // 发布线程只入队：不阻塞、不发送（A27）
        @Assert(transport.sentCount() == 0)
        @Assert(replicator.pendingCount == 64)
        replicator.flushOnce()
        @Assert(transport.sentCount() == 1)
        let payload = payloadOf(transport.messagesSentTo(1)[0])
        @Assert(payload.records.size == 64)
        replicator.close()
    }

    @TestCase
    public func fullQueueDropsWithoutBlocking(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1, capacity: 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        // 第三条被丢弃
        replicator.record("/t", 0, LogPosition(1, 16), [3u8])
        replicator.flushOnce()
        let payload = payloadOf(transport.messagesSentTo(1)[0])
        @Assert(payload.records.size == 2)
        replicator.close()
    }

    @TestCase
    public func onePeerFailureDoesNotBlockOthers(): Unit {
        let transport = makeTransport(3, 0)
        transport.available[1] = false
        let replicator = BackupReplicator(transport, 2)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flushOnce()
        @Assert(transport.messagesSentTo(1).size == 0)
        @Assert(transport.messagesSentTo(2).size == 1)
        replicator.close()
    }

    @TestCase
    public func closeFlushesPending(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.close()
        @Assert(transport.messagesSentTo(1).size == 1)
    }

    @TestCase
    public func timerFlushesBeforeBatchIsFull(): Unit {
        let transport = makeTransport(2, 0)
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

    // ===== 异步、真实状态与重试（A26/A27/A30/A38） =====

    /** 后继发送阻塞时，publish 侧不受影响。 */
    @TestCase
    public func slowReplicasDoNotBlockPublish(): Unit {
        let transport = makeTransport(2, 0)
        transport.responder = {_, message =>
            sleep(Duration.millisecond * 300)
            Some(MQProtocol.respond<MQBackupPayload>(message, MQBackupPayload()))
        }
        let replicator = BackupReplicator(transport, 1)
        let start = DateTime.now()
        for (i in 0..200) {
            replicator.record("/t", 0, LogPosition(1, i), [UInt8(i % 251)])
        }
        let elapsed = (DateTime.now() - start).toMilliseconds()
        @Assert(elapsed < 1000)
        @Assert(replicator.pendingCount == 200)
        replicator.close()
    }

    /** flush 时读取真实消费状态与位点。 */
    @TestCase
    public func payloadCarriesRealStatesAndCursors(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.setStateSource(StubStateSource())
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        replicator.flushOnce()
        let payload = payloadOf(transport.messagesSentTo(1)[0])
        @Assert(payload.states.size == 2)
        @Assert(payload.states[0].acked)
        @Assert(payload.states[0].deliverCount == 2)
        @Assert(!payload.states[1].acked)
        @Assert(payload.cursors.size == 1)
        @Assert(payload.cursors[0].group == "g")
        @Assert(payload.cursors[0].segmentedOffset == 8)
        replicator.close()
    }

    /** 全部目标失败时批次重新入队，恢复后发出；超过重试上限丢弃。 */
    @TestCase
    public func failedBatchIsRetriedAndEventuallyDropped(): Unit {
        let transport = makeTransport(2, 0)
        transport.available[1] = false
        let replicator = BackupReplicator(transport, 1)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flushOnce()
        @Assert(transport.sentCount() == 0)
        @Assert(replicator.pendingCount == 1)
        // 恢复后成功
        transport.available[1] = true
        replicator.flushOnce()
        @Assert(transport.sentCount() == 1)
        @Assert(replicator.pendingCount == 0)

        // 连续失败超过上限：丢弃，不再无限重试
        let flaky = makeTransport(2, 0)
        flaky.available[1] = false
        let dropper = BackupReplicator(flaky, 1)
        dropper.record("/t", 0, LogPosition(1, 0), [1u8])
        for (_ in 0..5) {
            dropper.flushOnce()
        }
        @Assert(dropper.pendingCount == 0)
        dropper.close()
        replicator.close()
    }

    /** 部分目标失败：只重试失败目标，已成功的目标不重复收（R2-G5）。 */
    @TestCase
    public func partialTargetFailureRetriesOnlyFailedTarget(): Unit {
        let transport = makeTransport(3, 0)
        transport.available[2] = false
        let replicator = BackupReplicator(transport, 2)
        try {
            replicator.record("/t", 0, LogPosition(1, 0), [1u8])
            replicator.flushOnce()
            @Assert(transport.messagesSentTo(1).size == 1)
            @Assert(transport.messagesSentTo(2).size == 0)
            // 只有失败目标那一条留在队列里
            @Assert(replicator.pendingCount == 1)

            transport.available[2] = true
            replicator.flushOnce()
            // 节点 1 不重复收，节点 2 补齐
            @Assert(transport.messagesSentTo(1).size == 1)
            @Assert(transport.messagesSentTo(2).size == 1)
            @Assert(replicator.pendingCount == 0)
        } finally {
            replicator.close()
        }
    }

    /** 关闭必须等在途批次发完再 drain：close 返回后不得还有发送在进行（R2-G6）。 */
    @TestCase
    public func closeWaitsForInFlightBatch(): Unit {
        let transport = makeTransport(2, 0)
        let active = AtomicInt64(0)
        transport.responder = {_, message =>
            active.fetchAdd(1)
            sleep(Duration.millisecond * 700)
            active.fetchSub(1)
            Some(MQProtocol.respond<MQBackupPayload>(message, MQBackupPayload()))
        }
        let replicator = BackupReplicator(transport, 1)
        replicator.start()
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        var waited = 0
        while (active.load() == 0 && waited < 200) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(active.load() == 1)
        replicator.close()
        // close 返回即在途发送已结束，待发队列也排空
        @Assert(active.load() == 0)
        @Assert(replicator.pendingCount == 0)
    }

    /** 关闭后 record 丢弃且不崩溃。 */
    @TestCase
    public func recordAfterCloseIsDropped(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.close()
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        @Assert(transport.sentCount() == 0)
        @Assert(replicator.pendingCount == 0)
    }

    /** 单节点没有副本可发，但批次不会被「凭空丢弃」。 */
    @TestCase
    public func singleNodeKeepsBatchWithoutTargets(): Unit {
        let transport = makeTransport(1, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flushOnce()
        @Assert(transport.sentCount() == 0)
        @Assert(replicator.pendingCount == 0)
        replicator.close()
    }

    /** 关闭与发送并发：不抛异常、不丢已入队批次、关闭后队列为空。 */
    @TestCase
    public func closeWhileFlushingIsSafe(): Unit {
        let transport = makeTransport(2, 0)
        transport.responder = {_, message =>
            sleep(Duration.millisecond * 5)
            Some(MQProtocol.respond<MQBackupPayload>(message, MQBackupPayload()))
        }
        let replicator = BackupReplicator(transport, 1)
        replicator.start()
        // 先发一批，保证「关闭与发送并发」确有其事
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.flushOnce()
        @Assert(transport.sentCount() == 1)
        let stop = AtomicBool(false)
        let workers = AtomicInt64(0)
        for (w in 0..4) {
            spawn {
                var i = 0
                while (!stop.load() && i < 50) {
                    replicator.record("/t", 0, LogPosition(1, i), [UInt8(i % 251)])
                    replicator.flushOnce()
                    i++
                }
                workers.fetchAdd(1)
            }
        }
        // 与在途发送并发关闭
        replicator.close()
        stop.store(true)
        var waited = 0
        while (workers.load() < 4 && waited < 1000) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(workers.load() == 4)
        // 收尾：并发窗口内可能还有入队，最终必须排空
        replicator.flushOnce()
        @Assert(replicator.pendingCount == 0)
    }

    /** 64 条由工作线程自动触发（不手动 flush）。 */
    @TestCase
    public func workerFlushesFullBatch(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.start()
        try {
            for (i in 0..64) {
                replicator.record("/t", 0, LogPosition(1, i), [UInt8(i % 251)])
            }
            var waited = 0
            while (transport.sentCount() == 0 && waited < 300) {
                sleep(Duration.millisecond * 10)
                waited++
            }
            @Assert(transport.sentCount() == 1)
            @Assert(payloadOf(transport.messagesSentTo(1)[0]).records.size == 64)
        } finally {
            replicator.close()
        }
    }

    /** 批次按 `(topic, queueIndex)` 分组：不同主题/队列不合并成一批（A42）。 */
    @TestCase
    public func batchesAreGroupedByTopicAndQueue(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        try {
            replicator.record("/a", 0, LogPosition(1, 0), [1u8])
            replicator.record("/a", 1, LogPosition(1, 0), [2u8])
            replicator.record("/b", 0, LogPosition(1, 0), [3u8])
            replicator.record("/a", 0, LogPosition(1, 8), [4u8])
            replicator.flushOnce()
            let sent = transport.messagesSentTo(1)
            @Assert(sent.size == 3)
            let keys = HashSet<String>()
            for (message in sent) {
                let payload = payloadOf(message)
                keys.add("${payload.topic}:${payload.queueIndex}")
                if (payload.topic == "/a" && payload.queueIndex == 0) {
                    @Assert(payload.records.size == 2)
                } else {
                    @Assert(payload.records.size == 1)
                }
            }
            @Assert(keys.size == 3)
        } finally {
            replicator.close()
        }
    }

    /** 关闭后不再接受新记录，也不会再发送（定时器已停）。 */
    @TestCase
    public func closedReplicatorStopsDispatching(): Unit {
        let transport = makeTransport(2, 0)
        let replicator = BackupReplicator(transport, 1)
        replicator.start()
        replicator.record("/t", 0, LogPosition(1, 0), [1u8])
        replicator.close()
        let afterClose = transport.sentCount()
        replicator.record("/t", 0, LogPosition(1, 8), [2u8])
        sleep(Duration.millisecond * 150)
        @Assert(transport.sentCount() == afterClose)
        @Assert(replicator.pendingCount == 0)
    }
}

/** 固定返回：第 0 条已确认、第 1 条未确认，组位点在 1:8。 */
private class StubStateSource <: BackupStateSource {
    public func backupStates(topic: String, queueIndex: Int64, positions: Array<LogPosition>): Array<MQBackupState> {
        Array<MQBackupState>(positions.size) {i =>
            MQBackupState(positions[i].seq, positions[i].offset, if (i == 0) {2} else {0}, i == 0)
        }
    }

    public func backupCursors(topic: String, queueIndex: Int64): Array<MQBackupCursor> {
        [MQBackupCursor("g", 1, 8)]
    }
}
