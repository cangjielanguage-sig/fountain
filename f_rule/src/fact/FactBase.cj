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
package fountain::f_rule.fact

import std.collection.{ArrayList, HashMap, HashSet}
import fountain::f_rule.exception.*

/**
 * `(space, session)` 级事实存储（`doc/02-fact-model.md` §6.3）。
 *
 * 只负责存储与 id 分配；业务索引归属 alpha/beta memory，避免两处索引不同步。
 * 句柄 id 在单个 `FactBase` 内单调分配，不同空间/会话可能重复——`FactHandle`
 * 的相等性因此同时比较 `(space, id)`。
 */
public class FactBase {
    private let space_: FactSpace
    private let session_: String
    private var nextId_: Int64
    private let buckets_: HashMap<String, ArrayList<FactHandle>>
    /** `(typeTag, 句柄) → 槽位`；撤销不再线性扫描桶（大规模事实下会退化成 O(n²)）。 */
    private let slots_: HashMap<String, HashMap<FactHandle, Int64>>
    /** 已撤销但仍占槽位的下标；`scan` 跳过，过半时整理一次。 */
    private let dead_: HashMap<String, HashSet<Int64>>
    private let facts_: HashMap<FactHandle, Fact>
    private let byIdentity_: HashMap<Int64, FactHandle>
    private let looseFacts_: ArrayList<Fact>

    public init(space: FactSpace, session: String) {
        this.space_ = space
        this.session_ = session
        this.nextId_ = 1
        this.buckets_ = HashMap<String, ArrayList<FactHandle>>()
        this.slots_ = HashMap<String, HashMap<FactHandle, Int64>>()
        this.dead_ = HashMap<String, HashSet<Int64>>()
        this.facts_ = HashMap<FactHandle, Fact>()
        this.byIdentity_ = HashMap<Int64, FactHandle>()
        this.looseFacts_ = ArrayList<Fact>()
    }

    public prop space: String {
        get() {
            space_.id
        }
    }

    public prop session: String {
        get() {
            session_
        }
    }

    /**
     * 插入事实并返回句柄。
     *
     * `typeTag` 未在该空间注册抛 `UNKNOWN_TYPE`；同一实例重复插入抛 `DUPLICATE_FACT`；
     * `DynamicFact` 插入时自动冻结。
     */
    public func assert(fact: Fact): FactHandle {
        if (!space_.hasType(fact.typeTag)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_TYPE,
                "空间 ${space_.id} 未注册类型 ${fact.typeTag}"
            )
        }
        ensureNotDuplicate(fact, None)
        freezeIfDynamic(fact)

