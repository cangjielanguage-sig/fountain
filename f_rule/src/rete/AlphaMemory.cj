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
import fountain::f_rule.condition.{Operator, OperatorEvaluator}
import fountain::f_rule.fact.{Fact, FactHandle, ValueKey}

/**
 * alpha memory：命中事实集合 + 索引（`doc/04-rete-network.md` §3、§7.1）。
 *
 * 只保存句柄集合与"句柄 → 事实"的引用，事实对象本身由 `FactBase` 持有。
 * 索引按字段**懒建**：第一次探测某字段时扫描当前集合建索引，之后插入/删除同步维护；
 * 这样构建期不需要预先知道哪些字段会被 join 引用。
 *
 * 有序索引使用 `ConcurrentSkipListMap<RangeKey, FactHandle>`，不设规模上限
 * （D4：范围探测 O(log n)，不做"索引过大退化"）。
 */
public class AlphaMemory <: ReteNode {
    /** 空候选的共享实例：高频探测里大多数索引桶为空，避免每次分配空表。 */
    private static let sharedEmpty = ArrayList<FactHandle>()

    private let id_: Int64
    private let facts_: HashMap<FactHandle, Fact>
    private let order_: ArrayList<FactHandle>
    /** 句柄在 `order_` 中的槽位，使撤销为 O(1)（尾元素填补）。 */
    private let slots_: HashMap<FactHandle, Int64>
    private let eqIndex_: HashMap<String, HashMap<ValueKey, ArrayList<FactHandle>>>
    private let ordIndex_: HashMap<String, ConcurrentSkipListMap<RangeKey, FactHandle>>
    private let nullSet_: HashMap<String, HashSet<FactHandle>>

    public init(id: Int64) {
        this.id_ = id
        this.facts_ = HashMap<FactHandle, Fact>()
        this.order_ = ArrayList<FactHandle>()
        this.slots_ = HashMap<FactHandle, Int64>()
        this.eqIndex_ = HashMap<String, HashMap<ValueKey, ArrayList<FactHandle>>>()
        this.ordIndex_ = HashMap<String, ConcurrentSkipListMap<RangeKey, FactHandle>>()
        this.nullSet_ = HashMap<String, HashSet<FactHandle>>()
    }

    /** 加入事实；同一句柄重复加入返回 false，不改变集合与索引。 */
    public func add(handle: FactHandle, fact: Fact): Bool {
        if (facts_.contains(handle)) {
            return false
        }
        facts_[handle] = fact
        slots_[handle] = Int64(order_.size)
        order_.add(handle)
        for ((field, index) in eqIndex_) {
            indexEq(index, field, handle, fact)
        }
        for ((field, index) in ordIndex_) {
            indexOrd(index, field, handle, fact)
        }
        for ((field, index) in nullSet_) {
            indexNull(index, field, handle, fact)
        }
        true
    }

