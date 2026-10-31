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
import fountain::f_rule.condition.{JoinConstraint, Operator}
import fountain::f_rule.fact.{Fact, FactHandle, ValueKey}

/** 左输入来源：首模式来自 alpha memory（哑令牌），后续模式来自上一个 join 的 beta memory。 */
public enum BetaLeft <: ToString {
    | FromAlpha(Int64)
    | FromBeta(Int64)

    public func toString(): String {
        match (this) {
            case FromAlpha(id) => "alpha:${id}"
            case FromBeta(id) => "beta:${id}"
        }
    }
}

/**
 * 构建期确定的探测计划（`doc/04-rete-network.md` §7.3）。
 *
 * 运行期不再重新决策：[choosePlan] 在 `NetworkBuilder` 建图时调用一次。
 */
public enum JoinPlan <: ToString {
    /** 连接算子全为 Eq：左侧哈希索引探测。 */
    | LeftHashProbe
    /** 含范围算子：左侧有序索引范围扫描。 */
    | LeftRangeScan
    /** 左集合很小或无可用索引：全扫左侧令牌。 */
    | LeftScan
    /** 无连接约束：逐条右侧事实与左令牌做笛卡尔积。 */
    | RightScan

    public func toString(): String {
        match (this) {
            case LeftHashProbe => "LeftHashProbe"
            case LeftRangeScan => "LeftRangeScan"
            case LeftScan => "LeftScan"
            case RightScan => "RightScan"
        }
    }
}

/**
 * beta join 节点：左令牌 × 右事实（`doc/04-rete-network.md` §3、§6）。
 *
 * 左右两个入口产出的是**同一批令牌**：父令牌相同、右侧句柄相同，`Token` 的相等性
 * 让重复路径自然去重（R-02 的对称性由此保证）。
 *
 * `produced` 记录"右侧句柄 → 产出令牌"，使 `rightRetract` 为 O(k) 而不是全扫重算；
 * `producedByParent` 是 `leftRetract` 的对应索引。
 */
public class BetaNode <: ReteNode & TokenSink & RightSink {
    private let id_: Int64
    public let leftSource: BetaLeft
    /** 左令牌的绑定名；仅 `FromAlpha` 的按需构造需要。 */
    public let leftBinding: String
    public let rightAlphaId: Int64
    public let joins: Array<JoinConstraint>
    public let rightBinding: String
    public let plan: JoinPlan
    private let consumers_: ArrayList<TokenSink>
    private let produced_: HashMap<FactHandle, ArrayList<Token>>
    private let producedByParent_: HashMap<Token, ArrayList<Token>>

