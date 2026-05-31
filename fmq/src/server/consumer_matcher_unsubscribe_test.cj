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

    @TestCase
    public func testDuplicateRegisterNoDuplicates(): Unit {
        let matcher = ConsumerMatcher()
        let reg1 = ConsumerRegistration(
            consumerId: "dup-consumer", groupId: "dup-group",
            matchModeStr: "Exact:/dup",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg1)

        // 相同 consumerId 再次注册
        let reg2 = ConsumerRegistration(
            consumerId: "dup-consumer", groupId: "dup-group",
            matchModeStr: "Exact:/dup",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg2)

        // matchTopic 应只匹配到一个消费者
        @Assert(matcher.matchTopic("/dup").size == 1)

        // deregister 一次后应完全清空
        matcher.deregister("dup-group", "dup-consumer")
        @Assert(matcher.matchTopic("/dup").size == 0)
    }

    /**
     * P2-4: 验证 deregister 后 roundRobinIndex 被修正，不导致 out-of-bounds 崩溃。
     * 注册两个同组消费者，matchTopic 推进 roundRobinIndex，deregister 一个后
     * roundRobinIndex 应修正为有效索引，再次 matchTopic 不崩溃。
     */
    @TestCase
    public func testDeregisterRoundRobinIndexFixed(): Unit {
        let matcher = ConsumerMatcher()
        let reg1 = ConsumerRegistration(
            consumerId: "rr-c1", groupId: "rr-group",
            matchModeStr: "Exact:/rr-fix",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let reg2 = ConsumerRegistration(
            consumerId: "rr-c2", groupId: "rr-group",
            matchModeStr: "Exact:/rr-fix",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg1)
        matcher.register(reg2)

        // 调用多次 matchTopic 推进 roundRobinIndex
        for (_ in 0..10) {
            let result = matcher.matchTopic("/rr-fix")
            @Assert(result.size == 1)
        }

        // deregister 一个消费者 → roundRobinIndex 应被修正
        matcher.deregister("rr-group", "rr-c1")

        // 再次 matchTopic 不应 out-of-bounds
        for (_ in 0..10) {
            let result = matcher.matchTopic("/rr-fix")
            @Assert(result.size == 1)
            if (let Some(consumerId) <- result.get("rr-group")) {
                @Assert(consumerId == "rr-c2")
            }
        }
    }

    @TestCase
    public func testDuplicateRegisterDifferentConsumerId(): Unit {
        let matcher = ConsumerMatcher()
        let reg1 = ConsumerRegistration(
            consumerId: "consumer-X", groupId: "same-group",
            matchModeStr: "Exact:/multi",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg1)

        let reg2 = ConsumerRegistration(
            consumerId: "consumer-Y", groupId: "same-group",
            matchModeStr: "Exact:/multi",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg2)

        // 同一组不同 consumerId → matchTopic 按 group 去重，size=1
        @Assert(matcher.matchTopic("/multi").size == 1)

        // 分别注销
        matcher.deregister("same-group", "consumer-X")
        @Assert(matcher.matchTopic("/multi").size == 1)
        matcher.deregister("same-group", "consumer-Y")
        @Assert(matcher.matchTopic("/multi").size == 0)
    }

    @TestCase
    public func testConcurrentMatchRoundRobin(): Unit {
        let matcher = ConsumerMatcher()
        let reg1 = ConsumerRegistration(
            consumerId: "rr-A", groupId: "rr-group",
            matchModeStr: "Exact:/rr",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let reg2 = ConsumerRegistration(
            consumerId: "rr-B", groupId: "rr-group",
            matchModeStr: "Exact:/rr",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(reg1)
        matcher.register(reg2)

        // 并发调用 matchTopic，验证没有丢失更新
        let futures = ArrayList<Future<HashMap<String, String>>>()
        for (_ in 0..20) {
            futures.add(spawn { matcher.matchTopic("/rr") })
        }
        var aCount: Int64 = 0
        var bCount: Int64 = 0
        for (f in futures) {
            let result = f.get()
            if (let Some(consumerId) <- result.get("rr-group")) {
                if (consumerId == "rr-A") { aCount += 1 }
                else if (consumerId == "rr-B") { bCount += 1 }
            }
        }
        // 20 次调用，每个消费者大约应分到 10 次（允许微小偏差）
        @Assert(aCount > 0 && bCount > 0)
        // 分布式计数之和应为 20
        @Assert(aCount + bCount == 20)
    }

    /**
     * P2-2: deregister 修正 roundRobinIndex 应使用组内消费者数，而非全局 registrations.size。
     * 场景：group-A 有 2 消费者，group-B 有 3 消费者（共 5）。matchTopic 推进 group-A 的
     * roundRobinIndex 后 deregister 一个 group-A 消费者，roundRobinIndex 应以 group-A 剩余 1 为模，
     * 而非全局剩余 4 为模。用 groupCount=4 会导致 idx % 4 ≈ idx % 1（因为 idx < 4 且 idx % 4
     * 仍然合法），但语义错误在更复杂场景下会暴露（如 groupCount=1 且 idx > 1 时 idx % 错误基数
     * 导致非 0 结果，下一轮 matchTopic 使用错误索引）。
     *
     * 本测试用 group-A:2 消费者 + group-B:3 消费者验证 deregister 后不被 OutOfBounds 干扰。
     */
    @TestCase
    public func testDeregisterRRWithMultipleGroups(): Unit {
        let matcher = ConsumerMatcher()
        // group-A: 2 consumers
        let ra1 = ConsumerRegistration(
            consumerId: "a1", groupId: "group-A",
            matchModeStr: "Exact:/topic-a",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let ra2 = ConsumerRegistration(
            consumerId: "a2", groupId: "group-A",
            matchModeStr: "Exact:/topic-a",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        // group-B: 3 consumers (dilute registrations.size)
        let rb1 = ConsumerRegistration(
            consumerId: "b1", groupId: "group-B",
            matchModeStr: "Exact:/topic-b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let rb2 = ConsumerRegistration(
            consumerId: "b2", groupId: "group-B",
            matchModeStr: "Exact:/topic-b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let rb3 = ConsumerRegistration(
            consumerId: "b3", groupId: "group-B",
            matchModeStr: "Exact:/topic-b",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(ra1)
        matcher.register(ra2)
        matcher.register(rb1)
        matcher.register(rb2)
        matcher.register(rb3)

        // 多次 matchTopic 推进 group-A 的 RR 索引
        for (_ in 0..10) {
            let result = matcher.matchTopic("/topic-a")
            @Assert(result.size == 1)
        }

        // deregister a1 → 旧代码用 registrations.size=5，
        // 新代码用 group-A count=2；用旧模数 5 会把 idx 缩减到 [0,4]，
        // 而新的 idx % 1 = 0，结果不同但都合法。
        // 关键验证：deregister 后 matchTopic 不崩溃。
        matcher.deregister("group-A", "a1")

        for (_ in 0..5) {
            let result = matcher.matchTopic("/topic-a")
            @Assert(result.size == 1)
            if (let Some(consumerId) <- result.get("group-A")) {
                @Assert(consumerId == "a2")
            }
        }
    }
}
