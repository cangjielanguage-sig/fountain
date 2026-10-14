/*
Copyright (c) 2025 WuJingrun（吴京润）

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

package fountain::f_ticktock

import std.collection.{ArrayList, HashMap, HashSet}

/** 索引里登记的一个任务。 */
class TicktockEntry {
    let name: String
    let task: TicktockTask
    let crons: Collection<CronDataCollection>

    init(name: String, task: TicktockTask, crons: Collection<CronDataCollection>) {
        this.name = name
        this.task = task
        this.crons = crons
    }
}

/**
 * 运行期时间索引：把每个 tick "遍历全部任务"降为"只遍历候选任务"。
 *
 * 每个时间单位维护三组任务下标：
 * - `buckets[值]`：该单位的允许值集合包含该值。`L` 按该单位的 lastRange 展开进值桶
 *   （日字段是 28..=31，其余单位的 L 是固定值；matches 的真值集合等于该区间），
 *   因此 L 任务只在对应候选区间参与求交，不再每 tick 进候选；
 * - `wildcard`  ：该单位未约束（表达式里该字段等价于 *）；
 * - `dynamic`   ：年字段被约束（年份无上限，不做值桶）。
 *
 * 另有 `always`：所有单位都未约束的"恒真"任务（如 `* * * * * *`），
 * 不进任何单位的集合（省去 7 份重复登记与求交），收集候选时无条件加入。
 *
 * 索引只用于排除"不可能在本 tick 触发"的任务，最终是否触发仍由
 * CronDataCollection.matches(now) 判定，因此不会改变任何既有语义。
 * 本类不做同步，调用方（Ticktock.indexLock）负责串行化。
 */
class TicktockIndex {
    private let units_ = TicktockUnit.values
    private let buckets = HashMap<Int64, HashMap<Int64, HashSet<Int64>>>()
    private let wildcard = HashMap<Int64, HashSet<Int64>>()
    private let dynamic = HashMap<Int64, HashSet<Int64>>()
    /** 恒真任务（所有单位都未约束）。 */
    private let always = HashSet<Int64>()
    /** 平凡单位：只有 wildcard（没有任何任务约束它），求交时不可能过滤掉任何任务，直接跳过。 */
    private let trivial = HashMap<Int64, Bool>()

    init() {
        for (u in units_) {
            buckets[u.value] = HashMap<Int64, HashSet<Int64>>()
            wildcard[u.value] = HashSet<Int64>()
            dynamic[u.value] = HashSet<Int64>()
            trivial[u.value] = true
        }
    }

    /**
     * 把一个任务的某个 cron（`|` 分隔的一组表达式之一）登记进索引。
     *
     * 全通配任务（所有单位都未约束）只登记进 `always`；
     * 其余任务按单位写入值桶 / wildcard / dynamic。
     */
    func add(id: Int64, cron: CronDataCollection): Unit {
        var constrained = false
        for (u in units_) {
            match (cron.get(u)) {
                case Some(crons) =>
                    constrained = true
                    for (c in crons) {
                        if (u == TicktockUnit.YEARLY) {
                            dynamic[u.value].add(id)
                        } else {
                            // `L` 的 range 就是该单位的 lastRange（如日字段 28..=31），
                            // 按它展开即 matches 真值集合的超集（此处实际为精确集合）
                            var v = c.start
                            let step = c.duration
                            while (v <= c.end) {
                                if (step == 1 || ((v - c.start) % step) == 0) {
                                    put(u.value, v, id)
                                }
                                v += 1
                            }
                        }
                        trivial[u.value] = false
                    }
                case None => ()
            }
        }
        if (!constrained) {
            always.add(id)
            return
        }
        for (u in units_) {
            match (cron.get(u)) {
                case Some(_) => ()
                case None => wildcard[u.value].add(id)
            }
        }
    }

    /** 从索引里摘除一个任务（值桶按单位全量扫描，单次移除成本为常数级）。 */
    func removeId(id: Int64): Unit {
        always.remove(id)
        for (u in units_) {
            wildcard[u.value].remove(id)
            dynamic[u.value].remove(id)
            let byValue = buckets[u.value]
            var stillUsed = !dynamic[u.value].isEmpty()
            for ((_, set) in byValue) {
                set.remove(id)
                if (!set.isEmpty()) {
                    stillUsed = true
                }
            }
            trivial[u.value] = !stillUsed
        }
    }

    /**
     * 计算本 tick 的候选任务（可能偏多，但绝不遗漏）。
     *
     * 先从"选择性最高"的非平凡单位取候选集，再逐个非平凡单位求交，
     * 最后交由 matches 精确判定。
     */
    func candidates(now: DateTime, buffer: ArrayList<Int64>): Unit {
        var bestUnit = units_[0]
        var bestValue = bestUnit.current(now)
        var bestSize = Int64.Max
        for (u in units_) {
            if (trivial[u.value]) {
                continue
            }
            let v = u.current(now)
            let s = sizeAt(u.value, v)
            if (s < bestSize) {
                bestSize = s
                bestUnit = u
                bestValue = v
            }
        }
        buffer.clear()
        collect(bestUnit.value, bestValue, buffer)
        for (u in units_) {
            if (buffer.size == 0) {
                break
            }
            if (u.value == bestUnit.value || trivial[u.value]) {
                continue
            }
            filterInPlace(u.value, u.current(now), buffer)
        }
    }

    private func put(unit: Int64, value: Int64, id: Int64): Unit {
        let byValue = buckets[unit]
        match (byValue.get(value)) {
            case Some(set) => set.add(id)
            case None =>
                let set = HashSet<Int64>()
                set.add(id)
                byValue[value] = set
        }
    }

    private func sizeAt(unit: Int64, value: Int64): Int64 {
        // always 是各单位的公共常量，只影响 argmin 的绝对值、不影响挑选结果
        var n = wildcard[unit].size + dynamic[unit].size + always.size
        match (buckets[unit].get(value)) {
            case Some(set) => n += set.size
            case None => ()
        }
        n
    }

    private func collect(unit: Int64, value: Int64, into: ArrayList<Int64>): Unit {
        for (id in always) {
            into.add(id)
        }
        match (buckets[unit].get(value)) {
            case Some(set) =>
                for (id in set) {
                    into.add(id)
                }
            case None => ()
        }
        for (id in wildcard[unit]) {
            into.add(id)
        }
        for (id in dynamic[unit]) {
            into.add(id)
        }
    }

    private func keep(unit: Int64, value: Int64, id: Int64): Bool {
        if (always.contains(id) || wildcard[unit].contains(id) || dynamic[unit].contains(id)) {
            return true
        }
        match (buckets[unit].get(value)) {
            case Some(set) => return set.contains(id)
            case None => return false
        }
    }

    private func filterInPlace(unit: Int64, value: Int64, buffer: ArrayList<Int64>): Unit {
        let total = buffer.size
        var write = 0
        var read = 0
        while (read < total) {
            let id = buffer[read]
            if (keep(unit, value, id)) {
                buffer[write] = id
                write += 1
            }
            read += 1
        }
        var i = buffer.size
        while (i > write) {
            buffer.remove(at: i - 1)
            i -= 1
        }
    }
}
