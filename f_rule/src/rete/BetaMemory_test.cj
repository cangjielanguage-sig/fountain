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
import fountain::f_rule.condition.{JoinConstraint, Operator}
import fountain::f_rule.fact.{DynamicFact, FactHandle, ValueKey}

/**
 * beta memory 的令牌集合、join 索引与引用计数（`doc/04-rete-network.md` §5、§7.2）。
 */
@Test
class BetaMemory_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func token(binding: String, amount: Int64, id: Int64): Token {
        Token.root(FactHandle("default", id, "Order"), binding, order(amount))
    }

    /** 同一令牌重复加入幂等；删除后再次删除返回 false。 */
    @TestCase
    public func addIsIdempotentAndRemoveIsExact(): Unit {
        let memory = BetaMemory(1)
        let item = token("o", 10, 1)
        @Expect(memory.add(item), true)
        @Expect(memory.add(item), false)
        @Assert(memory.size(), 1)
        @Expect(memory.remove(item), true)
        @Expect(memory.remove(item), false)
        @Assert(memory.size(), 0)
    }

    /** 加入即持有引用，删除即释放；归零时释放父链。 */
    @TestCase
    public func addRetainsAndRemoveReleases(): Unit {
        let memory = BetaMemory(1)
        let parent = token("o", 10, 1)
        let child = Token.child(parent, FactHandle("default", 2, "Order"), "u", order(20))
        @Expect(memory.add(child), true)
        @Assert(child.refCount, 1)
        @Expect(memory.remove(child), true)
        @Assert(child.refCount, 0)
        @Expect(child.isReleased(), true)
        @Expect(parent.isReleased(), true)
    }

    /** join 索引按 `binding.field` 懒建，同值全部命中。 */
    @TestCase
    public func joinIndexIsBuiltOnDemand(): Unit {
        let memory = BetaMemory(1)
        memory.add(token("o", 10, 1))
        memory.add(token("o", 10, 2))
        memory.add(token("o", 20, 3))
        @Assert(memory.probe("o.amount", ValueKey.of(10)).size, 2)
        @Assert(memory.select("o.amount", Operator.Ge, ValueKey.of(10)).size, 3)
    }

    /** 右侧事实进入时，用左侧 join 索引取候选令牌。 */
    @TestCase
    public func probeByJoinUsesLeftIndex(): Unit {
        let memory = BetaMemory(1)
        memory.add(token("o", 10, 1))
        memory.add(token("o", 20, 2))
        let joins = [JoinConstraint("o", "amount", Operator.Eq, "u", "amount")]
        let hit = memory.probeByJoin(joins, order(20), "u")
        @Assert(hit.size, 1)
        @Assert(hit[0].binding, "o")
    }

    /** 无可用索引时回退全扫，保证语义完整。 */
    @TestCase
    public func probeByJoinFallsBackToAll(): Unit {
        let memory = BetaMemory(1)
        memory.add(token("o", 10, 1))
        memory.add(token("o", 20, 2))
        let joins = [JoinConstraint("o", "code", Operator.Contains, "u", "code")]
        @Assert(memory.probeByJoin(joins, order(20), "u").size, 2)
    }
}
