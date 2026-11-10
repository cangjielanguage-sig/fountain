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

import std.collection.{ArrayList, HashMap, HashSet}
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
 * 产出索引（右事实 → 子令牌、父令牌 → 子令牌）属于**会话运行态**，由
 * [ReteSession.betaProductions] 按 `(space, session)` 提供；节点本身在构建后不可变，
 * 多个会话共享同一张网络也不会互相污染。
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
    /** 共享本节点的规则 id；join 求值异常时按规则记失败。 */
    private let ruleIds_: HashSet<String>

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
        this.ruleIds_ = HashSet<String>()
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    /** 登记使用本节点的规则（join 签名共享时多个规则共用同一节点）。 */
    public func addRule(ruleId: String): Unit {
        ruleIds_.add(ruleId)
    }

    public func ruleIds(): Array<String> {
        ruleIds_.toArray()
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
        // 只为本次展开建一次映射；候选事实逐个覆盖右绑定后复用。
        let base = BetaNode.factMapOf(token)
        for (handle in candidates) {
            match (memory.fact(handle)) {
                case Some(fact) =>
                    base[rightBinding] = fact
                    if (holds(session, joins, base) && !alreadyEmitted(session, token, handle)) {
                        emit(session, token, handle, fact)
                    }
                case None => ()
            }
        }
    }

    /** 右侧事实进入：用左侧 beta memory 的 join 索引找候选令牌。 */
    public func rightActivate(session: ReteSession, handle: FactHandle, fact: Fact): Unit {
        for (token in candidatesOf(session, fact)) {
            if (holdsWith(session, token, fact) && !alreadyEmitted(session, token, handle)) {
                emit(session, token, handle, fact)
            }
        }
    }

    /** 左令牌撤回：移除它产出的全部子令牌，并通知下游。 */
    public func leftRetract(session: ReteSession, token: Token): Unit {
        let children = match (session.betaProductions(id).takeByParent(token)) {
            case Some(found) => found
            case None => return
        }
        let output = session.betaMemory(id)
        for (child in children) {
            let _ = output.remove(child)
            session.betaProductions(id).forget(child)
            for (consumer in consumers_) {
                consumer.leftRetract(session, child)
            }
        }
    }

    /** 右事实撤回：只移除 `produced` 里记录的子令牌（O(k)）。 */
    public func rightRetract(session: ReteSession, handle: FactHandle): Unit {
        let children = match (session.betaProductions(id).takeByHandle(handle)) {
            case Some(found) => found
            case None => return
        }
        let output = session.betaMemory(id)
        for (child in children) {
            session.betaProductions(id).forget(child)
            let _ = output.remove(child)
            for (consumer in consumers_) {
                consumer.leftRetract(session, child)
            }
        }
    }

    /** 右侧候选句柄：能走索引时只取匹配值，否则全扫。 */
    private func probeRight(memory: AlphaMemory, token: Token): ArrayList<FactHandle> {
        match (plan) {
            case LeftScan | RightScan => return memory.orderedList()
            case _ => ()
        }
        for (join in joins) {
            if (join.rightBinding != rightBinding) {
                continue
            }
            let leftFact = match (token.factOf(join.leftBinding)) {
                case Some(found) => found
                case None => continue
            }
            let leftValue = match (leftFact.get(join.leftField)) {
                case Some(value) => value
                case None => continue
            }
            let key = match (BetaNode.keyOf(leftValue)) {
                case Some(found) => found
                case None => continue
            }
            if (join.op == Operator.Eq) {
                return memory.probeList(join.rightField, key)
            }
            if (join.op.ordering) {
                return BetaNode.asList(memory.select(join.rightField, BetaNode.inverse(join.op), key))
            }
        }
        memory.orderedList()
    }

    /** 范围探测返回数组，统一成列表以便与索引直读路径共用调用点。 */
    private static func asList(items: Array<FactHandle>): ArrayList<FactHandle> {
        let out = ArrayList<FactHandle>()
        for (item in items) {
            out.add(item)
        }
        out
    }

    /** 右侧事实的左侧候选令牌。 */
    private func candidatesOf(session: ReteSession, fact: Fact): ArrayList<Token> {
        match (leftSource) {
            case FromBeta(id) =>
                let memory = session.betaMemory(id)
                match (plan) {
                    case LeftScan | RightScan => memory.tokensList()
                    case _ => memory.probeJoinList(joins, fact, rightBinding)
                }
            case FromAlpha(id) =>
                // 首模式的左令牌由 alpha memory 的哑令牌驱动；右侧先到时按需构造等价令牌。
                // 有可用 join 时必须走索引探测，否则每条事实都会全扫左 memory（O(n) 退化）。
                let memory = session.alphaMemory(id)
                let handles = match (plan) {
                    case LeftScan | RightScan => memory.orderedList()
                    case _ => probeLeftAlpha(memory, fact)
                }
                let out = ArrayList<Token>()
                for (handle in handles) {
                    match (memory.fact(handle)) {
                        case Some(leftFact) => out.add(Token.root(handle, leftBinding, leftFact))
                        case None => ()
                    }
                }
                out
        }
    }

    /**
     * 用右侧事实的 join 值探测左侧 alpha memory。
     *
     * 与 [probeRight] 对称：只定位候选，最终仍由 [holdsWith] 逐条重算，返回超集是安全的。
     * 没有任何可用索引时退回全扫。
     */
    private func probeLeftAlpha(memory: AlphaMemory, fact: Fact): ArrayList<FactHandle> {
        for (join in joins) {
            if (join.rightBinding != rightBinding) {
                continue
            }
            let raw = match (fact.get(join.rightField)) {
                case Some(value) => value
                case None => continue
            }
            let key = match (BetaNode.keyOf(raw)) {
                case Some(found) => found
                case None => continue
            }
            if (join.op == Operator.Eq) {
                return memory.probeList(join.leftField, key)
            }
            if (join.op.ordering) {
                return BetaNode.asList(memory.select(join.leftField, join.op, key))
            }
        }
        memory.orderedList()
    }

    private func holdsWith(session: ReteSession, token: Token, fact: Fact): Bool {
        if (joins.size == 0) {
            return true
        }
        let resolve = { binding: String =>
            if (binding == rightBinding) {
                Some(fact)
            } else {
                token.factOf(binding)
            }
        }
        for (join in joins) {
            let result = try {
                join.evalWith(resolve)
            } catch (e: Exception) {
                RuleFailureReporter.report(session, ruleIds_.toArray(), e, site())
                return false
            }
            if (!result.isTrue()) {
                return false
            }
        }
        true
    }

    /**
     * 该 (父令牌, 右侧事实) 是否已产出过子令牌。
     *
     * 左/右激活是对称的两条路径，同一组合必然相遇一次；先查 `produced_` 可以避免
     * 为重复组合构造令牌再丢弃（占大规模插入的多数候选）。
     */
    private func alreadyEmitted(session: ReteSession, parent: Token, handle: FactHandle): Bool {
        session.betaProductions(id).contains(parent, handle)
    }

    /** 沿父链展开 `绑定名 → 事实`；只为 join 求值服务，不构造句柄表。 */
    private static func factMapOf(token: Token): HashMap<String, Fact> {
        let map = HashMap<String, Fact>()
        var cursor: ?Token = Some(token)
        while (let Some(current) <- cursor) {
            map[current.binding] = current.fact
            cursor = current.parent
        }
        map
    }

    private func emit(session: ReteSession, parent: Token, handle: FactHandle, fact: Fact): Unit {
        let child = Token.child(parent, handle, rightBinding, fact)
        let output = session.betaMemory(id)
        if (!output.add(child)) {
            let _ = child.release()
            return
        }
        session.betaProductions(id).record(handle, parent, child)
        for (consumer in consumers_) {
            consumer.leftActivate(session, child)
        }
    }

    private func holds(session: ReteSession, joins: Array<JoinConstraint>,
        map: HashMap<String, Fact>): Bool {
        for (join in joins) {
            let result = try {
                join.eval(map)
            } catch (e: Exception) {
                RuleFailureReporter.report(session, ruleIds_.toArray(), e, site())
                return false
            }
            if (!result.isTrue()) {
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

    private func site(): String {
        "beta#${id_}"
    }
}
