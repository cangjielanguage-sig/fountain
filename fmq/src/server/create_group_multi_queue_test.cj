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
public class CreateGroupMultiQueueTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_cg_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testCreateGroupInitializesAllQueueOffsets(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建多队列主题
        tm.createTopic("/multi-queue", queueCount: 3)

        // 创建消费者组
        let code = cgm.createGroup("/multi-queue", "test-group")
        @Assert(code == MqErrorCode.SUCCESS)

        // 验证 3 个队列的 offset 全部初始化为 0
        @Assert(cgm.getOffset("/multi-queue", 0, "test-group") == 0)
        @Assert(cgm.getOffset("/multi-queue", 1, "test-group") == 0)
        @Assert(cgm.getOffset("/multi-queue", 2, "test-group") == 0)
    }

    @TestCase
    public func testCreateGroupWithSingleQueue(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建单队列主题（默认）
        tm.createTopic("/single-queue", queueCount: 1)
        let code = cgm.createGroup("/single-queue", "single-group")
        @Assert(code == MqErrorCode.SUCCESS)

        // 仅 queue 0 应被初始化
        @Assert(cgm.getOffset("/single-queue", 0, "single-group") == 0)
    }
}
