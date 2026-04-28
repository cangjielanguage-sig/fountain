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

/** 多路归并迭代器：将多个有序迭代器合并为一个有序流。
 *  相同 key 取 sequence 最高的 EntryValue。
 *  过期数据在遍历时跳过（惰性过期）。
 *  tombstone 保留策略由 isBottomLevel 决定：最底层 Compaction 时移除 tombstone。
 */
class SSTableMerger <: Iterator<(ByteArray, EntryValue)> {
    private let sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>
    private let isBottomLevel: Bool
    private let now: Int64

    init(sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>, isBottomLevel!: Bool = false) {
        this.sources = sources
        this.isBottomLevel = isBottomLevel
        this.now = DateTime.now().toUnixTimeStamp().toNanoseconds()
    }

    public func next(): Option<(ByteArray, EntryValue)> {
        while (true) {
            // 1. 找 peek 最小 key 的迭代器
            var minKey: ?ByteArray = None
            var minIdx: Int64 = -1
            for (i in 0..sources.size) {
                if (let Some((key, _)) <- sources[i].peek()) {
                    if (minKey.isNone() || key < minKey.getOrThrow()) {
                        minKey = Some(key)
                        minIdx = i
                    }
                }
            }
            if (minIdx < 0) {
                return None // 所有源已耗尽
            }
            let currentKey = minKey.getOrThrow()

            // 2. 收集所有源中 key == currentKey 的条目，取最高 sequence
            var bestEntry: ?EntryValue = None
            var bestSeq: Int64 = -1
            for (i in 0..sources.size) {
                if (let Some((key, entry)) <- sources[i].peek()) {
                    if (key == currentKey) {
                        if (entry.sequence > bestSeq) {
                            bestSeq = entry.sequence
                            bestEntry = Some(entry)
                        }
                    }
                }
            }

            // 3. 推进所有 key == currentKey 的迭代器
            for (i in 0..sources.size) {
                if (let Some((key, _)) <- sources[i].peek()) {
                    if (key == currentKey) {
                        sources[i].next()
                    }
                }
            }

            if (let Some(entry) <- bestEntry) {
                // 4. 过期检查：跳过已过期数据
                if (let Some(expireAt) <- entry.expireAt) {
                    if (expireAt <= now) {
                        continue // 跳过过期数据
                    }
                }
                // 5. tombstone 处理：最底层 Compaction 时移除
                if (entry.value.isNone()) {
                    if (isBottomLevel) {
                        continue // 最底层移除 tombstone
                    }
                    // 非最底层保留 tombstone
                    return Some((currentKey, entry))
                }
                return Some((currentKey, entry))
            }
        }
        None
    }
}
