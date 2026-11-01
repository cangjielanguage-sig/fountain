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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.agenda.{Activation, ActivationSink}
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.Rule

/** 终端节点的测试会话：只提供激活汇，不提供任何 memory。 */
class TerminalTestSession <: ReteSession {
    private let sink_: ActivationSink

    TerminalTestSession(sink: ActivationSink) {
        this.sink_ = sink
    }

    public prop sink: ActivationSink {
        get() {
            sink_
        }
    }

    public func alphaMemory(nodeId: Int64): AlphaMemory {
        throw Exception("TerminalTestSession 不提供 alpha memory")
    }

    public func betaMemory(nodeId: Int64): BetaMemory {
        throw Exception("TerminalTestSession 不提供 beta memory")
    }

    public func betaProductions(nodeId: Int64): BetaProductions {
        throw Exception("TerminalTestSession 不提供 beta productions")
    }

    public func recordAlphaHits(handle: FactHandle, hits: Array<AlphaNode>): Unit {
        // 单节点用例不经过根节点分发，不需要命中记录。
    }

    public func alphaHits(handle: FactHandle): ?Array<AlphaNode> {
        None
    }

    public func forgetAlphaHits(handle: FactHandle): Unit {
    }
}

/** 极简激活汇：只记录 add/remove 调用，验证终端只依赖 `ActivationSink`。 */
class PlainSink <: ActivationSink {
    private let items: ArrayList<Activation>

    PlainSink() {
        this.items = ArrayList<Activation>()
    }

    public func add(activation: Activation): Unit {
        items.add(activation)
    }

    public func remove(activation: Activation): Unit {
        var i = 0
        while (i < items.size) {
            if (items[i] == activation) {
                items.remove(at: i)
                return
            }
            i += 1
        }
    }

    public func size(): Int64 {
        items.size
    }

    public func first(): Activation {
        items[0]
    }
}

/**
 * 终端节点：令牌 → 激活（`doc/04-rete-network.md` §8、§12）。
 *
 * 终端只依赖 `ActivationSink`，不感知议程实现；`leftRetract` 用同一组绑定
 * 构造等价激活并交给 `remove`。
 */
@Test
class TerminalNode_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    /** 一个模式 + 两条约束 → specificity 3。 */
    private func rule(): Rule {
        Rule.builder("R1")
            .facts("orders")
            .addPattern(Pattern("Order", "o")
                .constrain("amount", Operator.Gt, 100)
                .constrain("amount", Operator.Lt, 500))
            .build()
    }

    private func token(): Token {
        let first = Token.root(FactHandle("default", 1, "Order"), "o", order(300))
        Token.child(first, FactHandle("default", 2, "Order"), "u", order(200))
    }

    /** 左激活展开绑定并产出激活。 */
    @TestCase
    public func leftActivateProducesActivation(): Unit {
        let sink = PlainSink()
        let session = TerminalTestSession(sink)
        let terminal = TerminalNode(100, rule())

        terminal.leftActivate(session, token())
        @Assert(sink.size(), 1)
        let activation = sink.first()
        @Assert(activation.ruleId, "R1")
        @Assert(activation.factSpace, "orders")
        @Assert(activation.specificity, 3)
        @Assert(activation.bindings.size(), 2)
        @Assert(activation.bindings.resolve("o").getOrThrow().get("amount").getOrThrow() as Int64, 300)
    }

    /** 左撤回移除等价激活。 */
    @TestCase
    public func leftRetractRemovesActivation(): Unit {
        let sink = PlainSink()
        let session = TerminalTestSession(sink)
        let terminal = TerminalNode(100, rule())

        let item = token()
        terminal.leftActivate(session, item)
        @Assert(sink.size(), 1)
        terminal.leftRetract(session, item)
        @Assert(sink.size(), 0)
    }
}
