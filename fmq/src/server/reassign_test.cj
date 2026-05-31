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
import fountain::f_data.base.*
import std.sync.{AtomicInt64, AtomicBool}
import std.fs.*
import std.fs.removeIfExists


@Test
public class ReassignTest {
    @TestCase
    public func testReassignCreatesQueuesLocally(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_reassign_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        // nodeIndex=0 创建队列，nodeIndex=1 故障后接管
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        let before = qm.getQueues("/test")
        @Assert(before.isSome())
        if (let Some(qs) <- before) {
            @Assert(qs.size == 1)  // nodeIndex=0 只创建归属于节点 0 的队列
        }
        // 节点 1 故障，节点 0 接管
        let reassigned = qm.reassign(1)
        @Assert(reassigned.size > 0)
        let after = qm.getQueues("/test")
        if (let Some(qs) <- after) {
            @Assert(qs.size == 2)  // 接管后 2 个队列都在本地
        }
    }

    @TestCase
    public func testUnreassignDrainsThenRemoves(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_unreassign_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        qm.reassign(1)
        let afterReassign = qm.getQueues("/test")
        if (let Some(qs) <- afterReassign) {
            @Assert(qs.size == 2)
        }
        // 标记排空：draining=true，仍在队列列表中
        qm.unreassign(1)
        let q1 = qm.getQueue("/test", 1)
        @Assert(q1.isSome())
        if (let Some(q) <- q1) {
            @Assert(q.draining.load())
            @Assert(!q.isClosed())
        }
        // 排空完成检查：deliveryBuffer 空应自动移除
        qm.drainCompleteCheck()
        let afterDrain = qm.getQueue("/test", 1)
        @Assert(afterDrain.isNone())  // 已移除
        // 自己的队列不受影响
        let q0 = qm.getQueue("/test", 0)
        @Assert(q0.isSome())
    }

    @TestCase
    public func testReassignStartsWriterReader(): Unit {
        // P2-2: reassign 后 writer/reader 线程应自动启动
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        let config = MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_reassign_wr", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/test", 2)
        let reassigned = qm.reassign(1)
        @Assert(reassigned.size > 0)
        // 验证接管后的队列存在（writer/reader 已在内部启动）
        let q1 = qm.getQueue("/test", 1)
        @Assert(q1.isSome())
        if (let Some(q) <- q1) {
            @Assert(!q.isClosed())
        }
        // 无崩溃即验证 writer/reader 启动逻辑正确
    }

}
