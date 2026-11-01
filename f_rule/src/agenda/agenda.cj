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
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.rule.{ConflictKey, ConflictResolver}

/**
 * 执行模式（`doc/05-agenda-conflict-resolution.md` §5）。
 *
 * - `Refract`：执行后立即失效，即使条件仍成立也不重复触发（默认）；
 * - `NoLoop`：同一规则同一绑定在整次 `fire` 内只执行一次；
 * - `Loop`：允许重复触发，直到议程为空或达到 `limit`。
 */
public enum FireMode <: ToString & Equatable<FireMode> {
    | Refract
    | NoLoop
    | Loop

    public func toString(): String {
        match (this) {
            case Refract => "Refract"
            case NoLoop => "NoLoop"
            case Loop => "Loop"
        }
    }

    public operator func ==(other: FireMode): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: FireMode): Bool {
        !(this == other)
    }
}

/** 一次激活执行的输出槽（决策表的行级结果）。 */
public class FireRecord {
    public let ruleId: String
    public let outputs: HashMap<String, Any>

    public init(ruleId: String, outputs: HashMap<String, Any>) {
        this.ruleId = ruleId
        this.outputs = outputs
    }
}

/**
 * 激活执行器：把"执行动作"从议程里解耦。
 *
 * 生产路径由 `RuleSession` 注入动作上下文；议程单测注入记录器即可验证排序与循环语义。
 */
public interface ActionRunner {
    /** 执行一个激活的动作，返回本次输出槽。 */
    func run(activation: Activation): HashMap<String, Any>
}

/** 不执行任何动作的默认执行器（只走排序与计数）。 */
public class NoopRunner <: ActionRunner {
    public init() {}

    public func run(activation: Activation): HashMap<String, Any> {
        let _ = activation
        HashMap<String, Any>()
    }
}

/**
 * 议程（`doc/05-agenda-conflict-resolution.md` §3）。
 *
 * session 级：不同空间的激活进同一队列，按同一策略排序；执行只作用于激活所属空间。
 *
 * 内部是**惰性二叉堆**：`remove` 只改有效性索引，不做队列中间删除；
 * `fire` 取堆顶后校验索引，失效即丢弃继续取（O(log n) 均摊）。
 */
public class Agenda <: ActivationSink {
    private let resolver_: ConflictResolver
    private let runner_: ActionRunner
    private let cycle_: ?CycleDetector
    private var mode_: FireMode
    private let heap_: ArrayList<Activation>
    private let index_: HashMap<Activation, Bool>
    private var firing_: Bool
    private let lastOutputs_: HashMap<String, Any>
    private let lastFired_: ArrayList<FireRecord>

    public init(resolver: ConflictResolver, mode!: FireMode = FireMode.Refract,
        runner!: ActionRunner = NoopRunner(), cycle!: ?CycleDetector = None) {
        this.resolver_ = resolver
        this.runner_ = runner
        this.cycle_ = cycle
        this.mode_ = mode
        this.heap_ = ArrayList<Activation>()
        this.index_ = HashMap<Activation, Bool>()
        this.firing_ = false
        this.lastOutputs_ = HashMap<String, Any>()
        this.lastFired_ = ArrayList<FireRecord>()
    }

    /** 新激活进入议程；重复激活被丢弃。 */
    public func add(activation: Activation): Unit {
        if (index_.contains(activation)) {
            return
        }
        index_[activation] = true
        heap_.add(activation)
        siftUp(heap_.size - 1)
    }

    /** Rete 撤销时同步移除；不存在时静默返回。只改有效性位。 */
    public func remove(activation: Activation): Unit {
        let _ = index_.remove(activation)
    }

    /**
     * 执行循环。
     *
     * @param limit 最多执行多少个激活；-1 表示不限制
     * @return 实际执行的激活数
     */
    public func fire(limit!: Int64 = -1): Int64 {
        if (firing_) {
            throw RuleException(RuleErrorCode.REENTRANT_FIRE, "议程正在执行，不允许重入 fire")
        }
        firing_ = true
        lastOutputs_.clear()
        lastFired_.clear()
        var count: Int64 = 0
        let fired = HashMap<Activation, Bool>()
        try {
            while (true) {
                if (limit >= 0 && count >= limit) {
                    break
                }
                let picked = popValid()
                if (picked.isNone()) {
                    break
                }
                let activation = picked.getOrThrow()
                var skip = false
                match (mode_) {
                    case Refract =>
                        // 弹出即失效：即使条件仍成立也不再执行
                        let _ = index_.remove(activation)
                    case NoLoop =>
                        if (fired.contains(activation)) {
                            let _ = index_.remove(activation)
                            skip = true
                        } else {
                            fired[activation] = true
                            let _ = index_.remove(activation)
                        }
                    case Loop => ()
                }
                if (skip) {
                    continue
                }
                match (cycle_) {
                    case Some(detector) => detector.record(activation)
                    case None => ()
                }
                let outputs = runOne(activation)
                lastFired_.add(FireRecord(activation.ruleId, outputs))
                count += 1
                // 互斥组：首个激活执行后，同组其余激活全部失效（doc/11 §4.4）
                match (activation.activationGroup) {
                    case Some(group) => invalidateGroup(group, activation)
                    case None => ()
                }
                match (mode_) {
                    case Loop =>
                        // 仍有效则放回堆，等待下一轮或 limit 终止
                        if (index_.contains(activation)) {
                            heap_.add(activation)
                            siftUp(heap_.size - 1)
                        }
                    case _ => ()
                }
            }
        } finally {
            firing_ = false
        }
        count
    }

