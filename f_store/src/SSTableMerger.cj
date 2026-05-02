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

import std.collection.ArrayList

/** 优先级队列元素：记录 key 和来源索引 */
class MergeHeapEntry {
    let key: ByteArray
    let sourceIndex: Int64
    init(key: ByteArray, sourceIndex: Int64) {
        this.key = key
        this.sourceIndex = sourceIndex
    }
}

/** 合并比较器：key 小的优先 */
let mergeHeapCmp = {a: MergeHeapEntry, b: MergeHeapEntry =>
    if (a.key < b.key) { LT }
    else if (a.key > b.key) { GT }
    else { EQ }
}

/** 多路归并迭代器：合并多个有序源的 EntryValue
 *  - 全局有序输出（按 key 字典序升序）
 *  - 同 key 取最高 sequence
 *  - 跳过过期数据
 *  - 底层 compaction 移除 tombstone，非底层保留
 */
class SSTableMerger <: Iterator<(ByteArray, EntryValue)> {
    let sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>
    let heap: PriorityQueue<MergeHeapEntry>
    let isBottomLevel: Bool
    let now: Int64

    init(sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>, isBottomLevel!: Bool = false) {
        this.sources = sources
        this.heap = PriorityQueue<MergeHeapEntry>(mergeHeapCmp)
        this.isBottomLevel = isBottomLevel
        this.now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        // 初始化堆：每个源 peek 第一个 key
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
                // sources[idx].next() 返回 None（异常情况：源已耗尽但堆未清理），跳过该源继续
                continue
            }
            return None  // 堆已空，所有源耗尽
        }
        None
    }
}
