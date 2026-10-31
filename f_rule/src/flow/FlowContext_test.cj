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
package fountain::f_rule.flow

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact, FactSpaceRegistry, FieldType}

/** 测试用归档器：只记录归档到的事实数量。 */
class CountingArchiver <: FactArchiver {
    public var count: Int64 = 0

    public func archive(session: String, space: String, fact: Fact): Unit {
        count += 1
    }
}

/**
 * `FlowContext` 的会话上下文契约（`doc/06-flow-orchestration.md` §5.1、§5.2）。
 *
 * 覆盖：ThreadLocal 绑定、多空间惰性视图、同空间同视图、未声明空间、
 * 未绑定报错、release 的 Discard/Archive/Retain。
 */
@Test
class FlowContext_test {
    private func registry(): FactSpaceRegistry {
        let registry = FactSpaceRegistry()
        let _ = registry.declare("default").registerDynamic("D", [("value", FieldType.Number)])
        let _ = registry.declare("orders").registerDynamic("Order", [("amount", FieldType.Number)])
        let _ = registry.declare("users").registerDynamic("User", [("level", FieldType.Text)])
        registry
    }

    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
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

    /** `create` 建立上下文；`bind`/`current`/`unbind` 走 ThreadLocal。 */
    @TestCase
    public func bindAndUnbindTrackCurrentContext(): Unit {
        let ruleSetId = "flow-ctx-bind"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        @Expect(ctx.session, "s1")
        @Expect(ctx.ruleSetId, ruleSetId)

        FlowContext.bind(ctx)
        @Expect(refEq(FlowContext.current(), ctx), true)
        FlowContext.unbind()
        @Expect(codeOf({ => FlowContext.current() }), RuleErrorCode.NO_CONTEXT)

        let attached = FlowContext.attach(RuleEnvelope(session: "s1", ruleSetId: ruleSetId, payload: "x"))
        @Expect(refEq(FlowContext.current(), attached), true)
        FlowContext.detach()
        @Expect(codeOf({ => FlowContext.current() }), RuleErrorCode.NO_CONTEXT)
    }

    /** 同一 `(ruleSetId, session)` 复用同一个上下文实例。 */
    @TestCase
    public func sameSessionReusesContext(): Unit {
        let ruleSetId = "flow-ctx-reuse"
        FlowContext.configure(ruleSetId, registry())
        let first = FlowContext.create(ruleSetId, "s1")
        let second = FlowContext.create(ruleSetId, "s1")
        @Expect(refEq(first, second), true)
    }

    /** 视图惰性创建；同一空间两次取到同一视图，`spaces()` 按首次访问顺序。 */
    @TestCase
    public func viewsAreLazyAndOrdered(): Unit {
        let ruleSetId = "flow-ctx-spaces"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        @Expect(ctx.spaces().size, 0)

        let orders1 = ctx.factsOf("orders")
        let users = ctx.factsOf("users")
        let orders2 = ctx.factsOf("orders")
        @Expect(refEq(orders1, orders2), true)
        @Expect(orders1.space, "orders")
        @Expect(users.space, "users")
        let spaces = ctx.spaces()
        @Expect(spaces.size, 2)
        @Expect(spaces[0], "orders")
        @Expect(spaces[1], "users")
    }

    /** 缺省空间的 `facts` 属性等价于 `factsOf("default")`。 */
    @TestCase
    public func defaultFactsUsesDefaultSpace(): Unit {
        let ruleSetId = "flow-ctx-default"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        @Expect(ctx.facts.space, "default")
        @Expect(ctx.spaces()[0], "default")
    }

    /** 未声明空间抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func unknownSpaceIsRejected(): Unit {
        let ruleSetId = "flow-ctx-unknown"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        @Expect(codeOf({ => ctx.factsOf("nope") }), RuleErrorCode.UNKNOWN_FACT_SPACE)
    }

    /** `Discard`（缺省）清空该会话的全部空间视图。 */
    @TestCase
    public func releaseDiscardsSessionFacts(): Unit {
        let ruleSetId = "flow-ctx-discard"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        let _ = ctx.factsOf("orders").assert(order(200))
        @Expect(ctx.factsOf("orders").size(), 1)

        FlowContext.release("s1")
        let reopened = FlowContext.create(ruleSetId, "s1")
        @Expect(reopened.factsOf("orders").size(), 0)
    }

    /** `Archive` 先交给归档器，再丢弃。 */
    @TestCase
    public func releaseArchivesSessionFacts(): Unit {
        let ruleSetId = "flow-ctx-archive"
        FlowContext.configure(ruleSetId, registry())
        let archiver = CountingArchiver()
        FlowContext.setArchiver(archiver)
        let ctx = FlowContext.create(ruleSetId, "s1")
        let _ = ctx.factsOf("orders").assert(order(300))

        FlowContext.release("s1", policy: Release.Archive)
        @Expect(archiver.count, 1)
        let reopened = FlowContext.create(ruleSetId, "s1")
        @Expect(reopened.factsOf("orders").size(), 0)
        FlowContext.setArchiver(None<FactArchiver>)
    }

    /** `Retain` 保留会话上下文，重入仍能看到原事实。 */
    @TestCase
    public func releaseRetainKeepsSessionFacts(): Unit {
        let ruleSetId = "flow-ctx-retain"
        FlowContext.configure(ruleSetId, registry())
        let ctx = FlowContext.create(ruleSetId, "s1")
        let _ = ctx.factsOf("orders").assert(order(400))

        FlowContext.release("s1", policy: Release.Retain)
        let reopened = FlowContext.create(ruleSetId, "s1")
        @Expect(refEq(reopened, ctx), true)
        @Expect(reopened.factsOf("orders").size(), 1)
    }
}
