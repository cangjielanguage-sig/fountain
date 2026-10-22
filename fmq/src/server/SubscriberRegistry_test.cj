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

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_mq.base.{MQErrorCode, MQFilter}

@Test
class SubscriberRegistryTest {
    private static func info(id: String, topic: String, group: String, tags!: Array<String> = []): MQSubscriptionInfo {
        MQSubscriptionInfo(id, topic, group, tags, MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER)
    }

    /** 每次登记代次自增；旧快照的注销不得删掉新订阅（A60）。 */
    @TestCase
    public func generationGuardsReSubscription(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1"))
        let firstGeneration = registry.of("s1").getOrThrow().generation
        // 同一 id 重订阅
        registry.register(info("s1", "/a", "g1"))
        let secondGeneration = registry.of("s1").getOrThrow().generation
        @Assert(secondGeneration > firstGeneration)
        // 巡检携带旧代次：拒绝
        @Assert(registry.unregister("s1", generation: firstGeneration).code ==
            MQErrorCode.SUBSCRIBE_NOT_EXIST)
        @Assert(registry.of("s1").isSome())
        // 当前代次可以删
        @Assert(registry.unregister("s1", generation: secondGeneration).code == 0)
        @Assert(registry.of("s1").isNone())
    }

    /** 断链订阅不算活跃：否则其名下记录永远不回组（A55）。 */
    @TestCase
    public func activeIdsSkipDisconnectedSubscriptions(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1"))
        let dead = MQSubscriptionInfo("s2", "/a", "g1", [], MQFilter.compile(""), false, EMPTY_SOCKET_BUFFER,
            alive: {=> false})
        registry.register(dead)
        let active = registry.activeIds("/a", "g1")
        @Assert(active == ["s1"])
        @Assert(registry.byGroupOf("/a", "g1").size == 2)
    }

    @TestCase
    public func registerAndQuery(): Unit {
        let registry = SubscriberRegistry()
        @Assert(registry.register(info("s1", "/a", "g1")).code == 0)
        @Assert(registry.register(info("s2", "/a", "g1")).code == 0)
        @Assert(registry.register(info("s3", "/a", "g2")).code == 0)
        @Assert(registry.infos().size == 3)
        @Assert(registry.of("s1").getOrThrow().topic == "/a")
        @Assert(registry.byGroupOf("/a", "g1").size == 2)
        @Assert(registry.byGroupOf("/a", "g2").size == 1)
        @Assert(registry.byGroupOf("/a", "none").size == 0)
        @Assert(registry.activeIds("/a", "g1").size == 2)
    }

    @TestCase
    public func registerIsIdempotent(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1", tags: ["x"]))
        registry.register(info("s1", "/a", "g1", tags: ["y"]))
        @Assert(registry.infos().size == 1)
        @Assert(registry.of("s1").getOrThrow().tags == ["y"])
        @Assert(registry.byGroupOf("/a", "g1").size == 1)
    }

    @TestCase
    public func unregisterRemovesFromBothIndexes(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1"))
        @Assert(registry.unregister("s1").code == 0)
        @Assert(registry.of("s1").isNone())
        @Assert(registry.byGroupOf("/a", "g1").size == 0)
        // 未知 id
        @Assert(registry.unregister("s1").code == MQErrorCode.SUBSCRIBE_NOT_EXIST)
    }

    @TestCase
    public func groupsAreIsolated(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1"))
        registry.register(info("s2", "/a", "g2"))
        registry.removeByGroup("/a", "g1")
        @Assert(registry.of("s1").isNone())
        @Assert(registry.of("s2").isSome())
        @Assert(registry.byGroupOf("/a", "g2").size == 1)
    }

    @TestCase
    public func removeByTopicClearsAllGroups(): Unit {
        let registry = SubscriberRegistry()
        registry.register(info("s1", "/a", "g1"))
        registry.register(info("s2", "/a", "g2"))
        registry.register(info("s3", "/b", "g1"))
        registry.removeByTopic("/a")
        @Assert(registry.infos().size == 1)
        @Assert(registry.of("s3").isSome())
        @Assert(registry.byGroupOf("/b", "g1").size == 1)
    }

    @TestCase
    public func concurrentRegisterAndQuery(): Unit {
        let registry = SubscriberRegistry()
        let done = AtomicInt64(0)
        for (worker in 0..4) {
            spawn {
                for (i in 0..50) {
                    let id = "s-${worker}-${i}"
                    registry.register(info(id, "/a", "g${i % 3}"))
                    registry.of(id)
                }
                done.fetchAdd(1)
            }
        }
        var waited = 0
        while (done.load() < 4 && waited < 300) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(done.load() == 4)
        @Assert(registry.infos().size == 200)
    }
}
