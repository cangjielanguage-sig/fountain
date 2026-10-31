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

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.condition.{JoinConstraint, Operator}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}

/** beta 网络的测试会话：alpha/beta memory 表 + 激活汇。 */
class BetaTestSession <: ReteSession {
    private let sink_: RecordingSink
    private let alphaMems: HashMap<Int64, AlphaMemory>
    private let betaMems: HashMap<Int64, BetaMemory>

    BetaTestSession() {
        this.sink_ = RecordingSink()
        this.alphaMems = HashMap<Int64, AlphaMemory>()
        this.betaMems = HashMap<Int64, BetaMemory>()
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

    public func betaMemory(nodeId: Int64): BetaMemory {
        match (betaMems.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = BetaMemory(nodeId)
                betaMems[nodeId] = created
                created
        }
    }
}

/** 记录下游收到的令牌。 */
class TokenCollector <: TokenSink {
    private let tokens_: ArrayList<Token>

    TokenCollector() {
        this.tokens_ = ArrayList<Token>()
    }

    public func leftActivate(session: ReteSession, token: Token): Unit {
        tokens_.add(token)
    }

    public func leftRetract(session: ReteSession, token: Token): Unit {
        var i = 0
        while (i < tokens_.size) {
            if (tokens_[i] == token) {
                tokens_.remove(at: i)
                return
            }
            i += 1
        }
    }

