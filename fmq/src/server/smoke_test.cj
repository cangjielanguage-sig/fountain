/*
 * 冒烟测试：验证服务端能正常启动。
 */
package fountain::fmq.server

import std.unittest.*
import std.unittest.testmacro.*

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