    public init(id: Int64, leftSource: BetaLeft, leftBinding: String, rightAlphaId: Int64,
        joins: Array<JoinConstraint>, rightBinding: String, plan: JoinPlan) {
        this.id_ = id
        this.leftSource = leftSource
        this.leftBinding = leftBinding
        this.rightAlphaId = rightAlphaId
        this.joins = joins
        this.rightBinding = rightBinding
        this.plan = plan
        this.consumers_ = ArrayList<TokenSink>()
        this.produced_ = HashMap<FactHandle, ArrayList<Token>>()
        this.producedByParent_ = HashMap<Token, ArrayList<Token>>()
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    /** 构建期决定探测计划。 */
    public static func choosePlan(joins: Array<JoinConstraint>): JoinPlan {
        if (joins.size == 0) {
            return JoinPlan.RightScan
        }
        var allEq = true
        var hasOrdering = false
        for (join in joins) {
            if (join.op != Operator.Eq) {
                allEq = false
            }
            if (join.op.ordering) {
                hasOrdering = true
            }
        }
        if (allEq) {
            return JoinPlan.LeftHashProbe
        }
        if (hasOrdering) {
            return JoinPlan.LeftRangeScan
        }
        JoinPlan.LeftScan
    }

    /**
     * 登记下游消费方。
     *
     * `NetworkBuilder` 按节点 id 升序建图并按序登记，传播顺序因此可复现。
     */
    public func addConsumer(sink: TokenSink): Unit {
        consumers_.add(sink)
    }

    public func consumers(): Array<TokenSink> {
        consumers_.toArray()
    }

    /** 左令牌进入：用右侧 alpha memory 找候选事实。 */
    public func leftActivate(session: ReteSession, token: Token): Unit {
        let memory = session.alphaMemory(rightAlphaId)
        let candidates = probeRight(memory, token)
        let base = token.bindings().toFactMap()
        for (handle in candidates) {
            match (memory.fact(handle)) {
                case Some(fact) =>
                    base[rightBinding] = fact
                    if (holds(joins, base)) {
                        emit(session, token, handle, fact)
                    }
                case None => ()
            }
        }
    }

    /** 右侧事实进入：用左侧 beta memory 的 join 索引找候选令牌。 */
    public func rightActivate(session: ReteSession, handle: FactHandle, fact: Fact): Unit {
        for (token in candidatesOf(session, fact)) {
            if (holdsWith(token, fact)) {
                emit(session, token, handle, fact)
            }
        }
    }

    /** 左令牌撤回：移除它产出的全部子令牌，并通知下游。 */
    public func leftRetract(session: ReteSession, token: Token): Unit {
        let children = match (producedByParent_.remove(token)) {
            case Some(found) => found
            case None => return
        }
        let output = session.betaMemory(id)
        for (child in children) {
            let _ = output.remove(child)
            forgetProduced(child)
            for (consumer in consumers_) {
                consumer.leftRetract(session, child)
            }
        }
    }

    /** 右事实撤回：只移除 `produced` 里记录的子令牌（O(k)）。 */
    public func rightRetract(session: ReteSession, handle: FactHandle): Unit {
        let children = match (produced_.remove(handle)) {
            case Some(found) => found
            case None => return
        }
        let output = session.betaMemory(id)
        for (child in children) {
            match (child.parent) {
                case Some(parent) => BetaNode.removeChild(producedByParent_, parent, child)
                case None => ()
            }
            let _ = output.remove(child)
            for (consumer in consumers_) {
                consumer.leftRetract(session, child)
            }
        }
    }

    /** 右侧候选句柄：能走索引时只取匹配值，否则全扫。 */
    private func probeRight(memory: AlphaMemory, token: Token): Array<FactHandle> {
        match (plan) {
            case LeftScan | RightScan => return memory.all()
            case _ => ()
        }
        let bindings = token.bindings()
        for (join in joins) {
            if (join.rightBinding != rightBinding) {
                continue
            }
            let leftFact = bindings.resolve(join.leftBinding)
            if (leftFact.isNone()) {
                continue
            }
            let leftValue = leftFact.getOrThrow().get(join.leftField)
            if (leftValue.isNone()) {
                continue
            }
            let key = BetaNode.keyOf(leftValue.getOrThrow())
            if (key.isNone()) {
                continue
            }
            if (join.op == Operator.Eq) {
                return memory.probe(join.rightField, key.getOrThrow())
            }
            if (join.op.ordering) {
                return memory.select(join.rightField, BetaNode.inverse(join.op), key.getOrThrow())
            }
        }
        memory.all()
    }

    /** 右侧事实的左侧候选令牌。 */
    private func candidatesOf(session: ReteSession, fact: Fact): Array<Token> {
        match (leftSource) {
            case FromBeta(id) =>
                let memory = session.betaMemory(id)
                match (plan) {
                    case LeftScan | RightScan => memory.tokens()
                    case _ => memory.probeByJoin(joins, fact, rightBinding)
                }
            case FromAlpha(id) =>
                // 首模式的左令牌由 alpha memory 的哑令牌驱动；右侧先到时按需构造等价令牌。
                let memory = session.alphaMemory(id)
                let out = ArrayList<Token>()
                for (handle in memory.all()) {
                    match (memory.fact(handle)) {
                        case Some(leftFact) =>
                            out.add(Token.root(handle, leftBinding, leftFact))
                        case None => ()
                    }
                }
                out.toArray()
        }
    }

    private func holdsWith(token: Token, fact: Fact): Bool {
        let map = token.bindings().toFactMap()
        map[rightBinding] = fact
        holds(joins, map)
    }

    private func emit(session: ReteSession, parent: Token, handle: FactHandle, fact: Fact): Unit {
        let child = Token.child(parent, handle, rightBinding, fact)
        let output = session.betaMemory(id)
        if (!output.add(child)) {
            let _ = child.release()
            return
        }
        BetaNode.recordByHandle(produced_, handle, child)
        BetaNode.recordByParent(producedByParent_, parent, child)
        for (consumer in consumers_) {
            consumer.leftActivate(session, child)
        }
    }

    private func forgetProduced(child: Token): Unit {
        match (produced_.get(child.handle)) {
            case Some(children) =>
                var i = 0
                while (i < children.size) {
                    if (children[i] == child) {
                        children.remove(at: i)
                        break
                    }
                    i += 1
                }
                if (children.isEmpty()) {
                    produced_.remove(child.handle)
                }
            case None => ()
        }
    }

    private static func recordByHandle(map: HashMap<FactHandle, ArrayList<Token>>,
        key: FactHandle, token: Token): Unit {
        match (map.get(key)) {
            case Some(found) => found.add(token)
            case None =>
                let found = ArrayList<Token>()
                found.add(token)
                map[key] = found
        }
    }

    private static func recordByParent(map: HashMap<Token, ArrayList<Token>>, key: Token,
        token: Token): Unit {
        match (map.get(key)) {
            case Some(found) => found.add(token)
            case None =>
                let found = ArrayList<Token>()
                found.add(token)
                map[key] = found
        }
    }

    private static func removeChild(map: HashMap<Token, ArrayList<Token>>, parent: Token,
        child: Token): Unit {
        match (map.get(parent)) {
            case Some(children) =>
                var i = 0
                while (i < children.size) {
                    if (children[i] == child) {
                        children.remove(at: i)
                        break
                    }
                    i += 1
                }
                if (children.isEmpty()) {
                    map.remove(parent)
                }
            case None => ()
        }
    }

    private static func holds(joins: Array<JoinConstraint>, map: HashMap<String, Fact>): Bool {
        for (join in joins) {
            if (!join.eval(map).isTrue()) {
                return false
            }
        }
        true
    }

    private static func inverse(op: Operator): Operator {
        match (op) {
            case Operator.Gt => Operator.Lt
            case Operator.Ge => Operator.Le
            case Operator.Lt => Operator.Gt
            case Operator.Le => Operator.Ge
            case _ => op
        }
    }

    private static func keyOf(raw: Any): ?ValueKey {
        try {
            Some(ValueKey.of(raw))
        } catch (e: Exception) {
            None
        }
    }

    public func toString(): String {
        "BetaNode(${id}, ${leftSource}, ${joins.size} joins)"
    }
}
