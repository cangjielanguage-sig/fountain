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
public class DeregisterCacheTest {
    @TestCase
    public func testDeregisterClearsCompiledPatternsInSync(): Unit {
        let cm = ConsumerMatcher()

        // 注册 Glob 模式消费者
        let reg = ConsumerRegistration(
            consumerId: "g-consumer", groupId: "g-group",
            matchModeStr: "Glob:/orders/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 触发 compiledPatterns 缓存
        @Assert(cm.matchTopic("/orders/123").size == 1)

        // 注销后 match 应返回 0
        cm.deregister("g-group", "g-consumer")
        @Assert(cm.matchTopic("/orders/123").size == 0)
    }

    @TestCase
    public func testDeregisterWithConcurrentMatch(): Unit {
        let cm = ConsumerMatcher()

        // 注册 Glob 消费者
        let reg = ConsumerRegistration(
            consumerId: "rr-consumer", groupId: "rr-group",
            matchModeStr: "Glob:/api/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        cm.register(reg)

        // 并发 deregister + matchTopic
        let f1 = spawn { cm.deregister("rr-group", "rr-consumer"); true }
        let f2 = spawn { cm.matchTopic("/api/v1").size >= 0; true }
        let f3 = spawn { cm.matchTopic("/api/v2").size >= 0; true }
        f1.get()
        f2.get()
        f3.get()
        // 不抛异常就算通过
        @Assert(cm.matchTopic("/api/v1").size == 0)
    }
}
