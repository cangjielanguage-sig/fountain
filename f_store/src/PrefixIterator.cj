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
import std.time.DateTime

/** 前缀遍历迭代器 — 从多个有序源中归并遍历指定前缀的键值对。
 *  用 PriorityQueue（二叉堆）替代线性扫描，从 O(n) 降至 O(log n)。 */
public class PrefixIterator <: Iterator<(Array<Byte>, Array<Byte>)> & Resource {
    private let prefix: ByteArray
    private let sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>
    private let heap: PriorityQueue<MergeHeapEntry>
    private let now: Int64
    private var drained: Bool = false

    init(prefix: ByteArray, sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>) {
        this.prefix = prefix
        this.sources = sources
        this.now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        this.heap = PriorityQueue<MergeHeapEntry>(mergeHeapCmp)
        for (i in 0..sources.size) {
            if (let Some((key, _)) <- sources[i].peek()) {
                heap.add(MergeHeapEntry(key, i))
            }
        }
    }

    public func next(): Option<(Array<Byte>, Array<Byte>)> {
        if (drained) {
            return None
        }
        while (true) {
            if (let Some(minEntry) <- heap.remove()) {
                let currentKey = minEntry.key
                let idx = minEntry.sourceIndex

                // 不再以 prefix 开头 → 遍历结束
                if (!startsWith(currentKey, prefix)) {
                    close()
                    return None
                }

                // 从该源取出当前条目
                if (let Some((_, entry)) <- sources[idx].next()) {
                    // 该源还有更多则重新入堆
                    if (let Some((nextKey, _)) <- sources[idx].peek()) {
                        heap.add(MergeHeapEntry(nextKey, idx))
                    }

                    // 收集所有同 key 的其他源，取最高 sequence
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
                        if (let Some((nextKey, _)) <- sources[otherIdx].peek()) {
                            heap.add(MergeHeapEntry(nextKey, otherIdx))
                        }
                    }

                    // 跳过 tombstone / 过期数据
                    if (bestEntry.value.isNone()) {
                        continue
                    }
                    if (let Some(expireAt) <- bestEntry.expireAt) {
                        if (expireAt <= this.now) {
                            continue
                        }
                    }
                    return Some((currentKey.bytes, bestEntry.value.getOrThrow()))
                }
            } else {
                // 堆已空，所有源耗尽
                close()
                return None
            }
        }
        None
    }

    /** 直接关闭所有源迭代器（避免逐个排空的 O(n) 解码开销）。
     *  实现 Resource 接口。耗尽或提前退出时自动调用；外部也可用 try-with-resource 提前关闭。 */
    public func close(): Unit {
        if (drained) {
            return
        }
        drained = true
        var baseEx: ?BaseException = None
        for (src in sources) {
            try {
                src.close()
            } catch (e: Exception) {// ⚠ 不能忽略异常，异常必须暴露出去
                if(let Some(ex) <- baseEx){
                    ex.addSuppressed(e)
                }else{
                    baseEx = PrefixIteratorException(e)
                }
            }
        }
        if (let Some(ex) <- baseEx) {
            throw ex
        }
    }

    public func isClosed(): Bool {
        drained
    }
}

/** 判断 key 是否以 prefix 开头 */
public func startsWith(key: ByteArray, prefix: ByteArray): Bool {
    if (key.bytes.size < prefix.bytes.size) {
        return false
    }
    for (i in 0..prefix.bytes.size) {
        if (key.bytes[i] != prefix.bytes[i]) {
            return false
        }
    }
    true
}
public class PrefixIteratorException <: BaseException {
    public init(caused: Exception){
        super(caused)
    }
}