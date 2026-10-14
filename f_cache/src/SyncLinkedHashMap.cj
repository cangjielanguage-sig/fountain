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
package fountain::f_cache

import std.sync.{Mutex, AtomicInt64}
import std.collection.ArrayList
import fountain::f_collection.LinkedHashMap

/**
 * 段内哈希表 + 互斥锁。
 *
 * 段锁用 Mutex 而非 ReadWriteLock 的原因（实测见 cron-bench/logs/heapcache/perf-audit-2026-10-14.md）：
 * - std 的读锁为「每线程读计数」维护 ThreadLocal（一次 lock+unlock 约 4 次 ThreadLocal 访问），
 *   无人竞争也要 ~517 ns；Mutex（runtime 原生实现）无竞争约 20 ns。
 * - `get` 经 LinkedHashMap.get 维护 LRU 链表序（turnToTail 写链表指针），本身就是写操作，
 *   互斥保护同时消除「读锁下多读者并发改链表」的竞争。
 * 链表序（头 = 该段最久未访问）是 HeapCache 淘汰采样的依据，不能省。
 */
class SyncLinkedHashMap<V> <: Collection<(String, V)> {
    private let mtx = Mutex()
    private let map = LinkedHashMap<String, V>()
    /**
     * 本段条目的「最小死亡时间下界」（Unix 纳秒，只降不升的保守值）。
     * 定时清扫据此跳过不可能有到期条目的段：稳定态下每 tick 只做一次原子读。
     */
    private let minDeath = AtomicInt64(Int64.Max)
    /**下界被下调的版本号：sweepLocked 用它判断「遍历期间是否有新条目下调」，避免重算覆盖新值*/
    private let deathVer = AtomicInt64(0)
    public func iterator(): Iterator<(String, V)> {
        SyncLinkedHashMapIterator<V>(map.iterator(), mtx)
    }
    public func get(key: String): ?V {
        synchronized(mtx) {
            map.get(key)
        }
    }
    public func contains(key: String): Bool {
        synchronized(mtx) {
            map.contains(key)
        }
    }
    public func add(key: String, value: V): ?V {
        synchronized(mtx) {
            map.add(key, value)
        }
    }
    /**
     * 与 computeIfAbsent 相同，但同时返回「本次是否真的新建了条目」，
     * 供调用方（ConcHashMap）记账 size —— 本类不再单独提供只返回值的重载。
     *
     * callable 在段写锁**之外**执行：同一键可能被并发计算多次，但只有第一次的结果会被写入，
     * 之后的调用要么读到先写入的值（返回 false），要么把自己的计算结果丢弃。
     */
    public func computeIfAbsentCounted(key: String, callable: () -> V): (V, Bool) {
        if (let Some(v) <- get(key)) {
            (v, false)
        } else {
            let computed = callable()
            synchronized(mtx) {
                if (let Some(v) <- map.get(key)) {
                    (v, false)
                } else {
                    map.add(key, computed)
                    (computed, true)
                }
            }
        }
    }
    public func remove(key: String): ?V {
        synchronized(mtx) {
            map.remove(key)
        }
    }
    /**
     * 锁内删除：谓词在段写锁内执行，必须廉价且不得阻塞或回访本缓存。
     * 约定与 `Collection.removeIf` 一致：谓词返回 true 的条目被删除（`sweepLocked` 依赖该约定）。
     */
    func removeIfLocked(predicate: (String, V) -> Bool): Unit {
        synchronized(mtx) {
            map.removeIf(predicate)
        }
    }

    /**
     * 两阶段删除：锁下取快照 → **锁外**跑谓词 → 锁下按 key 删。用户谓词不阻塞同段读写。
     * 代价：谓词看到的是快照，两阶段之间新写入的条目也可能因「快照里的值满足谓词」而被删除。
     * 返回实际删除的条目数。
     */
    func removeIfOutside(predicate: (String, V) -> Bool): Int64 {
        let snapshot = synchronized(mtx) {
            let copy = ArrayList<(String, V)>()
            for (entry in map) {
                copy.add(entry)
            }
            copy
        }
        let victims = ArrayList<String>()
        for ((k, v) in snapshot) {
            if (predicate(k, v)) {
                victims.add(k)
            }
        }
        if (victims.isEmpty()) {
            return 0
        }
        synchronized(mtx) {
            var removed = 0
            for (key in victims) {
                if (let Some(_) <- map.remove(key)) {
                    removed++
                }
            }
            removed
        }
    }
    public prop size: Int64 {
        get() {
            synchronized(mtx) {
                map.size
            }
        }
    }
    public func isEmpty(): Bool {
        synchronized(mtx) {
            map.isEmpty()
        }
    }
    public func clear(): Unit {
        synchronized(mtx) {
            map.clear()
        }
    }
    /**
     * 登记一个条目的死亡时间（Unix 纳秒）：把本段下界**下调**到不超过它（只降不升，保守）。
     * 保守方向安全：实际最小值可能更小 ⇒ 只是多扫；绝不会因为漏登记而漏清。
     */
    func noteDeathNanos(nanos: Int64): Unit {
        while (true) {
            let cur = minDeath.load()
            if (nanos >= cur) {
                return
            }
            if (minDeath.compareAndSwap(cur, nanos)) {
                deathVer.fetchAdd(1)
                return
            }
        }
    }
    /**本段下界（Unix 纳秒）；Int64.Max 表示段内没有已知到期的条目*/
    prop minDeathNanos: Int64 {
        get() {
            minDeath.load()
        }
    }
    /**
     * 锁内清扫本段：probe 在段锁内执行，返回 (是否已过期/应删除, 该条目的死亡时间纳秒)。
     * 遍历结束后把下界**重算**为「保留条目的最小死亡时间」—— 只有当遍历期间没有任何
     * 新登记（版本号未变）时才写回，否则保持旧值（下次 tick 再扫），避免覆盖新条目的更早死亡时间。
     * 返回值：实际删除的条目数。
     */
    func sweepLocked(probe: (String, V) -> (Bool, Int64)): Int64 {
        synchronized(mtx) {
            let ver0 = deathVer.load()
            //仓颉不允许闭包捕获 var：用「不可变引用 + 可变字段」回写统计值
            let st = SweepStats()
            map.removeIf {k, v =>
                let (dead, d) = probe(k, v)
                if (dead) {
                    st.removed++
                    true//removeIf 的约定：谓词返回 true ⇒ 删除
                } else {
                    if (d < st.minDeath) {
                        st.minDeath = d
                    }
                    false
                }
            }
            if (deathVer.load() == ver0) {
                minDeath.store(st.minDeath)
            }
            st.removed
        }
    }
}

/**sweepLocked 的统计载体（闭包内回写用）*/
class SweepStats {
    var removed = 0
    var minDeath = Int64.Max
}

class SyncLinkedHashMapIterator<V> <: Iterator<(String, V)> {
    SyncLinkedHashMapIterator(private let itr: Iterator<(String, V)>, private let mtx: Mutex) {}
    public func next(): ?(String, V) {
        synchronized(mtx) {
            itr.next()
        }
    }
}
