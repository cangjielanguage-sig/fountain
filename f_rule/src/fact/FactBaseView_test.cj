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
package fountain::f_rule.fact

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * `FactBaseView` 的会话隔离与 fork 契约（`doc/02-fact-model.md` §6.7，用例 F-09/F-10）。
 *
 * 隔离键是二维的 `(factSpace, session)`：同一 `(space, session)` 返回同一视图，
 * 不同组合互不可见。`fork` 默认 `Isolated`，规则流默认 `Shared`。
 */
@Test
class FactBaseView_test {
    private func store(): FactBaseViewStore {
        let registry = FactSpaceRegistry()
        let space = registry.declare("orders")
        let _ = space.register(FactBase_test.orderSchema())
        FactBaseViewStore(registry)
    }

    private func fact(amount: Int64): TypedFact<SchemaOrder> {
        TypedFact(SchemaOrder("A", amount, 3), FactBase_test.orderSchema())
    }

    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** 同一 `(space, session)` 返回同一视图。 */
    @TestCase
    public func sameCombinationReturnsSameView(): Unit {
        let views = store()
        let first = views.view("orders", "A")
        let again = views.view("orders", "A")
        @Expect(refEq(first, again), true)

        let otherSession = views.view("orders", "B")
        @Expect(refEq(first, otherSession), false)
    }

    /** F-09：会话 A 的事实对会话 B 不可见。 */
    @TestCase
    public func sessionsAreIsolated(): Unit {
        let views = store()
        let a = views.view("orders", "A")
        let b = views.view("orders", "B")
        let handle = a.assert(fact(500))

        @Assert(a.scan("Order").size, 1)
        @Assert(b.scan("Order").size, 0)
        @Expect(b.get(handle).isNone(), true)
        @Expect(b.retract(handle), false)
    }

    /** 未声明空间抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func unknownSpaceRejected(): Unit {
        let views = store()
        @Expect(codeOf({ => let _ = views.view("users", "A") }), RuleErrorCode.UNKNOWN_FACT_SPACE)
    }

    /** F-10：默认 `Isolated` 的 fork 在提交前对父不可见，提交后合并。 */
    @TestCase
    public func isolatedForkCommitsToParent(): Unit {
        let views = store()
        let parent = views.view("orders", "A")
        let child = parent.fork("child")

        @Expect(child.level, IsolationLevel.Isolated)
        let _ = child.assert(fact(100))
        let _ = child.assert(fact(200))
        @Assert(child.scan("Order").size, 2)
        @Assert(parent.scan("Order").size, 0)

        child.commitToParent()
        @Assert(parent.scan("Order").size, 2)

        // 子视图的独立撤销不影响父视图
        let handles = child.scan("Order")
        @Expect(child.retract(handles[0]), true)
        @Assert(child.scan("Order").size, 1)
        @Assert(parent.scan("Order").size, 2)
    }

    /** `Shared` 视图直接读写父事实库，不需要 commit。 */
    @TestCase
    public func sharedForkSeesParentImmediately(): Unit {
        let views = store()
        let parent = views.view("orders", "A")
        let child = parent.fork("child", level: IsolationLevel.Shared)

        let handle = child.assert(fact(100))
        @Assert(parent.scan("Order").size, 1)
        @Expect(parent.get(handle).isSome(), true)

        @Expect(child.retract(handle), true)
        @Assert(parent.scan("Order").size, 0)
    }

    /** F-17/F-18：`copyTo` 在目标空间生成新句柄，两库独立撤销。 */
    @TestCase
    public func copyToMaterializesIndependentFact(): Unit {
        let registry = FactSpaceRegistry()
        let orders = registry.declare("orders")
        let mirror = registry.declare("mirror")
        let _ = orders.register(FactBase_test.orderSchema())
        let _ = mirror.register(FactBase_test.orderSchema())
        let views = FactBaseViewStore(registry)

        let source = views.view("orders", "A")
        let target = views.view("mirror", "A")
        let order = SchemaOrder("A", 500, 3)
        let sourceHandle = source.assert(TypedFact(order, FactBase_test.orderSchema()))

        let targetHandle = source.copyTo(target, TypedFact(order, FactBase_test.orderSchema()))
        @Assert(targetHandle.space, "mirror")
        @Expect(targetHandle == sourceHandle, false)
        @Assert(target.scan("Order").size, 1)

        // F-18：撤销源事实不影响目标
        @Expect(source.retract(sourceHandle), true)
        @Assert(source.scan("Order").size, 0)
        @Assert(target.scan("Order").size, 1)

        // 目标侧是字段快照：源对象后续变化不可见
        order.amount = 900
        match (target.get(targetHandle).getOrThrow().get("amount")) {
            case Some(value) =>
                match (value) {
                    case amount: Int64 => @Assert(amount, 500)
                    case _ => @Expect("amount type", "Int64")
                }
            case None => @Expect("amount present", "Some")
        }
    }

    /** 释放会话后重新取视图是新的空视图。 */
    @TestCase
    public func releaseDropsSessionFacts(): Unit {
        let views = store()
        let first = views.view("orders", "A")
        let _ = first.assert(fact(100))
        @Assert(first.scan("Order").size, 1)

        views.release("A")
        let again = views.view("orders", "A")
        @Expect(refEq(first, again), false)
        @Assert(again.scan("Order").size, 0)
    }
}