    public prop mode: FireMode {
        get() {
            mode_
        }
    }

    public func setMode(mode: FireMode): Unit {
        mode_ = mode
    }

    /**
     * 移除同组剩余激活（`doc/11-assembly.md` §4.4）。
     *
     * `except` 是刚刚执行的激活，保留它以支持 `Loop` 模式回堆；其余同组激活只改有效性位，
     * 惰性堆会在后续弹出时丢弃。组语义限定为「已进入议程的同组激活」，未命中行从未入队。
     */
    public func invalidateGroup(group: String, except: Activation): Unit {
        // 保留刚刚执行的激活；其余同组激活失效
        let doomed = ArrayList<Activation>()
        for ((item, _) in index_) {
            match (item.activationGroup) {
                case Some(found) =>
                    if (found == group && !(item == except)) {
                        doomed.add(item)
                    }
                case None => ()
            }
        }
        for (item in doomed) {
            let _ = index_.remove(item)
        }
    }

    public func size(): Int64 {
        index_.size
    }

    public func clear(): Unit {
        heap_.clear()
        index_.clear()
        lastOutputs_.clear()
        lastFired_.clear()
    }

    /** 当前待执行激活，按优先级升序（不改变队列）。 */
    public func snapshot(): Array<Activation> {
        let valid = ArrayList<Activation>()
        for (item in heap_) {
            if (index_.contains(item)) {
                valid.add(item)
            }
        }
        sortInPlace(valid)
        valid.toArray()
    }

    /** 最近一次 `fire` 合并后的输出槽。 */
    public func lastOutputs(): HashMap<String, Any> {
        let copy = HashMap<String, Any>()
        for ((key, value) in lastOutputs_) {
            copy[key] = value
        }
        copy
    }

    /** 最近一次 `fire` 的逐条执行记录（规则 id + 输出槽）。 */
    public func lastFired(): Array<FireRecord> {
        lastFired_.toArray()
    }

    private func runOne(activation: Activation): HashMap<String, Any> {
        var outputs = HashMap<String, Any>()
        try {
            outputs = runner_.run(activation)
        } catch (e: RuleException) {
            // 已是统一异常（如 REENTRANT_FIRE / CYCLE_LIMIT）：原样上抛，不再套一层
            throw e
        } catch (e: Exception) {
            throw RuleException(
                RuleErrorCode.ACTION_FAILED,
                "规则 ${activation.ruleId} 的动作执行失败: ${e.message}",
                e
            )
        }
        for ((key, value) in outputs) {
            lastOutputs_[key] = value
        }
        outputs
    }

    /** 取堆顶有效激活；失效的堆顶直接丢弃。 */
    private func popValid(): ?Activation {
        while (!heap_.isEmpty()) {
            let top = popHeap()
            if (index_.contains(top)) {
                return Some(top)
            }
        }
        None
    }

    private func popHeap(): Activation {
        let top = heap_[0]
        let last = heap_[heap_.size - 1]
        heap_.remove(at: heap_.size - 1)
        if (!heap_.isEmpty()) {
            heap_[0] = last
            siftDown(0)
        }
        top
    }

    private func siftUp(start: Int64): Unit {
        var child = start
        while (child > 0) {
            let parent = (child - 1) / 2
            if (compare(heap_[child], heap_[parent]) != Ordering.LT) {
                break
            }
            swap(child, parent)
            child = parent
        }
    }

    private func siftDown(start: Int64): Unit {
        var parent = start
        while (true) {
            let left = parent * 2 + 1
            if (left >= heap_.size) {
                break
            }
            var smallest = parent
            if (compare(heap_[left], heap_[smallest]) == Ordering.LT) {
                smallest = left
            }
            let right = left + 1
            if (right < heap_.size && compare(heap_[right], heap_[smallest]) == Ordering.LT) {
                smallest = right
            }
            if (smallest == parent) {
                break
            }
            swap(parent, smallest)
            parent = smallest
        }
    }

    private func swap(left: Int64, right: Int64): Unit {
        let tmp = heap_[left]
        heap_[left] = heap_[right]
        heap_[right] = tmp
    }

    private func compare(left: Activation, right: Activation): Ordering {
        resolver_.compare(keyOf(left), keyOf(right))
    }

    private static func keyOf(activation: Activation): ConflictKey {
        ConflictKey(activation.salience, activation.specificity, activation.ruleOrder,
            activation.seq, activation.factSpace, activation.ruleId)
    }

    /** 小规模排序（`snapshot` 与调试路径），用插入排序保持稳定且无额外分配。 */
    private func sortInPlace(items: ArrayList<Activation>): Unit {
        var i = 1
        while (i < items.size) {
            let current = items[i]
            var j = i - 1
            while (j >= 0 && compare(items[j], current) == Ordering.GT) {
                items[j + 1] = items[j]
                j -= 1
            }
            items[j + 1] = current
            i += 1
        }
    }
}
