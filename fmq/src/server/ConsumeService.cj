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
import fountain::f_mq.base.{MQErrorCode, MQMessageRecord}
import fountain::f_mq.exception.MQServiceException
import fountain::f_mq.base.payload.{MQAckPayload, MQBackupCursor, MQBackupState, MQConsumeResult, MQResult}
import fountain::f_time.*
import fountain::fmq.cluster.BackupStateSource
import fountain::fmq.metrics.MQMetrics
import fountain::fmq.queue.*

/**
 * 取消息 / 确认 / 订阅注销的服务端实现。
 *
 * 每个 `(topic, queueIndex, group)` 一个 `GroupCursor`，懒建并缓存；不同组之间互不阻塞。
 */
protected class ConsumeService <: BackupStateSource {
    private let queues: QueueManager
    private let catalog: CursorCatalog
    private let subscribers: SubscriberRegistry
    private let matcher: MQMatcher
    private let deadLetter: DeadLetterQueue
    private let ackTimeout: Duration
    private let deadMsgThreshold: Int64
    private let metrics: ?MQMetrics
    private let now: () -> DateTime
    private let lock = Mutex()
    private let cursors = HashMap<String, GroupCursor>()

    init(queues: QueueManager, catalog: CursorCatalog, subscribers: SubscriberRegistry, matcher: MQMatcher,
        deadLetter: DeadLetterQueue, ackTimeout: Duration, deadMsgThreshold: Int64,
        metrics!: ?MQMetrics = None, now!: () -> DateTime = {=> DateTime.now()}) {
        this.queues = queues
        this.catalog = catalog
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
                case None =>
                    // 本轮跳过了不可评估 BODY：把位置报给调用方，客户端据此看到错误（A46）
                    match (cursor.takeUnsupported()) {
                        case Some(position) =>
                            throw MQServiceException(MQErrorCode.FILTER_UNSUPPORTED_BODY,
                                "filter cannot be evaluated at ${queueIndex}:${position.seq}:${position.offset}")
                        case None => ()
                    }
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
                    let cursor = GroupCursor(topic, queueIndex, group, log, catalog, ackTimeout, deadMsgThreshold,
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
            let queueNum = queues.queueNumOf(name)
            let delayingMs = queues.delayingOf(name)
            let groups = groupsOf(name)
            if (groups.size == 0) {
                out.append("R\t${name}\t\t${queueNum}\t${delayingMs}\t0\t0\t0\t0\t0\t0\n")
                continue
            }
            // 单趟扫描：每个队列只顺序读一遍，按各组位点分桶计数（A62）
            let backlog = HashMap<String, Int64>()
            let oldest = HashMap<String, DateTime>()
            for (group in groups) {
                backlog.add(group, 0)
            }
            for ((queueIndex, log) in locals) {
                if (log.segmentsOrEmpty().size == 0) {
                    continue
                }
                let starts = HashMap<String, LogPosition>()
                var minStart = LogPosition(Int64.Max, 0)
                for (group in groups) {
                    let committed = match (catalog.positionOf(name, queueIndex, group)) {
                        case Some(position) => position
                        case None => LogPosition(1, 0)
                    }
                    starts.add(group, committed)
                    if (before(committed, minStart)) {
                        minStart = committed
                    }
                }
                let reader = try {
                    log.openRecordsFrom(minStart)
                } catch (e: QueueCorruptionException) {
                    throw MQServiceException(MQErrorCode.INTERNAL, "stats scan failed on ${name}/${queueIndex}: ${e.message}")
                }
                try {
                    while (true) {
                        let current = reader.position()
                        match (reader.next()) {
                            case None => break
                            case Some(item) =>
                                for (group in groups) {
                                    let start = starts.get(group).getOrThrow()
                                    if (before(current, start)) {
                                        continue
                                    }
                                    backlog.add(group, backlog.get(group).getOrThrow() + 1)
                                    if (oldest.get(group).isNone()) {
                                        match (MQMessageRecord.publishTime(item[0])) {
                                            case Some(published) => oldest.add(group, published)
                                            case None => ()
                                        }
                                    }
                                }
                        }
                    }
                    if (reader.isCorrupted()) {
                        throw MQServiceException(MQErrorCode.INTERNAL,
                            "stats scan failed on ${name}/${queueIndex}: queue is corrupted")
                    }
                } finally {
                    reader.close()
                }
            }
            for (group in groups) {
                let lagMs = match (oldest.get(group)) {
                    // 旧版本按本地时区写入的 id 会被解释成未来时刻，负滞后没有意义，钳到 0（A02）
                    case Some(published) =>
                        let lag = (now() - published).toMilliseconds()
                        if (lag < 0) {0} else {lag}
                    case None => 0
                }
                let groupBacklog = backlog.get(group).getOrThrow()
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
                out.append("R\t${name}\t${group}\t${queueNum}\t${delayingMs}\t${groupBacklog}\t${lagMs}\t" +
                    "${delivered}\t${acked}\t${redelivered}\t${deadLettered}\n")
            }
        }
        out.toString()
    }

