/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class ForTestDefaultsTest {
    private static func hosts(): ArrayList<String> {
        let h = ArrayList<String>()
        h.add("h:1")
        h
    }

    @TestCase
    public func testForTestUsesTestDataDir(): Unit {
        let cfg = MqConfig.forTest(dataDir: "/tmp/my-test", mqHosts: hosts())
        @Assert(cfg.dataDir == "/tmp/my-test")
    }

    @TestCase
    public func testForTestDefaultsMatchConstructorDefaults(): Unit {
        let hosts = hosts()
        hosts.add("host1:7201")
        let cfg = MqConfig.forTest(mqHosts: hosts)
        // forTest 与构造函数默认值一致的关键字段
        @Assert(cfg.heartbeatIntervalSec == 5)
        @Assert(cfg.healthcheckMaxRetry == 3)
        @Assert(cfg.idleTimeoutMinutes == 30)
        @Assert(cfg.ackTimeoutMs == 30000)
        @Assert(cfg.maxRetryCount == 3)
        @Assert(cfg.retryIntervalMs == 1000)
        @Assert(cfg.dlqRetentionHours == 168)
        @Assert(cfg.maxLabelsPerMessage == 64)
        @Assert(cfg.retentionHours == 72)
        @Assert(cfg.syncQuorum == 1)
        @Assert(cfg.cleanupBatchSize == 10)
    }

    @TestCase
    public func testForTestSegmentMaxSizeSmaller(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("h:1")
        let cfg = MqConfig.forTest(mqHosts: hosts)
        // 测试用 segment 大小 1MB，不同于生产环境 512MB
        @Assert(cfg.segmentMaxSize == 1024 * 1024)
    }

    /**
     * P4-1: heartbeatIntervalSec=0 的 MqConfig 仍然可正常构造，
     * 刷新线程跳过由 MqCommand.exec 中的 guard 处理。
     */
    @TestCase
    public func testConstructorAllowsZeroHeartbeatInterval(): Unit {
        let hosts = hosts()
        let cfg = MqConfig(mqHosts: hosts, heartbeatIntervalSec: 0)
        @Assert(cfg.heartbeatIntervalSec == 0)
    }
}
