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

/** 前缀遍历迭代器 — 从多个有序源中归并遍历指定前缀的键值对 */
public class PrefixIterator <: Iterator<(Array<Byte>, Array<Byte>)> & Resource {
    private let prefix: ByteArray
    private let sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>
    /** 当前所有 sources 中最小的 peek key，初始化时计算，每次 next 后更新 */
    private var currentMinKey: ?ByteArray
    private var drained: Bool = false

    init(prefix: ByteArray, sources: ArrayList<PeekableIterator<(ByteArray, EntryValue)>>) {
        this.prefix = prefix
        this.sources = sources
        this.currentMinKey = None
        this.currentMinKey = findMinKey()
    }

    /** 扫描所有 sources，找到当前最小的 peek key */
    private func findMinKey(): ?ByteArray {
        var minKey: ?ByteArray = None
        for (src in sources) {
            if (let Some((k, _)) <- src.peek()) {
                if (let Some(mk) <- minKey) {
                    if (k < mk) {
                        minKey = Some(k)
                    }
                } else {
                    minKey = Some(k)
                }
            }
        }
        minKey
    }

    public func next(): Option<(Array<Byte>, Array<Byte>)> {
        while (let Some(mk) <- currentMinKey) {
            // 不再以 prefix 开头 → 遍历结束
            if (!startsWith(mk, prefix)) {
                close()
                return None
            }

            // 收集所有 peek == mk 的条目，推进对应 source，同时计算下一个 minKey
            var bestEntry: ?EntryValue = None
            var nextMinKey: ?ByteArray = None
            for (src in sources) {
                if (let Some((k, entry)) <- src.peek()) {
                    if (k == mk) {
                        // 取 sequence 最高的
                        if (let Some(be) <- bestEntry) {
                            if (entry.sequence > be.sequence) {
                                bestEntry = Some(entry)
                            }
                        } else {
                            bestEntry = Some(entry)
                        }
                        // 推进此迭代器
                        src.next()
                        // 推进后新 peek 值作为下一个 minKey 候选
                        if (let Some((nextK, _)) <- src.peek()) {
                            if (let Some(nmk) <- nextMinKey) {
                                if (nextK < nmk) {
                                    nextMinKey = Some(nextK)
                                }
                            } else {
                                nextMinKey = Some(nextK)
                            }
                        }
                    } else {
                        // k != mk，作为下一个 minKey 候选
                        if (let Some(nmk) <- nextMinKey) {
                            if (k < nmk) {
                                nextMinKey = Some(k)
                            }
                        } else {
                            nextMinKey = Some(k)
                        }
                    }
                }
            }

            // 缓存下一个 minKey，下次调用直接使用
            currentMinKey = nextMinKey

            // 跳过 tombstone / 过期数据
            if (let Some(entry) <- bestEntry) {
                if (entry.value.isNone()) {
                    continue
                }
                if (let Some(expireAt) <- entry.expireAt) {
                    if (expireAt <= DateTime.now().toUnixTimeStamp().toNanoseconds()) {
                        continue
                    }
                }
                return Some((mk.bytes, entry.value.getOrThrow()))
            }
        }
        close()
        None
    }

    /** 排空所有源，触发 SSTableIterator 自动关闭。实现 Resource 接口。
     *  耗尽或提前退出时自动调用；外部也可用 try-with-resource 提前关闭。 */
    public func close(): Unit {
        if (drained) {
            return
        }
        drained = true
        for (src in sources) {
            while (src.next().isSome()) {}
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