    /** `left` 是否在 `right` 之前（段号优先，段内偏移其次）。 */
    private static func before(left: LogPosition, right: LogPosition): Bool {
        left.seq < right.seq || (left.seq == right.seq && left.offset < right.offset)
    }

    /** 备份状态：逐条计算「是否已被所有组确认」与投递次数（A26）。 */
    public func backupStates(topic: String, queueIndex: Int64,
        positions: Array<LogPosition>): Array<MQBackupState> {
        let groups = catalog.groupNames(topic)
        let committed = Array<LogPosition>(groups.size) {i =>
            match (catalog.positionOf(topic, queueIndex, groups[i])) {
                case Some(position) => position
                case None => LogPosition(1, 0)
            }
        }
        Array<MQBackupState>(positions.size) {i =>
            MQBackupState(positions[i].seq, positions[i].offset, deliverCountOf(topic, queueIndex, positions[i]),
                ackedByAll(committed, positions[i]))
        }
    }

    /** 备份附带位点：每个已注册组当前 committed。 */
    public func backupCursors(topic: String, queueIndex: Int64): Array<MQBackupCursor> {
        let groups = catalog.groupNames(topic)
        Array<MQBackupCursor>(groups.size) {i =>
            let position = match (catalog.positionOf(topic, queueIndex, groups[i])) {
                case Some(value) => value
                case None => LogPosition(1, 0)
            }
            MQBackupCursor(groups[i], position.seq, position.offset)
        }
    }

    /** 位置是否已被全部组越过；没有组时视为未确认（不伪造已确认）。 */
    private static func ackedByAll(committed: Array<LogPosition>, position: LogPosition): Bool {
        if (committed.size == 0) {
            return false
        }
        for (current in committed) {
            if (current.seq < position.seq ||
                (current.seq == position.seq && current.offset <= position.offset)) {
                return false
            }
        }
        true
    }

    /** 已投递次数：只查已存在的游标，不为备份创建新游标。 */
    private func deliverCountOf(topic: String, queueIndex: Int64, position: LogPosition): Int64 {
        let key = "${topic}\u{0}${queueIndex}\u{0}"
        synchronized(lock) {
            for ((cursorKey, cursor) in cursors) {
                if (cursorKey.startsWith(key)) {
                    let count = cursor.deliverCountAt(position)
                    if (count > 0) {
                        return count
                    }
                }
            }
            0
        }
    }

    /**
     * 段保留边界：该队列全部**已注册组**位点的最小段号。
     *
     * 走 `CursorCatalog` 而不是内存游标：离线组只有磁盘位点，按内存游标删段会删掉慢组积压。
     */
    protected func floorOf(topic: String, queueIndex: Int64): Int64 {
        catalog.floorOf(topic, queueIndex)
    }

    /** 主题删除：关闭并移除其全部游标。 */
    func removeTopic(topic: String): Unit {
        match (metrics) {
            case Some(m) => m.removeTopic(topic)
            case None => ()
        }
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
        match (metrics) {
            case Some(m) => m.removeGroup(topic, group)
            case None => ()
        }
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
