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
package fountain::f_rule.rete

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.fact.{DynamicFact, FactHandle, ValueKey}

/**
 * alpha memory 的集合与等值索引契约（`doc/04-rete-network.md` §7.1，用例 R-01/R-10/R-12）。
 */
@Test
class AlphaMemory_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func handle(id: Int64): FactHandle {
        FactHandle("default", id, "Order")
    }

    /** 同一句柄重复加入是同一次加入（幂等）。 */
    @TestCase
    public func addIsIdempotent(): Unit {
        let memory = AlphaMemory(1)
        @Expect(memory.add(handle(1), order(10)), true)
        @Expect(memory.add(handle(1), order(10)), false)
        @Assert(memory.size(), 1)
    }

    /** 等值探测命中全部同值事实。 */
    @TestCase
    public func probeHitsEveryEqualFact(): Unit {
        let memory = AlphaMemory(1)
        memory.add(handle(1), order(200))
        memory.add(handle(2), order(300))
        memory.add(handle(3), order(300))

        let hit = memory.probe("amount", ValueKey.of(300))
        @Assert(hit.size, 2)
        let seen = hit[0] == handle(2) || hit[0] == handle(3)
        @Expect(seen, true)
    }

    /** 删除后索引同步失效：再探测不到，size 归零。 */
    @TestCase
    public func removeUpdatesIndex(): Unit {
        let memory = AlphaMemory(1)
        let target = handle(2)
        memory.add(handle(1), order(200))
        memory.add(target, order(300))
        @Assert(memory.probe("amount", ValueKey.of(300)).size, 1)

        @Expect(memory.remove(target), true)
        @Expect(memory.remove(target), false)
        @Assert(memory.size(), 1)
        @Assert(memory.probe("amount", ValueKey.of(300)).size, 0)
        @Assert(memory.all().size, 1)
    }

    /** 未建立索引的字段也能探测（首次探测时补建）。 */
    @TestCase
    public func probeBuildsIndexOnDemand(): Unit {
        let memory = AlphaMemory(1)
        memory.add(handle(1), order(200))
        memory.add(handle(2), order(300))
        @Assert(memory.probe("amount", ValueKey.of(200)).size, 1)
        memory.add(handle(3), order(200))
        // 索引已建立，后续插入必须同步进索引
        @Assert(memory.probe("amount", ValueKey.of(200)).size, 2)
    }
}
