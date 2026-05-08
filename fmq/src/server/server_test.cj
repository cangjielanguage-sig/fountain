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

@Test
public class QueueDistributionTest {
    @TestCase
    public func testDistributeReturnsValidIndex(): Unit {
        let config = testConfig()
        let qm = QueueManager(config)
        let n0 = qm.distribute("/test", 0, 3)
        @Assert(n0 >= 0 && n0 < 3)
        let n1 = qm.distribute("/test", 1, 3)
        @Assert(n1 >= 0 && n1 < 3)
        let n2 = qm.distribute("/test", 2, 3)
        @Assert(n2 >= 0 && n2 < 3)
    }

    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("node1:7201")
        hosts.add("node2:7201")
        hosts.add("node3:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp/fmq_test", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1
        )
    }
}

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

@Test
public class DeliverySimpleTest {
    @TestCase
    public func testRecordAndAck(): Unit {
        let config = testConfig()
        let dm = DeliveryManager(config)
        let record = dm.recordDelivery("msg1", "consumer1", "group1")
        @Assert(record.messageId == "msg1")
        let ok = dm.onAck("msg1", "/test", 0)
        @Assert(ok)
    }

    @TestCase
    public func testDoubleAckReturnsFalse(): Unit {
        let config = testConfig()
        let dm = DeliveryManager(config)
        dm.recordDelivery("msg1", "consumer1", "group1")
        dm.onAck("msg1", "/test", 0)
        let second = dm.onAck("msg1", "/test", 0)
        @Assert(!second)
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
