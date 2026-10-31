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
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}

/**
 * 令牌的结构共享与引用计数（`doc/04-rete-network.md` §5，用例 R-14）。
 *
 * 令牌只沿父链保存 `(parent, handle, binding)`，不复制绑定表；相等性只看
 * `(parent, handle)`，同一路径的同一事实天然去重。引用计数归零时递归释放父链。
 */
@Test
class Token_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func handle(id: Int64): FactHandle {
        FactHandle("default", id, "Order")
    }

    /** 子令牌只持有父链引用：绑定表沿链展开，不复制成 map。 */
    @TestCase
    public func childSharesParentChainInsteadOfCopyingBindings(): Unit {
        let first = order(1)
        let second = order(2)
        let parent = Token.root(handle(1), "o", first)
        let child = Token.child(parent, handle(2), "u", second)

        @Expect(child.parent.getOrThrow(), parent)
        @Assert(child.bindings().size(), 2)
        @Assert(child.bindings().get("o").getOrThrow().get("amount").getOrThrow() as Int64, 1)
        @Assert(child.bindings().get("u").getOrThrow().get("amount").getOrThrow() as Int64, 2)

        let grandChild = Token.child(child, handle(3), "z", order(3))
        @Expect(grandChild.parent.getOrThrow(), child)
        @Assert(grandChild.bindings().size(), 3)
    }

    /** 相等性只看 `(parent, handle)`，与绑定名、事实对象无关。 */
    @TestCase
    public func equalityIsParentAndHandle(): Unit {
        let parent = Token.root(handle(1), "o", order(1))
        let left = Token.child(parent, handle(2), "u", order(2))
        let samePath = Token.child(parent, handle(2), "other", order(99))
        let otherHandle = Token.child(parent, handle(3), "u", order(3))

        @Expect(left == samePath, true)
        @Assert(left.hashCode(), samePath.hashCode())
        @Expect(left == otherHandle, false)
    }

    /** 每个子令牌创建时父令牌 +1；子令牌归零时父令牌 -1，归零即释放。 */
    @TestCase
    public func retainAndReleaseCascadeToParent(): Unit {
        let parent = Token.root(handle(1), "o", order(1))
        let first = Token.child(parent, handle(2), "u", order(2))
        let second = Token.child(parent, handle(3), "v", order(3))
        @Assert(parent.refCount, 2)
        @Expect(parent.isReleased(), false)

        // 第一个下游撤回：令牌仍在，只是引用减少
        @Expect(first.release(), true)
        @Assert(parent.refCount, 1)
        @Expect(parent.isReleased(), false)

        // 第二个下游撤回：引用归零并递归释放父链
        @Expect(second.release(), true)
        @Assert(parent.refCount, 0)
        @Expect(parent.isReleased(), true)
    }

    /** 重复 release 不重复递减，也不重复触发父链释放。 */
    @TestCase
    public func releaseIsIdempotentAtZero(): Unit {
        let parent = Token.root(handle(1), "o", order(1))
        let child = Token.child(parent, handle(2), "u", order(2))
        @Expect(child.release(), true)
        @Expect(child.release(), false)
        @Assert(parent.refCount, 0)
        @Expect(parent.isReleased(), true)
    }
}