        let handle = FactHandle(space_.id, nextId_, fact.typeTag)
        nextId_ += 1
        facts_[handle] = fact
        let bucket = bucket(fact.typeTag)
        slotIndex(fact.typeTag)[handle] = Int64(bucket.size)
        bucket.add(handle)
        recordIdentity(fact, handle)
        handle
    }

    /** 拷贝字段后插入：用于可变业务对象，避免网络索引跟着原对象变化。 */
    public func assertCopy(fact: Fact): FactHandle {
        let fields = match (space_.descriptor(fact.typeTag)) {
            case Some(desc) => desc.fieldNames()
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_TYPE,
                    "空间 ${space_.id} 未注册类型 ${fact.typeTag}"
                )
        }
        let copy = DynamicFact(fact.typeTag)
        for (field in fields) {
            match (fact.get(field)) {
                case Some(value) => copy.set(field, value)
                case None => ()
            }
        }
        assert(copy)
    }

    /** 撤销事实；不存在时静默返回 false。 */
    public func retract(handle: FactHandle): Bool {
        match (facts_.remove(handle)) {
            case Some(fact) =>
                removeFromBucket(handle)
                forgetIdentity(fact, handle)
                true
            case None => false
        }
    }

    /**
     * 等价于 retract + assert，但保留原句柄 id。
     *
     * 只允许同 `typeTag` 的替换：句柄的 `typeTag` 是桶定位的一部分，跨类型更新会让
     * `scan` 与网络索引失配，因此抛 `ILLEGAL_STATE`。
     */
    public func update(handle: FactHandle, fact: Fact): Bool {
        if (handle.space != space_.id) {
            return false
        }
        match (facts_.get(handle)) {
            case Some(old) =>
                if (fact.typeTag != handle.typeTag) {
                    throw RuleException(
                        RuleErrorCode.ILLEGAL_STATE,
                        "update 不允许改变 typeTag: ${handle.typeTag} -> ${fact.typeTag}"
                    )
                }
                ensureNotDuplicate(fact, Some(handle))
                freezeIfDynamic(fact)
                facts_[handle] = fact
                forgetIdentity(old, handle)
                recordIdentity(fact, handle)
                true
            case None => false
        }
    }

    public func get(handle: FactHandle): ?Fact {
        facts_.get(handle)
    }

    /** 按类型枚举句柄，保持插入顺序。 */
    public func scan(typeTag: String): Array<FactHandle> {
        let handles = match (buckets_.get(typeTag)) {
            case Some(found) => found
            case None => return Array<FactHandle>()
        }
        let dead = deadOf(typeTag)
        let out = ArrayList<FactHandle>()
        var i: Int64 = 0
        while (i < Int64(handles.size)) {
            if (!dead.contains(i)) {
                out.add(handles[i])
            }
            i += 1
        }
        out.toArray()
    }

    public func size(): Int64 {
        facts_.size
    }

    public func clear(): Unit {
        facts_.clear()
        buckets_.clear()
        slots_.clear()
        dead_.clear()
        byIdentity_.clear()
        looseFacts_.clear()
    }

    private func bucket(typeTag: String): ArrayList<FactHandle> {
        match (buckets_.get(typeTag)) {
            case Some(handles) => handles
            case None =>
                let handles = ArrayList<FactHandle>()
                buckets_[typeTag] = handles
                handles
        }
    }

    private func slotIndex(typeTag: String): HashMap<FactHandle, Int64> {
        match (slots_.get(typeTag)) {
            case Some(found) => found
            case None =>
                let created = HashMap<FactHandle, Int64>()
                slots_[typeTag] = created
                created
        }
    }

    private func deadOf(typeTag: String): HashSet<Int64> {
        match (dead_.get(typeTag)) {
            case Some(found) => found
            case None =>
                let created = HashSet<Int64>()
                dead_[typeTag] = created
                created
        }
    }

    /** 撤销桶内句柄：标记墓碑，过半时整理（保持 `scan` 的插入顺序）。 */
    private func removeFromBucket(handle: FactHandle): Unit {
        let slots = slotIndex(handle.typeTag)
        let slot = match (slots.remove(handle)) {
            case Some(found) => found
            case None => return
        }
        let dead = deadOf(handle.typeTag)
        dead.add(slot)
        let handles = bucket(handle.typeTag)
        if (Int64(dead.size) * 2 <= Int64(handles.size)) {
            return
        }
        let kept = ArrayList<FactHandle>()
        var i: Int64 = 0
        while (i < Int64(handles.size)) {
            if (!dead.contains(i)) {
                slots[handles[i]] = Int64(kept.size)
                kept.add(handles[i])
            }
            i += 1
        }
        handles.clear()
        for (item in kept) {
            handles.add(item)
        }
        dead.clear()
    }

    private func recordIdentity(fact: Fact, handle: FactHandle): Unit {
        match (fact as IdentifiedFact) {
            case Some(identified) => byIdentity_[identified.identity] = handle
            case None => looseFacts_.add(fact)
        }
    }

    private func forgetIdentity(fact: Fact, handle: FactHandle): Unit {
        match (fact as IdentifiedFact) {
            case Some(identified) =>
                match (byIdentity_.get(identified.identity)) {
                    case Some(existing) =>
                        if (existing == handle) {
                            byIdentity_.remove(identified.identity)
                        }
                    case None => ()
                }
            case None =>
                var i = 0
                while (i < looseFacts_.size) {
                    if (FactBase.sameReference(looseFacts_[i], fact)) {
                        looseFacts_.remove(at: i)
                        break
                    }
                    i += 1
                }
        }
    }

    private func ensureNotDuplicate(fact: Fact, replacing: ?FactHandle): Unit {
        match (fact as IdentifiedFact) {
            case Some(identified) =>
                match (byIdentity_.get(identified.identity)) {
                    case Some(existing) =>
                        let same = match (replacing) {
                            case Some(handle) => existing == handle
                            case None => false
                        }
                        if (!same) {
                            throw RuleException(
                                RuleErrorCode.DUPLICATE_FACT,
                                "同一事实实例被重复 assert: ${existing}"
                            )
                        }
                    case None => ()
                }
            case None =>
                for (existing in looseFacts_) {
                    let same = sameReference(existing, fact)
                    if (same) {
                        throw RuleException(
                            RuleErrorCode.DUPLICATE_FACT,
                            "同一事实实例被重复 assert"
                        )
                    }
                }
        }
    }

    private static func sameReference(left: Fact, right: Fact): Bool {
        match ((left as Object, right as Object)) {
            case (Some(a), Some(b)) => refEq(a, b)
            case _ => false
        }
    }

    private func freezeIfDynamic(fact: Fact): Unit {
        match (fact as DynamicFact) {
            case Some(dynamic) => dynamic.freeze()
            case None => ()
        }
    }
}
