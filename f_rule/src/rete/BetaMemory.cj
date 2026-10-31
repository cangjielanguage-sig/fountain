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
import fountain::f_concurrent.ConcurrentSkipListMap
import fountain::f_rule.condition.{JoinConstraint, Operator}
import fountain::f_rule.fact.{Fact, ValueKey}

/**
 * beta memory：令牌集合 + 下游 join 的左字段索引（`doc/04-rete-network.md` §7.2）。
 *
 * 索引键是 `"<binding>.<field>"`，按需懒建；同值多令牌通过 `RangeKey(ownerId)` 共存。
 * 加入令牌即 `retain`，移除即 `release`，引用归零的令牌会递归释放父链（R-14）。
 */
/** 索引探测计划：令牌侧字段键、应满足的算子、事实侧取值。 */
class JoinProbe {
    let fieldKey: String
    let op: Operator
    let raw: Any

    JoinProbe(fieldKey: String, op: Operator, raw: Any) {
        this.fieldKey = fieldKey
        this.op = op
        this.raw = raw
    }
}

public class BetaMemory <: ReteNode {
    private let id_: Int64
    private let tokens_: ArrayList<Token>
    private let set_: HashSet<Token>
    private let eqIndex_: HashMap<String, HashMap<ValueKey, ArrayList<Token>>>
    private let ordIndex_: HashMap<String, ConcurrentSkipListMap<RangeKey, Token>>

