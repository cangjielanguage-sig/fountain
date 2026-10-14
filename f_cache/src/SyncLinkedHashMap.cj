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

import std.sync.Mutex
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
     * 锁内删除：谓词在段写锁内执行，必须廉价且不得阻塞或回访本缓存；
     * 定时清扫（判定与删除需原子、谓词是内部代码）用它。
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
}

class SyncLinkedHashMapIterator<V> <: Iterator<(String, V)> {
    SyncLinkedHashMapIterator(private let itr: Iterator<(String, V)>, private let mtx: Mutex) {}
    public func next(): ?(String, V) {
        synchronized(mtx) {
            itr.next()
        }
    }
}