    /** 移除事实；不存在返回 false。尾元素填补槽位，均摊 O(1)。 */
    public func remove(handle: FactHandle): Bool {
        let fact = match (facts_.remove(handle)) {
            case Some(found) => found
            case None => return false
        }
        let slot = match (slots_.remove(handle)) {
            case Some(found) => found
            case None => return false
        }
        let last = Int64(order_.size) - 1
        if (slot != last) {
            let moved = order_[last]
            order_[slot] = moved
            slots_[moved] = slot
        }
        order_.remove(at: last)
        for ((field, index) in eqIndex_) {
            unindexEq(index, field, handle, fact)
        }
        for ((field, index) in ordIndex_) {
            unindexOrd(index, field, handle, fact)
        }
        for ((field, index) in nullSet_) {
            let _ = index.remove(handle)
        }
        true
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    public func size(): Int64 {
        facts_.size
    }

    public func contains(handle: FactHandle): Bool {
        facts_.contains(handle)
    }

    public func fact(handle: FactHandle): ?Fact {
        facts_.get(handle)
    }

    /** 等值探测。 */
    public func probe(field: String, key: ValueKey): Array<FactHandle> {
        let out = ArrayList<FactHandle>()
        for (handle in probeList(field, key)) {
            out.add(handle)
        }
        out.toArray()
    }

    /** 索引桶直读（内部热路径）：返回内部列表，调用方只读。 */
    func probeList(field: String, key: ValueKey): ArrayList<FactHandle> {
        ensureEqIndex(field)
        match (eqIndex_[field].get(key)) {
            case Some(handles) => handles
            case None => AlphaMemory.sharedEmpty
        }
    }

    /** 按插入顺序的全部句柄（内部热路径）：返回内部列表，调用方只读。 */
    func orderedList(): ArrayList<FactHandle> {
        order_
    }

    /** 闭区间范围探测 `[low, high]`。 */
    public func range(field: String, low: ValueKey, high: ValueKey): Array<FactHandle> {
        if (low.compare(high) == Ordering.GT) {
            return Array<FactHandle>()
        }
        ensureOrdIndex(field)
        let index = ordIndex_[field]
        let out = ArrayList<FactHandle>()
        for ((_, handle) in index.sub(RangeKey(low, Int64.Min), RangeKey(high, Int64.Max))) {
            out.add(handle)
        }
        out.toArray()
    }

    /**
     * 按算子选择候选句柄。
     *
     * 只负责定位，语义（含跨域 `TYPE_MISMATCH`）由算子层保证；未建索引的算子
     * 回退全扫，保证结果与索引路径一致。
     */
    public func select(field: String, op: Operator, value: ValueKey): Array<FactHandle> {
        match (op) {
            case Operator.Eq => return probe(field, value)
            case Operator.Gt => return orderedTail(field, value, false)
            case Operator.Ge => return orderedTail(field, value, true)
            case Operator.Lt => return orderedHeader(field, value, false)
            case Operator.Le => return orderedHeader(field, value, true)
            case Operator.Between => return between(field, value)
            case _ => ()
        }
        let out = ArrayList<FactHandle>()
        for (handle in order_) {
            match (facts_.get(handle)) {
                case Some(fact) =>
                    let left = fact.get(field)
                    if (OperatorEvaluator.apply(op, left, Some(value.unwrap())).isTrue()) {
                        out.add(handle)
                    }
                case None => ()
            }
        }
        out.toArray()
    }

    public func all(): Array<FactHandle> {
        order_.toArray()
    }

    private func orderedTail(field: String, value: ValueKey, including: Bool): Array<FactHandle> {
        ensureOrdIndex(field)
        // 同值多事实：不含下界时从该值的最大 ownerId 之后开始，保证同值全部排除。
        let bound = if (including) {
            RangeKey(value, Int64.Min)
        } else {
            RangeKey(value, Int64.Max)
        }
        let out = ArrayList<FactHandle>()
        for ((_, handle) in ordIndex_[field].tailer(bound, including: including)) {
            out.add(handle)
        }
        out.toArray()
    }

    private func orderedHeader(field: String, value: ValueKey, including: Bool): Array<FactHandle> {
        ensureOrdIndex(field)
        // 同上：不含上界时从该值的最小 ownerId 之前截断。
        let bound = if (including) {
            RangeKey(value, Int64.Max)
        } else {
            RangeKey(value, Int64.Min)
        }
        let out = ArrayList<FactHandle>()
        for ((_, handle) in ordIndex_[field].header(bound, including: including)) {
            out.add(handle)
        }
        out.toArray()
    }

    private func between(field: String, value: ValueKey): Array<FactHandle> {
        let items = match (value.unwrap()) {
            case list: ArrayList<ValueKey> => list
            case _ => return Array<FactHandle>()
        }
        if (items.size != 2) {
            return Array<FactHandle>()
        }
        range(field, items[0], items[1])
    }

    private func ensureEqIndex(field: String): Unit {
        if (eqIndex_.contains(field)) {
            return
        }
        let index = HashMap<ValueKey, ArrayList<FactHandle>>()
        eqIndex_[field] = index
        for (handle in order_.toArray()) {
            match (facts_.get(handle)) {
                case Some(fact) => indexEq(index, field, handle, fact)
                case None => ()
            }
        }
    }

    private func ensureOrdIndex(field: String): Unit {
        if (ordIndex_.contains(field)) {
            return
        }
        let index = ConcurrentSkipListMap<RangeKey, FactHandle>()
        ordIndex_[field] = index
        for (handle in order_.toArray()) {
            match (facts_.get(handle)) {
                case Some(fact) => indexOrd(index, field, handle, fact)
                case None => ()
            }
        }
    }

    private func indexEq(index: HashMap<ValueKey, ArrayList<FactHandle>>, field: String,
        handle: FactHandle, fact: Fact): Unit {
        match (fact.get(field)) {
            case Some(raw) =>
                let key = AlphaMemory.keyOf(raw)
                if (key.isSome()) {
                    let actual = key.getOrThrow()
                    match (index.get(actual)) {
                        case Some(handles) => handles.add(handle)
                        case None =>
                            let handles = ArrayList<FactHandle>()
                            handles.add(handle)
                            index[actual] = handles
                    }
                }
            case None => ()
        }
    }

    private func unindexEq(index: HashMap<ValueKey, ArrayList<FactHandle>>, field: String,
        handle: FactHandle, fact: Fact): Unit {
        match (fact.get(field)) {
            case Some(raw) =>
                let key = AlphaMemory.keyOf(raw)
                if (key.isSome()) {
                    let actual = key.getOrThrow()
                    match (index.get(actual)) {
                        case Some(handles) =>
                            var i = 0
                            while (i < handles.size) {
                                if (handles[i] == handle) {
                                    handles.remove(at: i)
                                    break
                                }
                                i += 1
                            }
                            if (handles.isEmpty()) {
                                index.remove(actual)
                            }
                        case None => ()
                    }
                }
            case None => ()
        }
    }

    private func indexOrd(index: ConcurrentSkipListMap<RangeKey, FactHandle>, field: String,
        handle: FactHandle, fact: Fact): Unit {
        match (fact.get(field)) {
            case Some(raw) =>
                let key = AlphaMemory.keyOf(raw)
                if (key.isSome()) {
                    let _ = index.add(RangeKey(key.getOrThrow(), handle.id), handle)
                }
            case None => ()
        }
    }

    private func unindexOrd(index: ConcurrentSkipListMap<RangeKey, FactHandle>, field: String,
        handle: FactHandle, fact: Fact): Unit {
        match (fact.get(field)) {
            case Some(raw) =>
                let key = AlphaMemory.keyOf(raw)
                if (key.isSome()) {
                    let _ = index.remove(RangeKey(key.getOrThrow(), handle.id))
                }
            case None => ()
        }
    }

    private func indexNull(index: HashSet<FactHandle>, field: String, handle: FactHandle,
        fact: Fact): Unit {
        if (fact.get(field).isNone()) {
            let _ = index.add(handle)
        }
    }

    /** 字段缺失或类型不可归一：索引路径跳过，语义由全扫/算子层兜底。 */
    private static func keyOf(raw: Any): ?ValueKey {
        try {
            Some(ValueKey.of(raw))
        } catch (e: Exception) {
            None
        }
    }
}
