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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_protocol.default.{Message as ProtocolMessage, MessageID, Command, VOTE, APPROVE}
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import std.sync.AtomicInt64
import fountain::fmq.common.extractBytes

/**
 * CommandExecutor 单元测试。
 * 测试命令 handler 的正确性，使用真实依赖（无需 mock）。
 *
 * 通过 Command.value 比较（tag 位于高 4 位：RESP=11, PING=12）。
 */

@Test
public class DeliveryRetryTopicTest {
    @TestCase
    public func testRetryUsesTopicFromRecord(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm  // capture let for lambda

        // 注册消费者匹配 /test-retry-topic
        let reg = ConsumerRegistration(
            consumerId: "retry-consumer", groupId: "retry-group",
            matchModeStr: "Exact:/test-retry-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 构造 DeliveryRecord 包含正确的 topic
        let record = DeliveryRecord(
            "/test-retry-topic:0:retry-group:0",   // messageId
            "retry-consumer",                       // consumerId
            "retry-group",                          // groupId
            "/test-retry-topic",                    // topic
            DateTime.now() - Duration.second * 60,  // deliverTime (超时)
            retryCount: AtomicInt64(0))

        // retry 应使用 record.topic 找到消费者，返回 true
        @Assert(dmL.retry(record, cm))
        // retryCount 应递增为 1
        @Assert(record.retryCount.load() == 1)
    }

    @TestCase
    public func testRetryWrongTopicReturnsTrue(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm

        // 注册消费者匹配 /other-topic
        let reg = ConsumerRegistration(
            consumerId: "other-consumer", groupId: "other-group",
            matchModeStr: "Exact:/other-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 记录 topic=/wrong-topic 无匹配消费者
        let record = DeliveryRecord(
            "/wrong-topic:0:other-group:0",
            "other-consumer", "other-group", "/wrong-topic",
            DateTime.now() - Duration.second * 60,
            retryCount: AtomicInt64(0))

        // P3-4: 无消费者时递增 retryCount 防止消息永久驻留，返回 true 等待消费者上线
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 1)
    }

    /**
     * P2-3: 验证有匹配消费者时 retry 正常返回 true，count 递增。
     */
    @TestCase
    public func testRetryWithConsumerReturnsTrue(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm

        let reg = ConsumerRegistration(
            consumerId: "match-cons", groupId: "match-group",
            matchModeStr: "Exact:/match-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        let record = DeliveryRecord(
            "/match-topic:0:match-group:0", "match-cons", "match-group", "/match-topic",
            DateTime.now() - Duration.second * 60,
            retryCount: AtomicInt64(0))

        @Assert(dmL.retry(record, cm))
        // 有消费者时 retryCount 递增
        @Assert(record.retryCount.load() == 1)
    }
    /**
     * P0-3: 验证 retryCount > maxRetryCount fencepost
     * maxRetryCount=3 应允许 3 次重试，第 4 次触发 DLQ。
     * 修复前用 >= 导致实际只重试 2 次。
     */
    @TestCase
    public func testRetryCountFencepostAllowsAllRetries(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm

        let reg = ConsumerRegistration(
            consumerId: "rf-consumer", groupId: "rf-group",
            matchModeStr: "Exact:/retry-fence",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        let record = DeliveryRecord(
            "/retry-fence:0:rf-group:0",
            "rf-consumer", "rf-group", "/retry-fence",
            DateTime.now() - Duration.second * 60,
            retryCount: AtomicInt64(0))

        // P3: pre-increment check → 3 retries before DLQ at count=3
        // retry 1: 0>=3? no → count=1
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 1)
        // retry 2: 1>=3? no → count=2
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 2)
        // retry 3: 2>=3? no → count=3
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 3)
        // retry 4: 3>=3? yes → DLQ, count unchanged
        @Assert(!dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 3)
    }

    /**
     * SRV-6: 验证 retry 不依赖 queueManager 引用（使用 cached payload）。
     * 修复前 retry 从 SegmentedLog 重读数据（需 queueManager），
     * 修复后使用 DeliveryRecord.payload 缓存。
     */
    @TestCase
    public func testRetryWithoutQueueManagerSucceeds(): Unit {
        let dm = DeliveryManager(DeliveryRetryTopicTest.testConfig(), serverId: "test:7201")
        let cm = ConsumerMatcher()
        let dmL = dm

        // 不设置 queueManager（None）

        let reg = ConsumerRegistration(
            consumerId: "sr6-cons", groupId: "sr6-group",
            matchModeStr: "Exact:/sr6-topic",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        let record = DeliveryRecord(
            "/sr6-topic:0:sr6-group:0", "sr6-cons", "sr6-group", "/sr6-topic",
            DateTime.now() - Duration.second * 60,
            retryCount: AtomicInt64(0), payload: [0x01u8, 0x02u8])

        // 即使 queueManager=None，retry 也应成功（使用 payload 缓存）
        @Assert(dmL.retry(record, cm))
        @Assert(record.retryCount.load() == 1)
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_retry_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }
}
