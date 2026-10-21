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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.fs.*
import std.sync.{AtomicBool, AtomicInt64, Mutex}
import fountain::fmq.meta.MQFileNames
import fountain::f_mq.base.payload.MQTopicAssignment

/** 一个主题在本机的队列集合与发布轮转游标。 */
private class TopicQueueSet {
    let items: Array<(Int64, QueueLog)>
    let queueNum: Int64
    let delayingMs: Int64
    private let cursor = AtomicInt64(0)

    init(items: Array<(Int64, QueueLog)>, queueNum: Int64, delayingMs: Int64) {
        this.items = items
        this.queueNum = queueNum
        this.delayingMs = delayingMs
    }

    func pick(): ?(Int64, QueueLog) {
        if (items.size == 0) {
            None<(Int64, QueueLog)>
        } else {
            Some(items[cursor.fetchAdd(1) % items.size])
        }
    }
}
/**
 * 主题 / 队列生命周期：只为本机持有的队列打开 `QueueLog`。
 *
 * 目录布局：`<logRoot>/<topicEsc>/<queueIndex>/log_<seq>.log`（只有 f_io 的段文件）。
 */
protected class QueueManager <: Resource {
    private let logRoot: String
    private let maxFileSize: Int64
    private let syncInterval: Int64
    private let topics = ConcurrentHashMap<String, TopicQueueSet>()
    /** 每个主题一把打开锁：建 `QueueLog` 是慢操作，不能持有全局锁（A52）。 */
    private let openLocks = ConcurrentHashMap<String, Mutex>()
    private let closed = AtomicBool(false)

    protected init(logRoot: String, maxFileSize: Int64, syncInterval: Int64) {
        this.logRoot = logRoot
        this.maxFileSize = maxFileSize
        this.syncInterval = syncInterval
    }

    /**
     * 按分配结果建/维护本地队列；重复调用同一主题为空操作。
     *
     * 每个主题一把锁、`putIfAbsent` 判归属：并发打开同一主题只会创建一组 `QueueLog`；
     * 中途失败时关闭已建的日志并删除本次新建的（空）目录，不留半成品（A52）。
     */
    protected func openTopic(assignment: MQTopicAssignment, selfIndex: Int64): Unit {
        if (topics.contains(assignment.topic)) {
            return
        }
        let topicLock = match (openLocks.addIfAbsent(assignment.topic, Mutex())) {
            case Some(existing) => existing
            case None => openLocks.get(assignment.topic).getOrThrow()
        }
        synchronized(topicLock) {
            if (topics.contains(assignment.topic)) {
                return
            }
            let local = ArrayList<(Int64, QueueLog)>()
            let createdDirs = ArrayList<String>()
            try {
                for (i in 0..assignment.owners.size) {
                    if (assignment.owners[i] == selfIndex) {
                        let dir = MQFileNames.queueDir(logRoot, assignment.topic, i)
                        let existed = exists(dir)
                        local.add((i, QueueLog(dir, maxFileSize, syncInterval)))
                        if (!existed) {
                            createdDirs.add(dir)
                        }
                    }
                }
                if (topics.addIfAbsent(assignment.topic,
                    TopicQueueSet(local.toArray(), assignment.queueNum, assignment.delayingMs)).isSome()) {
                    // 其它线程抢先一步：本次创建的句柄作废
                    throw IllegalStateException("topic '${assignment.topic}' was opened concurrently")
                }
            } catch (e: Exception) {
                for ((_, log) in local) {
                    try {
                        log.close()
                    } catch (_: Exception) {}
                }
                for (dir in createdDirs) {
                    try {
                        if (exists(dir)) {
                            remove(dir, recursive: true)
                        }
                    } catch (_: Exception) {}
                }
                throw e
            }
        }
    }

    /**
     * 关闭主题。
     *
     * `deleteFiles = true` 用于 deleteTopic：先关日志再删本机队列目录。
     */
    protected func closeTopic(topic: String, deleteFiles!: Bool): Unit {
        match (topics.remove(topic)) {
            case Some(set) =>
                for ((_, log) in set.items) {
                    log.close()
                }
            case None => ()
        }
        if (deleteFiles) {
            let dir = "${logRoot}/${MQFileNames.escape(topic)}"
            if (exists(dir)) {
                remove(dir, recursive: true)
            }
        }
    }

    protected func queueOf(topic: String, queueIndex: Int64): ?QueueLog {
        match (topics.get(topic)) {
            case None => None<QueueLog>
            case Some(set) =>
                for ((index, log) in set.items) {
                    if (index == queueIndex) {
                        return Some(log)
                    }
                }
                None<QueueLog>
        }
    }

    protected func localQueues(topic: String): Array<(Int64, QueueLog)> {
        match (topics.get(topic)) {
            case Some(set) => set.items
            case None => Array<(Int64, QueueLog)>()
        }
    }

    /** 本节点已打开的主题名（升序由调用方决定）。 */
    protected func localTopics(): Array<String> {
        let names = ArrayList<String>()
        for ((topic, set) in topics) {
            // 只列出本节点真正持有队列的主题，避免 stats 全量/按主题口径不一致
            if (set.items.size > 0) {
                names.add(topic)
            }
        }
        names.toArray()
    }

    /** 主题的延迟投递时长（毫秒）；未知主题返回 0。 */
    protected func delayingOf(topic: String): Int64 {
        match (topics.get(topic)) {
            case Some(set) => set.delayingMs
            case None => 0
        }
    }

    /** 主题的队列总数；未知主题返回 0。 */
    protected func queueNumOf(topic: String): Int64 {
        match (topics.get(topic)) {
            case Some(set) => set.queueNum
            case None => 0
        }
    }

    /** 发布选队列：本机持有的队列里轮转。 */
    protected func pickQueue(topic: String): ?(Int64, QueueLog) {
        match (topics.get(topic)) {
            case Some(set) => set.pick()
            case None => None<(Int64, QueueLog)>
        }
    }

    /** 全部本地队列（清理器 / 巡检遍历）。 */
    protected func allLogs(): Array<(String, Int64, QueueLog)> {
        let result = ArrayList<(String, Int64, QueueLog)>()
        for ((topic, set) in topics) {
            for ((index, log) in set.items) {
                result.add((topic, index, log))
            }
        }
        result.toArray()
    }

    protected prop hasLocalQueues: Bool {
        get() {
            for ((_, set) in topics) {
                if (set.items.size > 0) {
                    return true
                }
            }
            false
        }
    }

    protected func sync(): Unit {
        for ((_, _, log) in allLogs()) {
            log.sync()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        let names = ArrayList<String>()
        for ((topic, set) in topics) {
            // 只列出本节点真正持有队列的主题，避免 stats 全量/按主题口径不一致
            if (set.items.size > 0) {
                names.add(topic)
            }
        }
        for (topic in names) {
            match (topics.remove(topic)) {
                case Some(set) =>
                    for ((_, log) in set.items) {
                        log.close()
                    }
                case None => ()
            }
        }
    }
}
