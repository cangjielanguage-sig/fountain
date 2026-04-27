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
