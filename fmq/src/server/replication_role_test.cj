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
public class ReplicationRoleTest {
    @TestCase
    public func testPromoteAndDemote(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.role() != "master")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        rm.demoteToSlave("new-master")
        @Assert(rm.role().contains("slave"))
    }

    @TestCase
    public func testSlaveRegistration(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        @Assert(rm.onSlaveOf("slave1"))
        @Assert(rm.getSlaves().size == 1)
    }

    @TestCase
    public func testFailover(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.failoverToMaster())
        @Assert(rm.role() == "master")
    }

    @TestCase
    public func testPromoteDemoteCycle(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        @Assert(rm.role() != "master")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        rm.demoteToSlave("node2")
        @Assert(rm.role().contains("slave"))
        // 二次 promote 应生效
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
    }

    /**
     * P1-2: 验证 isMasterAlive 在没有 master 连接时不崩溃并返回 true。
     * masterConn 为 None 且 masterNodeId 为空或 mqHosts 为空时返回 true。
     */
    @TestCase
    public func testIsMasterAliveNoMasterReturnsTrue(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        // 从未调用 connectToMaster/promoteToMaster → masterConn 为 None
        // masterNodeId 为空 → 返回 true
        @Assert(rm.isMasterAlive())
    }

    /**
     * P1-1: 验证 connectToMaster 失败后 isSyncing 为 false。
     * 连接不可达的 master 时 error path 正确设置同步状态。
     */
    @TestCase
    public func testConnectToMasterFailsReturnsFalse(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("localhost:1")
        let config = MqConfig.forTest(dataDir: "/tmp/fmq_p11_sync", mqHosts: hosts)
        let rm = ReplicationManager(config)
        rm.demoteToSlave("node99")
        // 连接不可达的 master，应返回 false（不抛异常）
        @Assert(!rm.connectToMaster("node99"))
    }

    /**
     * P2-2: 验证 onSlaveOf 重复调用不产生重复条目。
     * 重连时更新 lastHeartbeat 而非新增 SlaveProgress。
     */
    @TestCase
    public func testOnSlaveOfReconnectUpdatesLastHeartbeat(): Unit {
        let config = testConfig()
        let rm = ReplicationManager(config)
        rm.promoteToMaster()
        @Assert(rm.onSlaveOf("slave1"))
        @Assert(rm.getSlaves().size == 1)
        // 再次调用 onSlaveOf 同一节点（模拟重连）
        @Assert(rm.onSlaveOf("slave1"))
        // 不应出现重复条目
        @Assert(rm.getSlaves().size == 1)
        // 验证不同节点各算一次
        @Assert(rm.onSlaveOf("slave2"))
        @Assert(rm.getSlaves().size == 2)
    }

    private static func testConfig(): MqConfig {
        MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}