    public init(id: Int64) {
        this.id_ = id
        this.tokens_ = ArrayList<Token>()
        this.set_ = HashSet<Token>()
        this.eqIndex_ = HashMap<String, HashMap<ValueKey, ArrayList<Token>>>()
        this.ordIndex_ = HashMap<String, ConcurrentSkipListMap<RangeKey, Token>>()
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    /** 集合语义：重复加入返回 false；成功加入时为令牌持有一次引用。 */
    public func add(token: Token): Bool {
        if (set_.contains(token)) {
            return false
        }
        set_.add(token)
        tokens_.add(token)
        token.retain()
        for ((fieldKey, index) in eqIndex_) {
            indexEq(index, fieldKey, token)
        }
        for ((fieldKey, index) in ordIndex_) {
            indexOrd(index, fieldKey, token)
        }
        true
    }

    /** 移除令牌并释放引用；不存在返回 false。 */
    public func remove(token: Token): Bool {
        if (!set_.remove(token)) {
            return false
        }
        var i = 0
        while (i < tokens_.size) {
            if (tokens_[i] == token) {
                tokens_.remove(at: i)
                break
            }
            i += 1
        }
        for ((fieldKey, index) in eqIndex_) {
            unindexEq(index, fieldKey, token)
        }
        for ((fieldKey, index) in ordIndex_) {
            unindexOrd(index, fieldKey, token)
        }
        let _ = token.release()
        true
    }

    public func contains(token: Token): Bool {
        set_.contains(token)
    }

    public func tokens(): Array<Token> {
        tokens_.toArray()
    }

    public func size(): Int64 {
        tokens_.size
    }

    /** 按 `"binding.field"` 做等值探测。 */
    public func probe(fieldKey: String, key: ValueKey): Array<Token> {
        ensureEqIndex(fieldKey)
        let out = ArrayList<Token>()
        match (eqIndex_[fieldKey].get(key)) {
            case Some(found) =>
                for (token in found) {
                    out.add(token)
                }
            case None => ()
        }
        out.toArray()
    }

    public func select(fieldKey: String, op: Operator, value: ValueKey): Array<Token> {
        match (op) {
            case Operator.Eq => return probe(fieldKey, value)
            case Operator.Gt => return orderedTail(fieldKey, value, false)
            case Operator.Ge => return orderedTail(fieldKey, value, true)
            case Operator.Lt => return orderedHeader(fieldKey, value, false)
            case Operator.Le => return orderedHeader(fieldKey, value, true)
            case _ => return tokens()
        }
    }

    /**
     * 右侧新事实进入时，用连接约束在左集合里取候选令牌。
     *
     * 只做定位：返回超集是允许的，最终由 `BetaNode` 逐条重算 join。
     * 无可用索引时回退全扫。
     */
    public func probeByJoin(joins: Array<JoinConstraint>, fact: Fact, factBinding: String): Array<Token> {
        for (join in joins) {
            match (BetaMemory.joinProbe(join, fact, factBinding)) {
                case Some(probe) =>
                    match (BetaMemory.keyOf(probe.raw)) {
                        case Some(key) => return select(probe.fieldKey, probe.op, key)
                        case None => ()
                    }
                case None => ()
            }
        }
        tokens()
    }

    /** 令牌侧字段键 + 令牌侧应满足的算子 + 事实侧取值；不适用于索引时返回 None。 */
    private static func joinProbe(join: JoinConstraint, fact: Fact,
        factBinding: String): ?JoinProbe {
        if (join.rightBinding == factBinding) {
            let raw = match (fact.get(join.rightField)) {
                case Some(value) => value
                case None => return None
            }
            if (join.op == Operator.Eq) {
                return Some(JoinProbe(join.leftBinding + "." + join.leftField, Operator.Eq, raw))
            }
            if (join.op.ordering) {
                // 事实在右侧：令牌字段必须满足 `left OP factValue`，算子不变。
                return Some(JoinProbe(join.leftBinding + "." + join.leftField, join.op, raw))
            }
            return None
        }
        if (join.leftBinding == factBinding) {
            let raw = match (fact.get(join.leftField)) {
                case Some(value) => value
                case None => return None
            }
            if (join.op == Operator.Eq) {
                return Some(JoinProbe(join.rightBinding + "." + join.rightField, Operator.Eq, raw))
            }
            if (join.op.ordering) {
                // 事实在左侧：`factValue OP tokenValue` ⇔ `tokenValue inv(OP) factValue`。
                return Some(JoinProbe(join.rightBinding + "." + join.rightField, inverse(join.op), raw))
            }
            return None
        }
        None
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

    private func orderedTail(fieldKey: String, value: ValueKey, including: Bool): Array<Token> {
        ensureOrdIndex(fieldKey)
        let bound = if (including) {
            RangeKey(value, Int64.Min)
        } else {
            RangeKey(value, Int64.Max)
        }
        let out = ArrayList<Token>()
        for ((_, token) in ordIndex_[fieldKey].tailer(bound, including: including)) {
            out.add(token)
        }
        out.toArray()
    }

    private func orderedHeader(fieldKey: String, value: ValueKey, including: Bool): Array<Token> {
        ensureOrdIndex(fieldKey)
        let bound = if (including) {
            RangeKey(value, Int64.Min)
        } else {
            RangeKey(value, Int64.Max)
        }
        let out = ArrayList<Token>()
        for ((_, token) in ordIndex_[fieldKey].header(bound, including: including)) {
            out.add(token)
        }
        out.toArray()
    }

    private func ensureEqIndex(fieldKey: String): Unit {
        if (eqIndex_.contains(fieldKey)) {
            return
        }
        let index = HashMap<ValueKey, ArrayList<Token>>()
        eqIndex_[fieldKey] = index
        for (token in tokens_.toArray()) {
            indexEq(index, fieldKey, token)
        }
    }

    private func ensureOrdIndex(fieldKey: String): Unit {
        if (ordIndex_.contains(fieldKey)) {
            return
        }
        let index = ConcurrentSkipListMap<RangeKey, Token>()
        ordIndex_[fieldKey] = index
        for (token in tokens_.toArray()) {
            indexOrd(index, fieldKey, token)
        }
    }

    private func indexEq(index: HashMap<ValueKey, ArrayList<Token>>, fieldKey: String,
        token: Token): Unit {
        match (BetaMemory.valueAt(token, fieldKey)) {
            case Some(raw) =>
                match (BetaMemory.keyOf(raw)) {
                    case Some(key) =>
                        match (index.get(key)) {
                            case Some(found) => found.add(token)
                            case None =>
                                let found = ArrayList<Token>()
                                found.add(token)
                                index[key] = found
                        }
                    case None => ()
                }
            case None => ()
        }
    }

    private func unindexEq(index: HashMap<ValueKey, ArrayList<Token>>, fieldKey: String,
        token: Token): Unit {
        match (BetaMemory.valueAt(token, fieldKey)) {
            case Some(raw) =>
                match (BetaMemory.keyOf(raw)) {
                    case Some(key) =>
                        match (index.get(key)) {
                            case Some(found) =>
                                var i = 0
                                while (i < found.size) {
                                    if (found[i] == token) {
                                        found.remove(at: i)
                                        break
                                    }
                                    i += 1
                                }
                                if (found.isEmpty()) {
                                    index.remove(key)
                                }
                            case None => ()
                        }
                    case None => ()
                }
            case None => ()
        }
    }

    private func indexOrd(index: ConcurrentSkipListMap<RangeKey, Token>, fieldKey: String,
        token: Token): Unit {
        match (BetaMemory.valueAt(token, fieldKey)) {
            case Some(raw) =>
                match (BetaMemory.keyOf(raw)) {
                    case Some(key) => let _ = index.add(RangeKey(key, token.id), token)
                    case None => ()
                }
            case None => ()
        }
    }

    private func unindexOrd(index: ConcurrentSkipListMap<RangeKey, Token>, fieldKey: String,
        token: Token): Unit {
        match (BetaMemory.valueAt(token, fieldKey)) {
            case Some(raw) =>
                match (BetaMemory.keyOf(raw)) {
                    case Some(key) => let _ = index.remove(RangeKey(key, token.id))
                    case None => ()
                }
            case None => ()
        }
    }

    /** 从 `"binding.field"` 取出令牌里的字段值。 */
    private static func valueAt(token: Token, fieldKey: String): ?Any {
        let parts = fieldKey.split('.')
        if (parts.size != 2) {
            return None
        }
        match (token.bindings().get(parts[0])) {
            case Some(fact) => fact.get(parts[1])
            case None => None
        }
    }

    private static func keyOf(raw: Any): ?ValueKey {
        try {
            Some(ValueKey.of(raw))
        } catch (e: Exception) {
            None
        }
    }
}
