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
package fountain::f_rule.table

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.ValueKey

/** 一行命中：行、行级输出槽与 salience（`doc/07-decision-table.md` §9）。 */
public class TableHit {
    public let row: TableRow
    public let outputs: HashMap<String, Any>
    public let salience: Int64

    public init(row: TableRow, outputs: HashMap<String, Any>, salience: Int64) {
        this.row = row
        this.outputs = outputs
        this.salience = salience
    }

    public func toString(): String {
        "TableHit(${row.ruleId}@${row.line})"
    }
}

/**
 * 命中策略聚合器（`doc/07-decision-table.md` §2）。
 *
 * 输入按行序排列，输出按策略重排或裁剪；`Unique` 的零/多命中与 `Any` 的输出冲突
 * 在这里抛错。输出比较统一走 [ValueKey]，与网络索引的数值归一语义一致。
 */
public class HitAggregator {
    private let policy_: HitPolicy
    private let outputOrder_: Array<String>

    public init(policy: HitPolicy, outputOrder!: Array<String> = Array<String>()) {
        this.policy_ = policy
        this.outputOrder_ = outputOrder
    }

    public func aggregate(hits: Array<TableHit>): Array<TableHit> {
        match (policy_) {
            case Unique =>
                if (hits.size == 0) {
                    throw RuleException(
                        RuleErrorCode.TABLE_NO_MATCH,
                        "Unique 命中策略要求恰好一行命中，实际 0 行"
                    )
                }
                if (hits.size > 1) {
                    throw RuleException(
                        RuleErrorCode.TABLE_MULTI_MATCH,
                        "Unique 命中策略要求恰好一行命中，实际 ${hits.size} 行"
                    )
                }
                return hits
            case First =>
                if (hits.size == 0) {
                    return Array<TableHit>()
                }
                return [hits[0]]
            case Priority =>
                if (hits.size == 0) {
                    return Array<TableHit>()
                }
                if (hits.size > 1 && outputOrder_.isEmpty()) {
                    throw RuleException(
                        RuleErrorCode.TABLE_INVALID,
                        "Priority 命中策略需要声明 outputOrder"
                    )
                }
                let ordered = prioritySorted(hits)
                return [ordered[0]]
            case Any =>
                ensureConsistentOutputs(hits)
                return hits
            case Collect =>
                return hits
            case RuleOrder =>
                return sorted(hits) { left, right => left.salience > right.salience }
            case OutputOrder =>
                let names = orderedNames(hits)
                return sorted(hits) { left, right => compareOutputs(left, right, names) == Ordering.LT }
        }
    }

    private func prioritySorted(hits: Array<TableHit>): Array<TableHit> {
        let names = orderedNames(hits)
        sorted(hits) { left, right => compareOutputs(left, right, names) == Ordering.LT }
    }

    /** `Any` 要求全部命中的输出完全一致。 */
    private func ensureConsistentOutputs(hits: Array<TableHit>): Unit {
        if (hits.size <= 1) {
            return
        }
        let first = hits[0]
        for (index in 1..hits.size) {
            if (!sameOutputs(first.outputs, hits[index].outputs)) {
                throw RuleException(
                    RuleErrorCode.TABLE_MULTI_MATCH,
                    "Any 命中策略要求多行命中输出一致，第 ${hits[index].row.line} 行不同"
                )
            }
        }
    }

    private func sameOutputs(left: HashMap<String, Any>, right: HashMap<String, Any>): Bool {
        if (left.size != right.size) {
            return false
        }
        for ((key, value) in left) {
            match (right.get(key)) {
                case Some(other) =>
                    if (ValueKey.of(value).compare(ValueKey.of(other)) != Ordering.EQ) {
                        return false
                    }
                case None => return false
            }
        }
        true
    }

    /** 按 `outputOrder` 逐列比较；未声明时对输出列名排序，保证确定性。 */
    private func compareOutputs(left: TableHit, right: TableHit, names: Array<String>): Ordering {
        for (name in names) {
            let order = compareValue(left.outputs.get(name), right.outputs.get(name))
            if (order != Ordering.EQ) {
                return order
            }
        }
        Ordering.EQ
    }

    /** 显式 outputOrder 优先；否则取全部命中输出键的并集并排序。 */
    private func orderedNames(hits: Array<TableHit>): Array<String> {
        if (!outputOrder_.isEmpty()) {
            return outputOrder_
        }
        let names = ArrayList<String>()
        let seen = HashMap<String, Bool>()
        for (hit in hits) {
            for ((key, _) in hit.outputs) {
                if (!seen.contains(key)) {
                    seen[key] = true
                    names.add(key)
                }
            }
        }
        var i = 1
        while (i < names.size) {
            let current = names[i]
            var j = i - 1
            while (j >= 0 && names[j] > current) {
                names[j + 1] = names[j]
                j -= 1
            }
            names[j + 1] = current
            i += 1
        }
        names.toArray()
    }

    private func compareValue(left: ?Any, right: ?Any): Ordering {
        match ((left, right)) {
            case (None, None) => Ordering.EQ
            case (None, Some(_)) => Ordering.GT
            case (Some(_), None) => Ordering.LT
            case (Some(l), Some(r)) => ValueKey.of(l).compare(ValueKey.of(r))
        }
    }

    /** 稳定插入排序：同键保持输入顺序（行序）。 */
    private func sorted(hits: Array<TableHit>, less: (TableHit, TableHit) -> Bool): Array<TableHit> {
        let items = ArrayList<TableHit>(hits.size)
        for (hit in hits) {
            items.add(hit)
        }
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && less(current, items[j])) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
        items.toArray()
    }
}