    public func count(): Int64 {
        tokens_.size
    }
}

/**
 * beta join、令牌产出与撤销（`doc/04-rete-network.md` §6、§7.3，用例 R-02/R-03/R-04/R-09）。
 */
@Test
class BetaNode_test {
    private func order(amount: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func handle(id: Int64): FactHandle {
        FactHandle("default", id, "Order")
    }

    private func join(left: String, op: Operator, right: String): JoinConstraint {
        JoinConstraint(left, "amount", op, right, "amount")
    }

    /** 两模式等值 join：左右两侧激活顺序不同，产出令牌集合一致（R-02）。 */
    @TestCase
    public func equalityJoinIsSymmetric(): Unit {
        let byRight = runJoin([1, 2, 3], [2, 3, 4], Operator.Eq, true)
        let byLeft = runJoin([1, 2, 3], [2, 3, 4], Operator.Eq, false)
        @Assert(byRight.size(), 2)
        @Assert(byLeft.size(), 2)
        @Expect(sameTokens(byRight.tokens(), byLeft.tokens()), true)
    }

    /** 两模式范围 join：结果与嵌套循环一致（R-03）。 */
    @TestCase
    public func rangeJoinMatchesNestedLoop(): Unit {
        // o.amount > u.amount，o ∈ {1,2,3}，u ∈ {2} → 只有 o=3
        let out = runJoin([1, 2, 3], [2], Operator.Gt, true)
        @Assert(out.size(), 1)
        let only = out.tokens()[0]
        @Assert(only.binding, "u")
        @Assert((only.fact.get("amount").getOrThrow() as Int64), 2)
    }

    /** 三模式链式 join：令牌数 = 笛卡尔积中满足全部 join 的组合数（R-04）。 */
    @TestCase
    public func threePatternChainProducesOnlySatisfyingCombinations(): Unit {
        let session = BetaTestSession()
        let first = BetaNode(20, BetaLeft.FromBeta(1), "o", 10,
            [join("o", Operator.Gt, "u")], "u", JoinPlan.LeftHashProbe)
        let second = BetaNode(21, BetaLeft.FromBeta(20), "u", 11,
            [join("u", Operator.Eq, "z")], "z", JoinPlan.LeftHashProbe)
        first.addConsumer(second)
        let collector = TokenCollector()
        second.addConsumer(collector)

        let rightFirst = session.alphaMemory(10)
        rightFirst.add(handle(101), order(1))
        rightFirst.add(handle(102), order(2))
        rightFirst.add(handle(103), order(3))
        let rightSecond = session.alphaMemory(11)
        rightSecond.add(handle(201), order(2))

        let left = session.betaMemory(1)
        for (amount in [1, 2, 3]) {
            let token = Token.root(handle(amount), "o", order(amount))
            let _ = left.add(token)
            first.leftActivate(session, token)
        }

        @Assert(session.betaMemory(20).size(), 3)
        @Assert(session.betaMemory(21).size(), 1)
        @Assert(collector.count(), 1)
    }

    /** 撤销一个中间事实：只移除相关令牌，其余保留（R-09）。 */
    @TestCase
    public func retractingOneFactRemovesOnlyRelatedTokens(): Unit {
        let session = BetaTestSession()
        let beta = BetaNode(20, BetaLeft.FromBeta(1), "o", 10,
            [join("o", Operator.Gt, "u")], "u", JoinPlan.LeftHashProbe)
        let collector = TokenCollector()
        beta.addConsumer(collector)
        let right = session.alphaMemory(10)
        let low = handle(101)
        right.add(low, order(1))
        right.add(handle(102), order(2))

        let left = session.betaMemory(1)
        for (amount in [2, 3]) {
            let token = Token.root(handle(amount), "o", order(amount))
            let _ = left.add(token)
            beta.leftActivate(session, token)
        }
        // o=2 > u=1、o=3 > u=1、o=3 > u=2 → 3 个令牌
        @Assert(session.betaMemory(20).size(), 3)

        // 撤销 u=1：只影响 o=2/u=1 与 o=3/u=1
        beta.rightRetract(session, low)
        @Assert(session.betaMemory(20).size(), 1)
        @Assert(collector.count(), 1)
    }

    /** join 计划在构建期确定：等值、范围、无索引各有分支。 */
    @TestCase
    public func joinPlanIsChosenAtBuildTime(): Unit {
        @Assert(BetaNode.choosePlan([]).toString(), "RightScan")
        @Assert(BetaNode.choosePlan([join("o", Operator.Eq, "u")]).toString(), "LeftHashProbe")
        @Assert(BetaNode.choosePlan([join("o", Operator.Gt, "u")]).toString(), "LeftRangeScan")
        @Assert(BetaNode.choosePlan([join("o", Operator.Contains, "u")]).toString(), "LeftScan")
    }

    /** 用右侧事实驱动 join，返回产出令牌所在的 memory。 */
    private func runJoin(leftAmounts: Array<Int64>, rightAmounts: Array<Int64>,
        op: Operator, byRight: Bool): BetaMemory {
        let session = BetaTestSession()
        let beta = BetaNode(20, BetaLeft.FromBeta(1), "o", 10,
            [join("o", op, "u")], "u", BetaNode.choosePlan([join("o", op, "u")]))
        let right = session.alphaMemory(10)
        var i = 0
        while (i < rightAmounts.size) {
            let handle = FactHandle("default", 100 + i, "Order")
            right.add(handle, order(rightAmounts[i]))
            i += 1
        }
        let left = session.betaMemory(1)
        i = 0
        while (i < leftAmounts.size) {
            let token = Token.root(FactHandle("default", i + 1, "Order"), "o",
                order(leftAmounts[i]))
            let _ = left.add(token)
            if (byRight) {
                // 先放齐左侧令牌，再逐条右侧事实激活
                ()
            } else {
                beta.leftActivate(session, token)
            }
            i += 1
        }
        if (byRight) {
            for (handle in right.all()) {
                let fact = right.fact(handle).getOrThrow()
                beta.rightActivate(session, handle, fact)
            }
        }
        session.betaMemory(20)
    }

    private func sameTokens(left: Array<Token>, right: Array<Token>): Bool {
        if (left.size != right.size) {
            return false
        }
        for (item in left) {
            var found = false
            for (other in right) {
                if (item == other) {
                    found = true
                    break
                }
            }
            if (!found) {
                return false
            }
        }
        true
    }
}
