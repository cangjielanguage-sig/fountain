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
package fountain::f_rule.agenda

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.Pattern
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.*
import fountain::f_rule.rule.Rule

/** 记录事实变更回调，验证动作上下文的传播契约。 */
class RecordingPropagation <: FactPropagation {
    private let asserts_: ArrayList<String>
    private let retracts_: ArrayList<String>
    private let updates_: ArrayList<String>

    RecordingPropagation() {
        this.asserts_ = ArrayList<String>()
        this.retracts_ = ArrayList<String>()
        this.updates_ = ArrayList<String>()
    }

    public func onAssert(space: String, handle: FactHandle, fact: Fact): Unit {
        let _ = handle
        let _ = fact
        asserts_.add(space)
    }

    public func onRetract(space: String, handle: FactHandle): Unit {
        let _ = handle
        retracts_.add(space)
    }

    public func onUpdate(space: String, handle: FactHandle, fact: Fact): Unit {
        let _ = handle
        let _ = fact
        updates_.add(space)
    }

    public func asserts(): Array<String> {
        asserts_.toArray()
    }

    public func retracts(): Array<String> {
        retracts_.toArray()
    }

    public func updates(): Array<String> {
        updates_.toArray()
    }
}

/**
 * 动作上下文（`doc/05-agenda-conflict-resolution.md` §7，F-17/F-18）。
 *
 * 覆盖：`fact(binding)` 解析、`assert`/`retract`/`update` 默认写回 `factSpace`、
 * 输出槽、`factIn` 只读、`copyTo` 生成新句柄且两库撤销互不影响。
 */
@Test
class ActionContext_test {
    private func dynamic(typeTag: String, values: Array<(String, Any)>): Fact {
        let fact = DynamicFact(typeTag)
        for ((name, value) in values) {
            fact.set(name, value)
        }
        fact
    }

    private func registry(): FactSpaceRegistry {
        let registry = FactSpaceRegistry()
        let orders = registry.declare("orders")
        let _ = orders.registerDynamic("Order", [("amount", FieldType.Number)])
        let users = registry.declare("users")
        let _ = users.registerDynamic("User", [("level", FieldType.Text)])
        // 跨空间物化要求目标空间也认识该类型（F-18）
        let _ = users.registerDynamic("Order", [("amount", FieldType.Number)])
        registry
    }

    private func setup(): (FactBaseViewStore, FactBaseView, FactHandle, Fact, Activation) {
        let views = FactBaseViewStore(registry())
        let orders = views.view("orders", "s1")
        let original = dynamic("Order", [("amount", 300)])
        let handle = orders.assert(original)
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = handle
        facts["o"] = original
        let rule = Rule.builder("R1")
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
            .build()
        let activation = Activation(rule, Bindings.of(handles, facts))
        (views, orders, handle, original, activation)
    }

    private func context(views: FactBaseViewStore, activation: Activation,
        outputs: HashMap<String, Any>, propagation: FactPropagation): SessionActionContext {
        SessionActionContext(activation, views.view(activation.factSpace, "s1"),
            { space: String => views.view(space, "s1") }, outputs, propagation: propagation)
    }

    /** `fact(binding)` 按绑定取事实。 */
    @TestCase
    public func factResolvesBinding(): Unit {
        let (views, _, _, original, activation) = setup()
        let ctx = context(views, activation, HashMap<String, Any>(), NoopPropagation())

        @Assert(ctx.factSpace, "orders")
        let _ = original
        match (ctx.fact("o")) {
            case Some(fact) => @Assert(fact.get("amount").getOrThrow() as Int64, 300)
            case None => @Fail("绑定 o 未解析")
        }
        @Expect(ctx.fact("missing").isNone(), true)
    }

    /** `assert` / `retract` / `update` 默认写回 `factSpace`，并触发传播回调。 */
    @TestCase
    public func mutationsTargetFactSpaceAndPropagate(): Unit {
        let (views, orders, handle, _, activation) = setup()
        let propagation = RecordingPropagation()
        let ctx = context(views, activation, HashMap<String, Any>(), propagation)

        let added = ctx.assert(dynamic("Order", [("amount", 10)]))
        @Assert(orders.size(), 2)
        @Assert(propagation.asserts().size, 1)
        @Assert(propagation.asserts()[0], "orders")

        let replacement = dynamic("Order", [("amount", 99)])
        ctx.update(handle, replacement)
        @Assert(propagation.updates().size, 1)
        @Assert(replacement.get("amount").getOrThrow() as Int64, 99)

        ctx.retract(added)
        @Assert(orders.size(), 1)
        @Assert(propagation.retracts().size, 1)
    }

    /** 输出槽：`set`/`get`/`outputs` 指向同一份本次执行结果。 */
    @TestCase
    public func outputSlotsAreShared(): Unit {
        let (views, _, _, _, activation) = setup()
        let outputs = HashMap<String, Any>()
        let ctx = context(views, activation, outputs, NoopPropagation())

        ctx.set("discount", 0.85)
        @Assert(ctx.get("discount").getOrThrow() as Float64, 0.85)
        @Assert(ctx.outputs().size, 1)
    }

    /** `factIn` 跨空间只读：本上下文不提供跨空间撤销。 */
    @TestCase
    public func factInReadsAnotherSpace(): Unit {
        let (views, _, _, _, activation) = setup()
        let user = views.view("users", "s1").assert(dynamic("User", [("level", "vip")]))
        let ctx = context(views, activation, HashMap<String, Any>(), NoopPropagation())

        match (ctx.factIn("users", user)) {
            case Some(fact) => @Assert(fact.get("level").getOrThrow() as String, "vip")
            case None => @Fail("users 空间事实未读到")
        }
        @Assert(views.view("users", "s1").size(), 1)
    }

    /** `copyTo` 物化到目标空间：新句柄，两边撤销互不影响（F-18）。 */
    @TestCase
    public func copyToMaterializesIndependentFact(): Unit {
        let (views, orders, handle, original, activation) = setup()
        let ctx = context(views, activation, HashMap<String, Any>(), NoopPropagation())

        let copied = ctx.copyTo("users", original)
        @Expect(copied == handle, false)
        @Assert(copied.space, "users")
        @Assert(views.view("users", "s1").size(), 1)

        @Expect(views.view("users", "s1").retract(copied), true)
        @Expect(views.view("orders", "s1").get(handle).isSome(), true)
        @Assert(orders.size(), 1)
    }

    /** 未声明空间抛 `UNKNOWN_FACT_SPACE`。 */
    @TestCase
    public func unknownSpaceIsRejected(): Unit {
        let (views, _, _, _, activation) = setup()
        let ctx = context(views, activation, HashMap<String, Any>(), NoopPropagation())
        var code = RuleErrorCode.CLOSED
        try {
            let _ = ctx.factIn("missing", FactHandle("missing", 1, "Order"))
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.UNKNOWN_FACT_SPACE)
    }
}
