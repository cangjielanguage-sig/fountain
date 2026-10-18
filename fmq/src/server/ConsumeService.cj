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
package fountain::fmq.server

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import std.time.DateTime
import fountain::f_io.LogPosition
import fountain::f_mq.base.MQErrorCode
import fountain::f_mq.base.payload.{MQAckPayload, MQConsumeResult, MQResult}
import fountain::f_time.*
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.queue.*

/**
 * 取消息 / 确认 / 订阅注销的服务端实现。
 *
 * 每个 `(topic, queueIndex, group)` 一个 `GroupCursor`，懒建并缓存；不同组之间互不阻塞。
 */
protected class ConsumeService {
    private let queues: QueueManager
    private let store: CursorStore
    private let subscribers: SubscriberRegistry
    private let matcher: MQMatcher
    private let deadLetter: DeadLetterQueue
    private let ackTimeout: Duration
    private let deadMsgThreshold: Int64
    private let metrics: ?MQMetrics
    private let now: () -> DateTime
    private let lock = Mutex()
    private let cursors = HashMap<String, GroupCursor>()

    init(queues: QueueManager, store: CursorStore, subscribers: SubscriberRegistry, matcher: MQMatcher,
        deadLetter: DeadLetterQueue, ackTimeout: Duration, deadMsgThreshold: Int64,
        metrics!: ?MQMetrics = None, now!: () -> DateTime = {=> DateTime.now()}) {
        this.queues = queues
        this.store = store
        this.subscribers = subscribers
        this.matcher = matcher
        this.deadLetter = deadLetter
        this.ackTimeout = ackTimeout
        this.deadMsgThreshold = deadMsgThreshold
        this.metrics = metrics
        this.now = now
    }

    /** 为某订阅取一条消息；无消息（或本机没有该主题队列）返回 `None`。 */
    func consume(info: MQSubscriptionInfo): ?MQConsumeResult {
        let locals = queues.localQueues(info.topic)
        if (locals.size == 0) {
            return None<MQConsumeResult>
        }
        let members = subscribers.byGroupOf(info.topic, info.subscribeGroup)
        if (members.size == 0) {
            return None<MQConsumeResult>
        }
        let views = Array<MQSubscriptionView>(members.size) {i => members[i].view()}
        let active = subscribers.activeIds(info.topic, info.subscribeGroup)
        for ((queueIndex, _) in locals) {
            let cursor = cursorOf(info.topic, queueIndex, info.subscribeGroup)
            // 先把已断开的订阅名下的分配退回组内
            cursor.sweep(active)
            match (cursor.next(info.view(), views, matcher)) {
                case Some(item) =>
                    return Some(MQConsumeResult(queueIndex, item[1].seq, item[1].offset, item[0]))
                case None => ()
            }
        }
        None<MQConsumeResult>
    }

    /**
     * 确认位置；不属于该订阅或位置已越过时返回 `ACK_UNKNOWN`。
     *
     * 按载荷里的 `queueIndex` 精确定位游标：每个队列的段日志位置都会从 `1:0` 重复，
     * 不能遍历本机队列「命中第一个即返回」。
     */
    func ack(info: MQSubscriptionInfo, payload: MQAckPayload): MQResult {
        if (queues.queueOf(info.topic, payload.queueIndex).isNone()) {
            return MQResult(MQErrorCode.ACK_UNKNOWN, MQErrorCode.messageOf(MQErrorCode.ACK_UNKNOWN))
        }
        let cursor = cursorOf(info.topic, payload.queueIndex, info.subscribeGroup)
        if (cursor.ack(payload.subscribedId, LogPosition(payload.segmentedIndex, payload.segmentedOffset))) {
            return MQResult(0, "ok")
        }
        MQResult(MQErrorCode.ACK_UNKNOWN, MQErrorCode.messageOf(MQErrorCode.ACK_UNKNOWN))
    }

    /** 订阅注销 / 连接断开：把名下未确认记录退回组内。 */
    func releaseSubscription(info: MQSubscriptionInfo): Unit {
        for ((queueIndex, _) in queues.localQueues(info.topic)) {
            cursorOf(info.topic, queueIndex, info.subscribeGroup).release(info.subscribedId)
        }
    }

    /** 懒建并缓存组游标。 */
    func cursorOf(topic: String, queueIndex: Int64, group: String): GroupCursor {
        let key = "${topic}\u{0}${queueIndex}\u{0}${group}"
        synchronized(lock) {
            match (cursors.get(key)) {
                case Some(cursor) => cursor
                case None =>
                    let log = match (queues.queueOf(topic, queueIndex)) {
                        case Some(queue) => queue
                        case None => throw IllegalArgumentException(
                            "queue ${queueIndex} of topic '${topic}' is not local")
                    }
                    let cursor = GroupCursor(topic, queueIndex, group, log, store, ackTimeout, deadMsgThreshold,
                        deadLetter, delaying: Duration.millisecond * queues.delayingOf(topic), metrics: metrics,
                        now: now)
                    cursors.add(key, cursor)
                    cursor
            }
        }
    }

