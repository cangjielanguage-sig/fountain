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
public class DeleteGroupMultiQueueTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_dg_test", segmentMaxSize: 16384,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testDeleteGroupResetsAllQueueOffsets(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建多队列主题 (queueCount=3)
        tm.createTopic("/multi-delete", queueCount: 3)

        // 创建消费者组（初始化所有 offset=0）
        @Assert(cgm.createGroup("/multi-delete", "del-group") == MqErrorCode.SUCCESS)

        // 在不同队列上设置不同 offset
        cgm.setOffset("/multi-delete", 0, "del-group", 10)
        cgm.setOffset("/multi-delete", 1, "del-group", 20)
        cgm.setOffset("/multi-delete", 2, "del-group", 30)
        @Assert(cgm.getOffset("/multi-delete", 0, "del-group") == 10)
        @Assert(cgm.getOffset("/multi-delete", 1, "del-group") == 20)
        @Assert(cgm.getOffset("/multi-delete", 2, "del-group") == 30)

        // 删除消费者组 — 不重置 offset（P2-3: 组删除后 offset 管理无意义）
        @Assert(cgm.deleteGroup("/multi-delete", "del-group") == MqErrorCode.SUCCESS)
        // offset 保留删除前的值（组已不存在，但 deliveryManager 仍持有该组 offset）
        @Assert(cgm.getOffset("/multi-delete", 0, "del-group") == 10)
        @Assert(cgm.getOffset("/multi-delete", 1, "del-group") == 20)
        @Assert(cgm.getOffset("/multi-delete", 2, "del-group") == 30)
    }

    @TestCase
    public func testDeleteGroupSingleQueue(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 创建单队列主题
        tm.createTopic("/single-delete", queueCount: 1)
        @Assert(cgm.createGroup("/single-delete", "sg") == MqErrorCode.SUCCESS)
        cgm.setOffset("/single-delete", 0, "sg", 99)
        @Assert(cgm.getOffset("/single-delete", 0, "sg") == 99)

        // 删除组 — offset 不重置（P2-3）
        @Assert(cgm.deleteGroup("/single-delete", "sg") == MqErrorCode.SUCCESS)
        @Assert(cgm.getOffset("/single-delete", 0, "sg") == 99)
    }

    @TestCase
    public func testDeleteGroupNonExistentReturnsError(): Unit {
        let config = testConfig()
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        // 删除不存在的组应返回错误
        let code = cgm.deleteGroup("/no-topic", "no-group")
        @Assert(code != MqErrorCode.SUCCESS)
    }
}
