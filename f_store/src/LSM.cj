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
package fountain::f_store

import fountain::f_concurrent.ConcurrentSkipListMap
import std.sync.{AtomicInt64, AtomicReference, AtomicOptionReference, Mutex}

/** 内存表，基于 ConcurrentSkipListMap 实现无锁读写 */
class MemTable {
    let table: ConcurrentSkipListMap<ByteArray, EntryValue>
    let byteCount: AtomicInt64

    init() {
        table = ConcurrentSkipListMap<ByteArray, EntryValue>()
        byteCount = AtomicInt64(0)
    }

    func add(key: ByteArray, entry: EntryValue): ?EntryValue {
        let old = table.add(key, entry)
        // 近似计算：key 字节数 + value 字节数 + 元数据开销
        byteCount.fetchAdd(key.bytes.size + (if (let Some(v) <- entry.value) { v.size } else { 0 }) + 24)
        old
    }

    func get(key: ByteArray): ?EntryValue {
        table.get(key)
    }

    func iterator(): Iterator<(ByteArray, EntryValue)> {
        table.iterator()
    }

    func tailer(min: ByteArray): Iterator<(ByteArray, EntryValue)> {
        table.tailer(min)
    }

    func approximateSize(): Int64 {
        byteCount.load()
    }
}

/** 双缓冲管理：active 可写，immutable 刷盘中（只读快照） */
class MemTableManager {
    let active: AtomicReference<MemTable>
    let immutable: AtomicOptionReference<MemTable>
    let flushLock: Mutex

    init() {
        active = AtomicReference<MemTable>(MemTable())
        immutable = AtomicOptionReference<MemTable>()
        flushLock = Mutex()
    }

    /** 将 active 设为 immutable，创建新 active，返回旧 active（可能为 None 如果已被其他线程 swap） */
    func swapActive(): ?MemTable {
        synchronized(flushLock) {
            let old = active.load()
            // 如果 immutable 非空（上次刷盘未完成），不 swap
            if (immutable.load().isSome()) {
                return None
            }
            immutable.store(Some(old))
            active.store(MemTable())
            Some(old)
        }
    }

    func getActive(): MemTable {
        active.load()
    }

    func getImmutable(): ?MemTable {
        immutable.load()
    }

    /** 刷盘完成后清空 immutable 引用 */
    func clearImmutable(): Unit {
        immutable.store(None)
    }
}
