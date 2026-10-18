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
import fountain::f_mq.base.payload.MQDeadLetterMessage

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
    private let topic: String
    private let queueIndex: Int64
    private let group: String
    private let log: QueueLog
    private let store: CursorStore
    private let ackTimeout: Duration
    private let deadMsgThreshold: Int64
    private let deadLetter: DeadLetterQueue
    private let now: () -> DateTime
    private let lock = Mutex()

    private var committed_: LogPosition
    private var scanPosition: LogPosition
    private let entries = ArrayList<DeliveryRecord>()
    private var reader: ?QueueRecordReader = None
    private var closed = false

    protected init(topic: String, queueIndex: Int64, group: String, log: QueueLog, store: CursorStore,
        ackTimeout: Duration, deadMsgThreshold: Int64, deadLetter: DeadLetterQueue,
        now!: () -> DateTime = {=> DateTime.now()}) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.group = group
        this.log = log
        this.store = store
        this.ackTimeout = ackTimeout
        this.deadMsgThreshold = deadMsgThreshold
        this.deadLetter = deadLetter
        this.now = now
        let loaded = match (store.load(topic, queueIndex, group)) {
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
                let record = log.readAt(entry.position)
                if (record.isNone()) {
                    // 记录已不可读（段被清理）：标记已决，避免阻塞
                    entry.decided = true
                    continue
                }
                // 已分配给本订阅但尚未取走时，匹配在分配时已判定；退回组内的记录必须重新匹配
                let needMatch = entry.delivered || entry.owner.isNone()
                if (needMatch && !MQMatcher.matches(subscription, record.getOrThrow())) {
                    continue
                }
                entry.deliverCount++
                entry.lastDeliverTime = current
                entry.owner = Some(subscription.subscribedId)
                entry.delivered = true
                if (entry.deliverCount > deadMsgThreshold) {
                    writeDeadLetter(entry, record.getOrThrow(), current)
                    entry.decided = true
                    continue
                }
                redelivered = Some((record.getOrThrow(), entry.position))
                if (subscription.autoAck) {
                    entry.decided = true
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
                    reader = Some(log.openRecordsFrom(scanPosition))
                }
                let item = reader.getOrThrow().next()
                if (item.isNone()) {
                    reader.getOrThrow().close()
                    reader = None
                    advance()
                    return None<(Array<Byte>, LogPosition)>
                }
                let record = item.getOrThrow()[0]
                let position = item.getOrThrow()[1]
                let after = reader.getOrThrow().position()
                scanPosition = after

                if (MQMatcher.matches(subscription, record)) {
                    let entry = DeliveryRecord(position, after, Some(subscription.subscribedId), 1, now(), true)
                    entries.add(entry)
                    if (subscription.autoAck) {
                        entry.decided = true
                        advance()
                    }
                    return Some((record, position))
                }
                // 是否属于组内其它订阅
                var assignedTo: ?String = None
                for (member in groupMembers) {
                    if (member.subscribedId == subscription.subscribedId) {
                        continue
                    }
                    if (MQMatcher.matches(member, record)) {
                        assignedTo = Some(member.subscribedId)
                        break
                    }
                }
                if (let Some(other) <- assignedTo) {
                    entries.add(DeliveryRecord(position, after, Some(other), 0, now(), false))
                } else {
                    // 组内无人匹配：不适用，允许越过
                    entries.add(DeliveryRecord(position, after, None<String>, 0, now(), false, decided: true))
                }
                advance()
            }
            None<(Array<Byte>, LogPosition)>
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
                entry.decided = true
                advance()
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

    /** 本游标是否仍然引用该段（清理器据此保留段）。 */
    protected func references(segmentIndex: Int64): Bool {
        synchronized(lock) {
            segmentIndex >= committed_.seq
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
            store.save(topic, queueIndex, group, committed_)
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
            store.save(topic, queueIndex, group, committed_)
        }
    }

    private func writeDeadLetter(entry: DeliveryRecord, record: Array<Byte>, now: DateTime): Unit {
        deadLetter.append(MQDeadLetterMessage(topic, queueIndex, group, entry.position.seq, entry.position.offset,
            entry.deliverCount, now, record))
    }
}
