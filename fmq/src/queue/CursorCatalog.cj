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
package fountain::fmq.queue

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import fountain::f_io.LogPosition
import fountain::f_log.*
import fountain::fmq.meta.MetaStore

/**
 * 消费位点的统一入口：磁盘落盘 + 内存缓存 + 段保留边界。
 *
 * 段 TTL 必须以**全部已注册组**的位点为边界，而不只是内存里懒建的游标：
 * 离线组的位点只在磁盘上，按内存游标删段会把慢组积压直接删掉（A44）。
 *
 * `floorOf(topic, queue)` 返回该队列所有已注册组位点的最小段号：
 * - 组从未消费（无位点文件）→ 视为 1，历史段全部保留；
 * - 无组 → 1；
 * - 位点文件损坏 → 按缺失处理（1），并记 ERROR。
 */
protected class CursorCatalog {
    private static let log = LoggerFactory.getLogger("fountain::fmq.queue.CursorCatalog")

    private let store: CursorStore
    private let meta: MetaStore
    private let lock = Mutex()
    private let cache = HashMap<String, LogPosition>()

    protected init(store: CursorStore, meta: MetaStore) {
        this.store = store
        this.meta = meta
    }

    private static func keyOf(topic: String, queueIndex: Int64, group: String): String {
        "${topic}\u{0}${queueIndex}\u{0}${group}"
    }

    /** 读位点：先查缓存，未命中再落一次 IO 并缓存。 */
    protected func positionOf(topic: String, queueIndex: Int64, group: String): ?LogPosition {
        let key = keyOf(topic, queueIndex, group)
        let cached = synchronized(lock) {
            cache.get(key)
        }
        match (cached) {
            case Some(position) => return Some(position)
            case None => ()
        }
        // 磁盘 IO 放在锁外：清理器与消费线程会并发调用
        match (store.load(topic, queueIndex, group)) {
            case Some(loaded) =>
                let chosen = synchronized(lock) {
                    // 并发 save 可能已经写入更新的位点，缓存只能前进
                    var result = loaded
                    match (cache.get(key)) {
                        case Some(existing) =>
                            if (existing.seq > loaded.seq ||
                                (existing.seq == loaded.seq && existing.offset >= loaded.offset)) {
                                result = existing
                            } else {
                                cache.add(key, loaded)
                            }
                        case None => cache.add(key, loaded)
                    }
                    result
                }
                Some(chosen)
            case None => None<LogPosition>
        }
    }

    /** 写位点：先落盘再更新缓存（落盘失败时缓存不前进）。 */
    protected func save(topic: String, queueIndex: Int64, group: String, position: LogPosition): Unit {
        store.save(topic, queueIndex, group, position)
        synchronized(lock) {
            cache.add(keyOf(topic, queueIndex, group), position)
        }
    }

    /**
     * 段保留边界：所有已注册组位点的最小段号。
     *
     * 只有 `segment.index < floor` 的段才「无人需要」，可以按 TTL 删除。
     */
    protected func floorOf(topic: String, queueIndex: Int64): Int64 {
        var floor = Int64.Max
        var seen = false
        for (group in meta.groupsOf(topic)) {
            seen = true
            let position = match (positionOf(topic, queueIndex, group.subscribeGroup)) {
                case Some(p) => p
                case None =>
                    // 组从未消费：位点缺失等同于「从头开始」，把边界钉在最老段。
                    // 文件存在却读不出来是「损坏」，按缺失处理但必须留痕。
                    if (store.hasCursor(topic, queueIndex, group.subscribeGroup)) {
                        log.error("cursor of ${topic}/${queueIndex}/${group.subscribeGroup} is corrupted, treat as missing")
                    }
                    LogPosition(1, 0)
            }
            if (position.seq < floor) {
                floor = position.seq
            }
        }
        if (!seen) {
            return 1
        }
        floor
    }

    /** 删除某订阅组在各队列上的位点，并让缓存失效。 */
    protected func removeGroup(topic: String, group: String): Unit {
        store.removeGroup(topic, group)
        let suffix = "\u{0}${group}"
        invalidateWhere {key => key.startsWith("${topic}\u{0}") && key.endsWith(suffix)}
    }

    /** 删除主题下全部位点，并让缓存失效。 */
    protected func removeAllOf(topic: String): Unit {
        store.removeAllOf(topic)
        invalidateWhere {key => key.startsWith("${topic}\u{0}")}
    }

    private func invalidateWhere(predicate: (String) -> Bool): Unit {
        synchronized(lock) {
            let victims = ArrayList<String>()
            for ((key, _) in cache) {
                if (predicate(key)) {
                    victims.add(key)
                }
            }
            for (key in victims) {
                cache.remove(key)
            }
        }
    }
}
