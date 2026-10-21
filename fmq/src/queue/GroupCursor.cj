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
import std.sync.Mutex
import std.time.DateTime
import fountain::f_io.LogPosition
import fountain::f_log.*
import fountain::f_mq.base.{MQMessageRecord}
import fountain::f_mq.base.payload.MQDeadLetterMessage
import fountain::fmq.metrics.MQMetrics

/**
 * `(topic, queueIndex, group)` 的消费游标。
 *
 * 算法（规格 §6.5）：
 * 1. 先看未决集合，按位置顺序重投超期/已分配未取走的记录；
 * 2. 再从 `scanPosition` 顺序扫描新记录：匹配本订阅 → 立即投递；匹配同组其它订阅 →
 *    分配给它（`delivered = false`）；无人匹配 → 记为不适用（可越过）；
 * 3. 从 `committed` 起吞并连续的「已决」位置，每前进一步落盘。
 *
 * `committed` 保存的是「最后一条已决记录之后的位置」，重启不会重读已确认记录。
 * 乱序确认只留洞，不按最大位置推进。
 */
protected class GroupCursor {
    private static let logger = LoggerFactory.getLogger("fountain::fmq.queue.GroupCursor")

    private let topic: String
    private let queueIndex: Int64
    private let group: String
    private let log: QueueLog
    private let catalog: CursorCatalog
    private let ackTimeout: Duration
    private let deadMsgThreshold: Int64
    private let deadLetter: DeadLetterQueue
    private let delaying: Duration
    private let metrics: ?MQMetrics
    private let now: () -> DateTime
    private let lock = Mutex()

    private var committed_: LogPosition
    private var scanPosition: LogPosition
    private let entries = ArrayList<DeliveryRecord>()
    private var reader: ?QueueRecordReader = None
    /** 本轮扫描遇到的「BODY 不可评估」位置，由调用方取走并转成协议错误（A46）。 */
    private var unsupportedAt: ?LogPosition = None
    /** 不可读记录计数（段被清理/记录被截断），用于观测「静默已决」（A48）。 */
    private var skippedUnreadable_: Int64 = 0
    /** 组内无人匹配而越过的记录计数（规格要求可观测）。 */
    private var noMatchSkipped_: Int64 = 0
    /** BODY 不可评估而越过的位置计数（A46，与 `unreadableSkipped`/`noMatchSkipped` 并列观测）。 */
    private var unsupportedSkipped_: Int64 = 0
    private var closed = false

