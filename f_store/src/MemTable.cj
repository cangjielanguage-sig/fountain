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

/** 内存表，基于 ConcurrentSkipListMap 实现无锁读写 */
class MemTable {
    let table: ConcurrentSkipListMap<ByteArray, EntryValue>
    let byteCount: AtomicInt64

    // EntryValue 结构开销: sequence(8) + value 引用(8) + expireAt(8) = 24
    static const ENTRY_OVERHEAD: Int64 = 24

    init() {
        table = ConcurrentSkipListMap<ByteArray, EntryValue>()
        byteCount = AtomicInt64(0)
    }

    func add(key: ByteArray, entry: EntryValue): ?EntryValue {
        let old = table.add(key, entry)
        // 增量计算：newSize - oldSize，避免覆盖写导致 byteCount 持续漂移
        let newSize = key.bytes.size + valueSize(entry) + ENTRY_OVERHEAD
        let oldSize = if (let Some(oldEntry) <- old) {
            key.bytes.size + valueSize(oldEntry) + ENTRY_OVERHEAD
        } else {
            0
        }
        byteCount.fetchAdd(newSize - oldSize)
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

/** 获取 EntryValue 中 value 的字节数（None = 0） */
func valueSize(entry: EntryValue): Int64 {
    if (let Some(v) <- entry.value) {
        v.size
    } else {
        0
    }
}
