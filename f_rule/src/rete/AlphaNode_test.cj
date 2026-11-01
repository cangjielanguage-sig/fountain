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

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.agenda.ActivationSink
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle, ValueKey}

/** alpha 网络的测试会话：只提供 memory 表与激活汇。 */
class AlphaTestSession <: ReteSession {
    private let sink_: ActivationSink
    private let alphaMems: HashMap<Int64, AlphaMemory>
    private let productions: HashMap<Int64, BetaProductions>

    AlphaTestSession(sink: ActivationSink) {
        this.sink_ = sink
        this.alphaMems = HashMap<Int64, AlphaMemory>()
        this.productions = HashMap<Int64, BetaProductions>()
    }

    public prop sink: ActivationSink {
        get() {
            sink_
        }
    }

    public func alphaMemory(nodeId: Int64): AlphaMemory {
        match (alphaMems.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = AlphaMemory(nodeId)
                alphaMems[nodeId] = created
                created
        }
    }

    public func memoryOf(nodeId: Int64): AlphaMemory {
        alphaMemory(nodeId)
    }

    public func betaMemory(_: Int64): BetaMemory {
        throw Exception("AlphaTestSession 不提供 beta memory")
    }

    public func betaProductions(nodeId: Int64): BetaProductions {
        match (productions.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = BetaProductions()
                productions[nodeId] = created
                created
        }
    }

    public func recordAlphaHits(_: FactHandle, _: Array<AlphaNode>): Unit {
        // 单节点用例不经过根节点分发，不需要命中记录。
    }

    public func alphaHits(_: FactHandle): ?Array<AlphaNode> {
        None
    }

    public func forgetAlphaHits(_: FactHandle): Unit {
    }
}

/** 记录右侧激活次数的下游 join。 */
class CountingRightSink <: RightSink {
    public var activated: Int64 = 0
    public var retracted: Int64 = 0

    public func rightActivate(_: ReteSession, _: FactHandle, _: Fact): Unit {
        activated += 1
    }

    public func rightRetract(_: ReteSession, _: FactHandle): Unit {
        retracted += 1
    }
}

/** 记录左侧令牌数量的终端/下游 join。 */
class CountingLeftSink <: TokenSink {
    public var activated: Int64 = 0
    public var retracted: Int64 = 0
    public var lastName: String = ""

    public func leftActivate(_: ReteSession, token: Token): Unit {
        activated += 1
        lastName = token.binding
    }

    public func leftRetract(_: ReteSession, _: Token): Unit {
        retracted += 1
    }
}

/**
 * alpha 链、memory 与下游通知（`doc/04-rete-network.md` §3、§6.1，用例 R-01/R-10/R-12/R-13）。
 */
@Test
class AlphaNode_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func signature(field: String, op: String, value: Int64): AlphaSignature {
        AlphaSignature("Order", field: field, opName: op, value: Some(ValueKey.of(value)))
    }

    private func node(id: Int64, amount: Int64): AlphaNode {
        let signatureValue = signature("amount", "Gt", amount)
        AlphaNode(id, signatureValue, { fact: Fact =>
            match (fact.get("amount")) {
                case Some(value) => ValueKey.of(value) > ValueKey.of(amount)
                case None => false
            }
        })
    }

    /** 多约束串成链并短路：不满足前一个约束的事实不会进入后继。 */
    @TestCase
    public func chainShortCircuitsAtFirstFailure(): Unit {
        let session = AlphaTestSession(RecordingSink())
        let first = node(1, 200)
        let second = node(2, 0)
        let third = AlphaNode(3, signature("amount", "Lt", 400), { fact: Fact =>
            match (fact.get("amount")) {
                case Some(value) => ValueKey.of(value) < ValueKey.of(400)
                case None => false
            }
        })
        first.addChild(second)
        second.addChild(third)

        first.propagate(session, FactHandle("default", 1, "Order"), order(100))
        first.propagate(session, FactHandle("default", 2, "Order"), order(300))
        first.propagate(session, FactHandle("default", 3, "Order"), order(500))

        @Assert(session.memoryOf(1).size(), 2)
        @Assert(session.memoryOf(2).size(), 2)
        // 100 在第一个节点就被短路，500 在第三个节点被拒绝
        @Assert(session.memoryOf(3).size(), 1)
    }

    /** 同事实重复传播：memory 幂等，下游只收到一次（R-10）。 */
    @TestCase
    public func duplicatePropagationIsIdempotent(): Unit {
        let session = AlphaTestSession(RecordingSink())
        let first = node(1, 200)
        let counter = CountingRightSink()
        first.addRightConsumer(counter)
        let handle = FactHandle("default", 1, "Order")
        let fact = order(300)

        first.propagate(session, handle, fact)
        first.propagate(session, handle, fact)

        @Assert(session.memoryOf(1).size(), 1)
        @Assert(counter.activated, 1)
    }

    /** 撤销只对曾经命中的事实通知下游；空 memory 撤销不抛错（R-12）。 */
    @TestCase
    public func removeNotifiesDownstreamOnlyWhenPresent(): Unit {
        let session = AlphaTestSession(RecordingSink())
        let first = node(1, 200)
        let right = CountingRightSink()
        let left = CountingLeftSink()
        first.addRightConsumer(right)
        first.addLeftConsumer(left, "o")
        let handle = FactHandle("default", 1, "Order")

        first.propagate(session, handle, order(300))
        @Assert(right.activated, 1)
        @Assert(left.activated, 1)
        @Assert(left.lastName, "o")

        first.retract(session, handle)
        @Assert(right.retracted, 1)
        @Assert(left.retracted, 1)
        @Assert(session.memoryOf(1).size(), 0)

        // 第二次撤销：memory 里已没有该句柄，不再通知
        first.retract(session, handle)
        @Assert(right.retracted, 1)
        @Assert(session.memoryOf(1).size(), 0)
    }

    /** 不满足测试的事实不进入 memory（R-01）。 */
    @TestCase
    public func failingTestLeavesMemoryEmpty(): Unit {
        let session = AlphaTestSession(RecordingSink())
        let first = node(1, 200)
        first.propagate(session, FactHandle("default", 1, "Order"), order(100))
        @Assert(session.memoryOf(1).size(), 0)
    }

    /** 没有任何规则关心该类型时直接忽略，不抛错（R-13）。 */
    @TestCase
    public func unknownTypeIsIgnoredByRoot(): Unit {
        let session = AlphaTestSession(RecordingSink())
        let root = RootNode(0)
        root.addHead(node(1, 0))
        let other = DynamicFact("Unknown")
        other.set("amount", 100)
        root.propagate(session, FactHandle("default", 1, "Unknown"), other)
        @Assert(session.memoryOf(1).size(), 0)
    }
}