    protected init(topic: String, queueIndex: Int64, group: String, log: QueueLog, catalog: CursorCatalog,
        ackTimeout: Duration, deadMsgThreshold: Int64, deadLetter: DeadLetterQueue,
        delaying!: Duration = Duration.Zero, metrics!: ?MQMetrics = None,
        now!: () -> DateTime = {=> DateTime.now()}) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.group = group
        this.log = log
        this.catalog = catalog
        this.ackTimeout = ackTimeout
        this.deadMsgThreshold = deadMsgThreshold
        this.deadLetter = deadLetter
        this.delaying = delaying
        this.metrics = metrics
        this.now = now
        let loaded = match (catalog.positionOf(topic, queueIndex, group)) {
            case Some(position) => position
            case None => LogPosition(1, 0)
        }
        this.committed_ = loaded
        this.scanPosition = loaded
    }

    protected prop committed: LogPosition {
        get() {
            committed_
        }
    }

    protected prop pendingCount: Int64 {
        get() {
            synchronized(lock) {
                var count = 0i64
                for (entry in entries) {
                    if (!entry.decided) {
                        count++
                    }
                }
                count
            }
        }
    }

    /**
     * 取一条给该订阅的消息；无消息返回 `None`。
     *
     * `groupMembers` 是组内当前活跃订阅（至少包含本订阅）；为空表示组内无人在线，
     * 此时不扫描、不推进（消息保留）。
     */
    protected func next(subscription: MQSubscriptionView, groupMembers: Array<MQSubscriptionView>,
        matcher: MQMatcher): ?(Array<Byte>, LogPosition) {
        synchronized(lock) {
            if (closed || groupMembers.size == 0) {
                return None<(Array<Byte>, LogPosition)>
            }
            // 1. 重投 / 取走已分配给本订阅的记录
            let current = now()
            var redelivered: ?(Array<Byte>, LogPosition) = None
            for (entry in entries) {
                if (entry.decided) {
                    continue
                }
                let mine = match (entry.owner) {
                    case None => true
                    case Some(id) => id == subscription.subscribedId
                }
                if (!mine) {
                    continue
                }
                let ready = !entry.delivered || current - entry.lastDeliverTime >= ackTimeout
                if (!ready) {
                    continue
                }
                let record = try {
                    log.readAt(entry.position)
                } catch (e: Exception) {
                    // 段被 TTL 清理：跳到现存后继段后重试（本轮直接返回，下次从新位置开始）
                    match (recoverIfSegmentGone(entry.position.seq)) {
                        case StillPresent => throw e
                        case Moved => return None<(Array<Byte>, LogPosition)>
                        case NoFuture => return None<(Array<Byte>, LogPosition)>
                    }
                }
                let bytes = match (record) {
                    case Record(data) => data
                    case Corrupt =>
                        // 段还在但记录坏了：不标记已决、不推进，交给运维修段后重试（R3-M2）
                        logger.error("corrupted record at ${topic}/${queueIndex}@" +
                            "${entry.position.seq}:${entry.position.offset} for group '${group}', " +
                            "cursor is not advanced")
                        return None<(Array<Byte>, LogPosition)>
                    case SegmentGone =>
                        // 段被清理、记录已不可读：标记已决，但必须留痕（A48）
                        entry.decided = true
                        skippedUnreadable_ = skippedUnreadable_ + 1
                        if (let Some(m) <- metrics) {
                            m.incSkippedUnreadable(topic, group)
                        }
                        logger.warn("record at ${topic}/${queueIndex}@${entry.position.seq}:" +
                            "${entry.position.offset} is gone for group '${group}', marked decided")
                        continue
                }
                // 已分配但尚未取走：延迟未到期时停在队首（已投递过的重投不受延迟约束）
                if (!entry.delivered && !isDue(bytes, current)) {
                    return None<(Array<Byte>, LogPosition)>
                }
                // 已分配给本订阅但尚未取走时，匹配在分配时已判定；退回组内的记录必须重新匹配
                let needMatch = entry.delivered || entry.owner.isNone()
                if (needMatch) {
                    match (MQMatcher.matches(subscription, bytes)) {
                        case Match => ()
                        case _ => continue
                    }
                }
                entry.deliverCount++
                entry.lastDeliverTime = current
                entry.owner = Some(subscription.subscribedId)
                entry.delivered = true
                if (entry.deliverCount > deadMsgThreshold) {
                    writeDeadLetter(entry, bytes, current)
                    entry.decided = true
                    continue
                }
                redelivered = Some((bytes, entry.position))
                if (let Some(m) <- metrics) {
                    m.incDelivered(topic, group)
                    if (entry.deliverCount > 1) {
                        m.incRedelivered(topic, group)
                    }
                }
                if (subscription.autoAck) {
                    // autoAck 也是「已确认」，必须计入 acked（A61）
                    entry.decided = true
                    if (let Some(m) <- metrics) {
                        m.incAcked(topic, group)
                    }
                }
                break
            }
            advance()
            if (redelivered.isSome()) {
                return redelivered
            }

            // 2. 扫描新记录
            while (true) {
                if (reader.isNone()) {
                    try {
                        reader = Some(openReaderAt(scanPosition))
                    } catch (e: Exception) {
                        // 起始段已被清理：跳到后继段继续；没有任何段则视为空
                        match (recoverIfSegmentGone(scanPosition.seq)) {
                            case StillPresent => throw e
                            case Moved => continue
                            case NoFuture => return None<(Array<Byte>, LogPosition)>
                        }
                    }
                }
                let item = try {
                    reader.getOrThrow().next()
                } catch (e: Exception) {
                    // 读取中途段失效：与开流路径同样恢复；记录损坏（段仍在）则保持原样抛出
                    match (recoverIfSegmentGone(scanPosition.seq)) {
                        case StillPresent => throw e
                        case Moved => continue
                        case NoFuture => return None<(Array<Byte>, LogPosition)>
                    }
                }
                if (item.isNone()) {
                    let corrupted = reader.getOrThrow().isCorrupted()
                    reader.getOrThrow().close()
                    reader = None
                    if (corrupted) {
                        // 记录损坏：不推进、不崩溃，留给上层转成错误/告警（A45/A48）
                        logger.error("queue ${topic}/${queueIndex} is corrupted at ${scanPosition.seq}:${scanPosition.offset}, group '${group}'")
                        return None<(Array<Byte>, LogPosition)>
                    }
                    advance()
                    return None<(Array<Byte>, LogPosition)>
                }
                let record = item.getOrThrow()[0]
                let position = item.getOrThrow()[1]
                let after = reader.getOrThrow().position()
                scanPosition = after

                let ownResult = MQMatcher.matches(subscription, record)
                match (ownResult) {
                    case Match =>
                        if (!isDue(record, current)) {
                            // 未到期：停在队首，不建未决项、不推进 committed
                            scanPosition = position
                            reader.getOrThrow().close()
                            reader = None
                            return None<(Array<Byte>, LogPosition)>
                        }
                        let entry = DeliveryRecord(position, after, Some(subscription.subscribedId), 1, now(), true)
                        entries.add(entry)
                        if (let Some(m) <- metrics) {
                            m.incDelivered(topic, group)
                        }
                        if (subscription.autoAck) {
                            entry.decided = true
                            if (let Some(m) <- metrics) {
                                m.incAcked(topic, group)
                            }
                            advance()
                        }
                        return Some((record, position))
                    case _ => ()
                }
                // 是否属于组内其它订阅；任一活跃订阅「无法判定」时整组暂停，不得越过该位置
                var assignedTo: ?String = None
                var unsupported = match (ownResult) {
                    case Unsupported => true
                    case _ => false
                }
                if (!unsupported) {
                    for (member in groupMembers) {
                        if (member.subscribedId == subscription.subscribedId) {
                            continue
                        }
                        match (MQMatcher.matches(member, record)) {
                            case Match =>
                                assignedTo = Some(member.subscribedId)
                                break
                            case Unsupported =>
                                unsupported = true
                                break
                            case NoMatch => ()
                        }
                    }
                }
                if (let Some(other) <- assignedTo) {
                    if (!isDue(record, current)) {
                        scanPosition = position
                        reader.getOrThrow().close()
                        reader = None
                        return None<(Array<Byte>, LogPosition)>
                    }
                    entries.add(DeliveryRecord(position, after, Some(other), 0, now(), false))
                } else if (unsupported) {
                    // BODY 无法评估：跳过该位置并留痕，不让整组永久停摆（A46）。
                    // 该位置只报一次；其它组独立游标，不受影响。
                    entries.add(DeliveryRecord(position, after, None<String>, 0, current, false, decided: true))
                    unsupportedSkipped_ = unsupportedSkipped_ + 1
                    if (let Some(m) <- metrics) {
                        m.incSkippedUnsupported(topic, group)
                    }
                    scanPosition = after
                    reader.getOrThrow().close()
                    reader = None
                    unsupportedAt = Some(position)
                    logger.warn("body of ${topic}/${queueIndex}@${position.seq}:${position.offset} cannot be evaluated " +
                        "for group '${group}', skipped")
                    advance()
                    return None<(Array<Byte>, LogPosition)>
                } else {
                    // 组内无人匹配：不适用，允许越过（记 DEBUG + 计数，便于排查「消息被越过」）
                    entries.add(DeliveryRecord(position, after, None<String>, 0, now(), false, decided: true))
                    noMatchSkipped_ = noMatchSkipped_ + 1
                    if (let Some(m) <- metrics) {
                        m.incSkippedNoMatch(topic, group)
                    }
                    logger.debug("record at ${topic}/${queueIndex}@${position.seq}:${position.offset} " +
                        "matches no active subscriber of group '${group}', skipped")
                }
                advance()
            }
            None<(Array<Byte>, LogPosition)>
        }
    }

    /** 因不可读而被跳过的记录数（观测用）。 */
    protected prop unreadableSkipped: Int64 {
        get() {
            synchronized(lock) {
                skippedUnreadable_
            }
        }
    }

    /** 因组内无人匹配而被越过（标为不适用）的记录数（观测用）。 */
    protected prop noMatchSkipped: Int64 {
        get() {
            synchronized(lock) {
                noMatchSkipped_
            }
        }
    }

    /** 因 BODY 不可评估而被越过的位置数（观测用）。 */
    protected prop unsupportedSkipped: Int64 {
        get() {
            synchronized(lock) {
                unsupportedSkipped_
            }
        }
    }

    /** 取走「不可评估」位置（每处只报一次）。 */
    protected func takeUnsupported(): ?LogPosition {
        synchronized(lock) {
            let value = unsupportedAt
            unsupportedAt = None<LogPosition>
            value
        }
    }

    /** 该位置的已投递次数；不在未决集合时返回 0（备份诊断用）。 */
    protected func deliverCountAt(position: LogPosition): Int64 {
        synchronized(lock) {
            for (entry in entries) {
                if (entry.position.seq == position.seq && entry.position.offset == position.offset) {
                    return entry.deliverCount
                }
            }
            0
        }
    }

    /**
     * 确认位置。位置不在未决集合、或已分配给其它订阅时返回 `false`。
     */
    protected func ack(subscriptionId: String, position: LogPosition): Bool {
        synchronized(lock) {
            for (entry in entries) {
                if (entry.decided || entry.position.seq != position.seq || entry.position.offset != position.offset) {
                    continue
                }
                if (let Some(owner) <- entry.owner) {
                    if (owner != subscriptionId) {
                        return false
                    }
                }
                // 只接受了「已分配的归属」还不够：必须真的投递过（A50）
                if (!entry.delivered) {
                    return false
                }
                entry.decided = true
                advance()
                if (let Some(m) <- metrics) {
                    m.incAcked(topic, group)
                }
                return true
            }
            false
        }
    }

    /** 订阅取消：把它名下的未确认记录退回组内。 */
    protected func release(subscriptionId: String): Unit {
        synchronized(lock) {
            for (entry in entries) {
                if (entry.decided) {
                    continue
                }
                if (let Some(owner) <- entry.owner) {
                    if (owner == subscriptionId) {
                        entry.owner = None
                        entry.delivered = false
                    }
                }
            }
            advance()
        }
    }

    /**
     * 定时兜底：owner 已不在活跃集合的记录退回组内（连接断开 / 订阅注销）。
     */
    protected func sweep(activeSubscriptions: Array<String>): Unit {
        synchronized(lock) {
            for (entry in entries) {
                if (entry.decided) {
                    continue
                }
                if (let Some(owner) <- entry.owner) {
                    if (!activeSubscriptions.contains(owner)) {
                        entry.owner = None
                        entry.delivered = false
                    }
                }
            }
            advance()
        }
    }

    protected func close(): Unit {
        synchronized(lock) {
            if (closed) {
                return
            }
            closed = true
            match (reader) {
                case Some(r) => r.close()
                case None => ()
            }
            reader = None
            catalog.save(topic, queueIndex, group, committed_)
        }
    }

    // ===== 内部 =====

    /** 吞并连续的已决位置并落盘。 */
    private func advance(): Unit {
        var moved = false
        while (entries.size > 0 && entries[0].decided) {
            committed_ = entries[0].next
            entries.remove(at: 0)
            moved = true
        }
        if (moved) {
            catalog.save(topic, queueIndex, group, committed_)
        }
    }

    /**
     * 在指定位置开读流，并把「起点段已被清理」的跳转同步到游标。
     *
     * `QueueLog.openRecordsFrom` 已经会跳到后继段（A47），但游标位点也必须跟着前移：
     * 否则 `committed` 会停在已不存在的段上，`advance()` 永远等不到可吞并的已决项。
     * 调用方必须已持有 `lock`。
     */
    private func openReaderAt(position: LogPosition): QueueRecordReader {
        let opened = log.openRecordsFrom(position)
        let actual = opened.position()
        if (actual.seq != position.seq || actual.offset != position.offset) {
            entries.clear()
            let movedForward = actual.seq > committed_.seq ||
                (actual.seq == committed_.seq && actual.offset > committed_.offset)
            if (movedForward) {
                committed_ = actual
                catalog.save(topic, queueIndex, group, committed_)
                logger.warn("cursor of ${topic}/${queueIndex}/${group} moved from " +
                    "${position.seq}:${position.offset} to ${actual.seq}:${actual.offset} " +
                    "because its segment was removed")
            }
            scanPosition = actual
        }
        opened
    }

    /**
     * 位置所在段已不存在时恢复游标：关闭读流、丢弃未决项、跳到「最接近的更大段」起点并落盘。
     *
     * 规格要求起点段被删时从后继段继续，不能退回更老的段（否则已确认区间被重投）；
     * 没有任何后继段时按空队列处理（`NoFuture`），不得把空队列变成异常。
     * `StillPresent` 表示目标段仍在（异常另有原因，调用方应继续抛出）。
     * 调用方必须已持有 `lock`。
     */
    private func recoverIfSegmentGone(segmentIndex: Int64): SegmentRecovery {
        let segments = log.segmentsOrEmpty()
        let next = QueueLog.startSegmentAtOrAfter(segments, segmentIndex)
        match (next) {
            case Some(index) =>
                if (index == segmentIndex) {
                    return StillPresent
                }
            case None => ()
        }
        match (reader) {
            case Some(r) => r.close()
            case None => ()
        }
        reader = None
        entries.clear()
        match (next) {
            case Some(index) =>
                let previous = committed_
                committed_ = LogPosition(index, 0)
                scanPosition = committed_
                catalog.save(topic, queueIndex, group, committed_)
                logger.warn("cursor of ${topic}/${queueIndex}/${group} moved from ${previous.seq}:${previous.offset} to " +
                    "${index}:0 because its segment was removed")
                Moved
            case None =>
                logger.warn("no segment at or after ${segmentIndex} on queue ${topic}/${queueIndex} for group " +
                    "'${group}', treated as empty")
                NoFuture
        }
    }

    /**
     * 延迟到期判定：未配置延迟恒为真；无发布时间时按已到期并告警。
     *
     * 发布时间比当前时刻还晚 5 分钟以上，说明 id 由旧版本按本地时区写入（按 UTC 解释会整体后移
     * 一个时区偏移）。这类记录按「已到期」处理，避免延迟组被未来时间卡住（A02）。
     */
    private func isDue(record: Array<Byte>, current: DateTime): Bool {
        if (delaying <= Duration.Zero) {
            return true
        }
        match (MQMessageRecord.publishTime(record)) {
            case Some(published) =>
                if (published > current + Duration.minute * 5) {
                    logger.warn("publish time of record on ${topic}/${queueIndex} is in the future by more than 5m, " +
                        "deliver immediately")
                    return true
                }
                current - published >= delaying
            case None =>
                logger.warn("no publish time in messageId on delayed topic ${topic}, deliver immediately")
                true
        }
    }

    private func writeDeadLetter(entry: DeliveryRecord, record: Array<Byte>, now: DateTime): Unit {
        deadLetter.append(MQDeadLetterMessage(topic, queueIndex, group, entry.position.seq, entry.position.offset,
            entry.deliverCount, now, record))
        if (let Some(m) <- metrics) {
            m.incDeadLettered(topic, group)
        }
    }
}
