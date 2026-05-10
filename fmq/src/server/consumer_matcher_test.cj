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

/**
 * ConsumerMatcher 单元测试：验证注册、注销和匹配功能。
 */
@Test
public class ConsumerMatcherUnsubscribeTest {
    @TestCase
    public func testRegisterAndDeregister(): Unit {
        let matcher = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "test-consumer-1", groupId: "test-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg)

        // 注册后应能匹配到消费者
        let result1 = matcher.matchTopic("/test")
        @Assert(result1.size == 1)

        // 注销后不应再匹配
        matcher.deregister("test-group", "test-consumer-1")
        let result2 = matcher.matchTopic("/test")
        @Assert(result2.size == 0)
    }

    @TestCase
    public func testUnsubscribeGlob(): Unit {
        let matcher = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "/orders", groupId: "/orders",
            matchModeStr: "Glob:/orders/*",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg)

        // 注册后应能匹配到 topic=/orders/create
        let result1 = matcher.matchTopic("/orders/create")
        @Assert(result1.size == 1)

        // 模拟 unsubscribe：deregister(topic, topic)
        matcher.deregister("/orders", "/orders")
        let result2 = matcher.matchTopic("/orders/create")
        @Assert(result2.size == 0)
    }

    @TestCase
    public func testDeregisterWithSeparateGroupAndConsumer(): Unit {
        let matcher = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "consumer-A", groupId: "my-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg)

        // 验证注册成功
        @Assert(matcher.matchTopic("/test").size == 1)

        // 用正确的 groupId + consumerId 注销 — 应该成功
        let ok = matcher.deregister("my-group", "consumer-A")
        @Assert(ok)
        @Assert(matcher.matchTopic("/test").size == 0)
    }

    @TestCase
    public func testDeregisterWrongGroupIdReturnsFalse(): Unit {
        let matcher = ConsumerMatcher()
        let reg = ConsumerRegistration(
            consumerId: "consumer-B", groupId: "group-B",
            matchModeStr: "Prefix:/b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg)
        @Assert(matcher.matchTopic("/b/1").size == 1)

        // 用错误的 groupId 注销 — 应返回 false，注册应保持不变
        let ok = matcher.deregister("wrong-group", "consumer-B")
        @Assert(!ok)
        @Assert(matcher.matchTopic("/b/1").size == 1)
    }
}
