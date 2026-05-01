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

/** 堆条目：关联 key 与源迭代器索引 */
class MergeHeapEntry {
    let key: ByteArray
    let sourceIndex: Int64
    init(key: ByteArray, sourceIndex: Int64) {
        this.key = key
        this.sourceIndex = sourceIndex
    }
}

/** 堆比较器：按 key 字典序 */
let mergeHeapCmp = { a: MergeHeapEntry, b: MergeHeapEntry =>
    if (a.key < b.key) { LT }
    else if (a.key > b.key) { GT }
    else { EQ }
}

/** 多路归并迭代器：将多个有序迭代器合并为一个有序流。
 *  相同 key 取 sequence 最高的 EntryValue。
 *  过期数据在遍历时跳过（惰性过期）。
 *  tombstone 保留策略由 isBottomLevel 决定：最底层 Compaction 时移除 tombstone。
 *
 *  性能优化：用 PriorityQueue（二叉堆）替代线性扫描，从 O(n×m) 降至 O(n×log m)。
 */
class SSTableMerger <: Iterator<(ByteArray, EntryValue)> {
    private let sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>
    private let isBottomLevel: Bool
    private let now: Int64
    private let heap: PriorityQueue<MergeHeapEntry>

    init(sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>, isBottomLevel!: Bool = false) {
        this.sources = sources
        this.isBottomLevel = isBottomLevel
        this.now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        this.heap = PriorityQueue<MergeHeapEntry>(mergeHeapCmp)
        // 初始将所有源的首个 key 入堆
        for (i in 0..sources.size) {
            if (let Some((key, _)) <- sources[i].peek()) {
                heap.add(MergeHeapEntry(key, i))
            }
        }
    }

    public func next(): Option<(ByteArray, EntryValue)> {
        while (true) {
            // 1. 从堆中弹出最小 key 的源
            if (let Some(minEntry) <- heap.remove()) {
                let currentKey = minEntry.key
                let idx = minEntry.sourceIndex

                // 2. 从该源取出当前条目
                if (let Some((_, entry)) <- sources[idx].next()) {
                    // 3. 如果该源还有更多数据，peek 下一 key 并重新入堆
                    if (let Some((nextKey, _)) <- sources[idx].peek()) {
                        heap.add(MergeHeapEntry(nextKey, idx))
                    }

                    // 4. 收集所有同 key 的其他源，取最高 sequence
                    var bestEntry = entry
                    var bestSeq = entry.sequence
                    while (let Some(nextEntry) <- heap.peek()) {
                        if (nextEntry.key != currentKey) {
                            break
                        }
                        heap.remove()
                        let otherIdx = nextEntry.sourceIndex
                        if (let Some((_, otherEntry)) <- sources[otherIdx].next()) {
                            if (otherEntry.sequence > bestSeq) {
                                bestSeq = otherEntry.sequence
                                bestEntry = otherEntry
                            }
                        }
                        // 该源还有更多数据则重新入堆
                        if (let Some((nextKey, _)) <- sources[otherIdx].peek()) {
                            heap.add(MergeHeapEntry(nextKey, otherIdx))
                        }
                    }

                    // 5. 过期检查
                    if (let Some(expireAt) <- bestEntry.expireAt) {
                        if (expireAt <= now) {
                            continue
                        }
                    }
                    // 6. tombstone 处理
                    if (bestEntry.value.isNone()) {
                        if (isBottomLevel) {
                            continue
                        }
                        return Some((currentKey, bestEntry))
                    }
                    return Some((currentKey, bestEntry))
                }
            }
            return None  // 堆已空，所有源耗尽
        }
        None
    }
}
