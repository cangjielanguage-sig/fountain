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
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * 冒烟测试：验证服务端能正常启动和停止。
 */
@Test
public class SmokeTest {
    @TestCase
    public func testServerStarts(): Unit {
        let port: UInt16 = 18001u16
        let server = MqServer(bindPort: port)
        let executor = CommandExecutor(
            TopicManager(testConfig()), QueueManager(testConfig()),
            DeliveryManager(testConfig()), ConsumerMatcher(),
            ReplicationManager(testConfig()))
        let future = server.start({ msg => executor.execute(msg) })
        sleep(Duration.second)
        @Assert(!server.isClosed())
        server.close()
        @Assert(server.isClosed())
    }

    private static func testConfig(): MqConfig {
        MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
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