    /**
     * 组装节点级统计文本（TSV）。
     *
     * 第一行 `#\t节点\t生成时间`；其后每个 `(topic, group)` 一行 `R` 记录。
     * 无订阅组的主题输出一行 group 为空的记录。`groupsOf(topic)` 由调用方提供。
     */
    func stats(topic: String, nodeIndex: Int64, groupsOf: (String) -> Array<String>): String {
        let topics = ArrayList<String>()
        if (topic.isEmpty()) {
            for (name in queues.localTopics()) {
                topics.add(name)
            }
        } else if (queues.localQueues(topic).size > 0) {
            topics.add(topic)
        }

        let out = StringBuilder()
        out.append("#\t${nodeIndex}\t${now().toUnixTimeStamp().toMilliseconds()}\n")
        for (name in topics) {
            let locals = queues.localQueues(name)
            var messages = 0i64
            var bytes = 0i64
            for ((_, log) in locals) {
                messages += log.countAll()
                bytes += log.size
            }
            let queueNum = queues.queueNumOf(name)
            let delayingMs = queues.delayingOf(name)
            let groups = groupsOf(name)
            if (groups.size == 0) {
                out.append("R\t${name}\t\t${queueNum}\t${delayingMs}\t${messages}\t0\t0\t0\t0\t0\t0\n")
                continue
            }
            for (group in groups) {
                var backlog = 0i64
                var oldest: ?DateTime = None
                for ((queueIndex, log) in locals) {
                    let cursor = cursorOf(name, queueIndex, group)
                    let scanned = log.scanAfter(cursor.committed)
                    backlog += scanned[0]
                    match (scanned[1]) {
                        case Some(published) =>
                            let earlier = match (oldest) {
                                case None => true
                                case Some(current) =>
                                    published.toUnixTimeStamp() < current.toUnixTimeStamp()
                            }
                            if (earlier) {
                                oldest = Some(published)
                            }
                        case None => ()
                    }
                }
                let lagMs = match (oldest) {
                    case Some(published) => (now() - published).toMilliseconds()
                    case None => 0
                }
                var delivered = 0i64
                var acked = 0i64
                var redelivered = 0i64
                var deadLettered = 0i64
                if (let Some(m) <- metrics) {
                    delivered = m.deliveredOf(name, group)
                    acked = m.ackedOf(name, group)
                    redelivered = m.redeliveredOf(name, group)
                    deadLettered = m.deadLetteredOf(name, group)
                }
                out.append("R\t${name}\t${group}\t${queueNum}\t${delayingMs}\t${messages}\t${backlog}\t" +
                    "${lagMs}\t${delivered}\t${acked}\t${redelivered}\t${deadLettered}\n")
            }
        }
        out.toString()
    }

    /** 段是否仍被某游标引用（不存在游标视为未引用）。 */
    protected func references(topic: String, queueIndex: Int64, segmentIndex: Int64): Bool {
        let key = "${topic}\u{0}${queueIndex}\u{0}"
        synchronized(lock) {
            for ((cursorKey, cursor) in cursors) {
                if (cursorKey.startsWith(key)) {
                    if (cursor.references(segmentIndex)) {
                        return true
                    }
                }
            }
            false
        }
    }

    /** 主题删除：关闭并移除其全部游标。 */
    func removeTopic(topic: String): Unit {
        let prefix = "${topic}\u{0}"
        let victims = ArrayList<String>()
        synchronized(lock) {
            for ((key, _) in cursors) {
                if (key.startsWith(prefix)) {
                    victims.add(key)
                }
            }
            for (key in victims) {
                match (cursors.remove(key)) {
                    case Some(cursor) => cursor.close()
                    case None => ()
                }
            }
        }
    }

    /** 订阅组删除：关闭并移除该组游标。 */
    func removeGroup(topic: String, group: String): Unit {
        let suffix = "\u{0}${group}"
        let victims = ArrayList<String>()
        synchronized(lock) {
            for ((key, _) in cursors) {
                if (key.startsWith("${topic}\u{0}") && key.endsWith(suffix)) {
                    victims.add(key)
                }
            }
            for (key in victims) {
                match (cursors.remove(key)) {
                    case Some(cursor) => cursor.close()
                    case None => ()
                }
            }
        }
    }

    func close(): Unit {
        let victims = ArrayList<String>()
        synchronized(lock) {
            for ((key, _) in cursors) {
                victims.add(key)
            }
            for (key in victims) {
                match (cursors.remove(key)) {
                    case Some(cursor) => cursor.close()
                    case None => ()
                }
            }
        }
    }
}
