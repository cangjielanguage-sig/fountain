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
public class ReplicationRoleStateTest {
    private static func testConfig(): MqConfig {
        let hosts = ArrayList<String>()
        hosts.add("master:7201")
        MqConfig(
            mqHosts: hosts, syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
    }

    @TestCase
    public func testPromoteDemoteCycle(): Unit {
        let rm = ReplicationManager(testConfig())
        @Assert(rm.role() == "slave()")

        rm.promoteToMaster()
        @Assert(rm.role() == "master")

        rm.demoteToSlave("backup:7201")
        let role = rm.role()
        @Assert(role == "slave(backup:7201)")
    }

    @TestCase
    public func testSwitchbackToMaster(): Unit {
        let rm = ReplicationManager(testConfig())
        rm.promoteToMaster()
        @Assert(rm.role() == "master")

        // 切回：当前 Master 将角色交还原 Master
        rm.switchbackToMaster("original:7201")
        @Assert(rm.role() == "slave(original:7201)")
    }

    @TestCase
    public func testIsMasterAliveWhenNoConnection(): Unit {
        let rm = ReplicationManager(testConfig())
        // 无连接时 isMasterAlive 不应抛异常
        @Assert(rm.isMasterAlive())
    }

    @TestCase
    public func testIncrementalSyncWithStateLock(): Unit {
        let rm = ReplicationManager(testConfig())
        // onIncrementalSync 内部使用 stateLock 保护 lastMasterSeq
        // 即使 isSyncing=false 也应安全返回（不抛异常）
        rm.onIncrementalSync([0x01u8, 0x02u8], 42)
        // 验证调用后状态一致
        @Assert(rm.role() == "slave()")
        rm.promoteToMaster()
        @Assert(rm.role() == "master")
        // 作为 Master 调用 onIncrementalSync 也不应抛异常
        rm.onIncrementalSync([0x03u8], 99)
        @Assert(rm.role() == "master")
    }
}
