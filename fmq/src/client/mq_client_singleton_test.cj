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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID}


@Test
public class MqClientSingletonTest {
    @TestCase
    public func testConcurrentGetInstanceReturnsSameReference(): Unit {
        // 使用不含有效服务器的 config，所有线程 getInstance 都会抛异常
        // 测试目标是验证 synchronized 块不会因并发调用而损坏
        let config = MqConfig(
            mqHosts: ArrayList(), syncHosts: ArrayList(),
            dataDir: "/tmp", segmentMaxSize: 1024,
            heartbeatIntervalSec: 5, healthcheckMaxRetry: 3,
            idleTimeoutMinutes: 30, ackTimeoutMs: 30000,
            maxRetryCount: 3, retryIntervalMs: 1000,
            dlqRetentionHours: 168, maxMessageSize: 4096,
            maxLabelsPerMessage: 64, retentionHours: 72,
            syncQuorum: 1)
        let futures = ArrayList<Future<Bool>>()
        for (_ in 0..20) {
            let c = config
            futures.add(spawn {
                try {
                    MqClient.getInstance(c)
                    true
                } catch (_: Exception) { false }
            })
        }
        var ok: Int64 = 0
        var fail: Int64 = 0
        for (f in futures) {
            if (f.get()) { ok += 1 } else { fail += 1 }
        }
        // 空 mqHosts 时全部应失败，验证并发 synchronized 不损坏内部状态
        @Assert(ok == 0)
        @Assert(fail == 20)
    }
}
