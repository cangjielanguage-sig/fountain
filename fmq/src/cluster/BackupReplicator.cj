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
package fountain::fmq.cluster

import std.collection.{ArrayList, HashMap}
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import fountain::f_io.LogPosition
import fountain::f_log.*
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.{MQBackupCursor, MQBackupPayload, MQBackupState}

/** 备份状态来源：生产端在 flush 时向它查询真实消费状态与位点。 */
protected interface BackupStateSource {
    func backupStates(topic: String, queueIndex: Int64, positions: Array<LogPosition>): Array<MQBackupState>
    func backupCursors(topic: String, queueIndex: Int64): Array<MQBackupCursor>
}

/** 待备份的一条记录。 */
private class BackupItem {
    let topic: String
    let queueIndex: Int64
    let position: LogPosition
    let record: Array<Byte>
    var attempts: Int64
    /** 上一次发送失败的目标；空表示「该批次的全部目标」（R2-G5）。 */
    var remainingTargets: Array<Int64> = []

    init(topic: String, queueIndex: Int64, position: LogPosition, record: Array<Byte>, attempts!: Int64 = 0) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.position = position
        this.record = record
        this.attempts = attempts
    }
}

/** 同一 `(topic, queue)` 且待发目标相同的一组记录：一次发一条消息给每个目标。 */
private class BackupGroup {
    let topic: String
    let queueIndex: Int64
    let targets: Array<Int64>
    let items = ArrayList<BackupItem>()

    init(topic: String, queueIndex: Int64, targets: Array<Int64>) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.targets = targets
    }
}

/**
 * 备份副本：把发布成功的记录异步推送给环形后续的 `backup` 个节点。
 *
 * 发布线程只负责入队（A27）：发送由独立工作线程在「累积 64 条」或「最早一条已等待 100ms」时触发。
 * 批次发送失败重新入队（最多重试 3 次，A30）；接收端按 `cursors` 落消费位点（A26）。
 */
protected class BackupReplicator {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.BackupReplicator")
    private static let BATCH_SIZE: Int64 = 64
    private static let FLUSH_INTERVAL_MS: Int64 = 100
    private static let POLL_INTERVAL = Duration.millisecond * 10
    private static let MAX_ATTEMPTS: Int64 = 3
    /** 关闭等待上限：必须覆盖一次发送的 transport 超时，否则 close 返回时还有在途请求（R2-G6）。 */
    private static let CLOSE_WAIT_MS: Int64 = 5000

    private let transport: MQNodeTransport
    private let backup: Int64
    private let capacity: Int64
    private let lock = Mutex()
    /** 串行化 flush：工作线程与 close 的 drain 不能同时发同一批（R2-G6）。 */
    private let flushLock = Mutex()
    private var pending = ArrayList<BackupItem>()
    private var oldestEnqueuedMs: Int64 = 0
    private let closed = AtomicBool(false)
    private let workerRunning = AtomicBool(false)
    private var stateSource: ?BackupStateSource = None
    private var lastDropWarnMs: Int64 = 0

    protected init(transport: MQNodeTransport, backup: Int64, capacity!: Int64 = 8192) {
        this.transport = transport
        this.backup = backup
        this.capacity = capacity
    }

    /** 当前待发送条目数（测试与运维观测用）。 */
    public prop pendingCount: Int64 {
        get() {
            synchronized(lock) {
                pending.size
            }
        }
    }

    /** 装配真实消费状态来源（服务端启动时注入）。 */
    protected func setStateSource(source: BackupStateSource): Unit {
        this.stateSource = source
    }

    /** 发布成功后调用：只入队，不发送。 */
    protected func record(topic: String, queueIndex: Int64, position: LogPosition, record: Array<Byte>): Unit {
        if (backup <= 0) {
            // 未开启备份时发布路径仍会调用：丢弃必须留痕（限流，避免每条消息刷屏）
            warnRateLimited("dropped backup of ${topic}/${queueIndex}@${position.seq}:${position.offset}: " +
                "backup replication is disabled (mqServer_backup=${backup})")
            return
        }
        if (closed.load()) {
            warnRateLimited("dropped backup of ${topic}/${queueIndex}@${position.seq}:${position.offset}: replicator is closed")
            return
        }
        synchronized(lock) {
            if (pending.size >= capacity) {
                warnRateLimited("backup queue is full (${capacity}), drop backup of " +
                    "${topic}/${queueIndex}@${position.seq}:${position.offset}")
                return
            }
            if (pending.size == 0) {
                oldestEnqueuedMs = nowMs()
            }
            pending.add(BackupItem(topic, queueIndex, position, record))
        }
    }

    /** 取走当前批次并发送；失败批次重新入队。 */
    protected func flushOnce(): Unit {
        if (backup <= 0) {
            return
        }
        synchronized(flushLock) {
            var batch = ArrayList<BackupItem>()
            synchronized(lock) {
                if (pending.size == 0) {
                    return
                }
                batch = pending
                pending = ArrayList<BackupItem>()
                oldestEnqueuedMs = 0
            }
            let retry = sendBatch(batch)
            if (retry.size > 0) {
                requeue(retry)
            }
        }
    }

    /** 发送一批；返回需要重试的条目（目标全部不可达）。 */
    private func sendBatch(batch: ArrayList<BackupItem>): ArrayList<BackupItem> {
        let retry = ArrayList<BackupItem>()
        let targets = transport.successors(backup)
        if (targets.size == 0) {
            // 单节点：没有副本可发，不算失败（不能凭空丢批次）
            return retry
        }
        // 按「待发目标集合」分组：已成功的目标不会再收到同一条记录（R2-G5）
        let groups = HashMap<String, BackupGroup>()
        for (item in batch) {
            let dest = if (item.remainingTargets.size == 0) {
                targets
            } else {
                item.remainingTargets
            }
            let key = "${item.topic}\u{0}${item.queueIndex}\u{0}${joinNodes(dest)}"
            match (groups.get(key)) {
                case Some(group) => group.items.add(item)
                case None =>
                    let group = BackupGroup(item.topic, item.queueIndex, dest)
                    group.items.add(item)
                    groups.add(key, group)
            }
        }
        for ((_, group) in groups) {
            let items = group.items
            let first = items[0]
            let records = Array<Array<Byte>>(items.size) {i => items[i].record}
            let states = statesOf(first.topic, first.queueIndex, items)
            let cursors = cursorsOf(first.topic, first.queueIndex)
            let payload = MQBackupPayload(transport.selfIndex, first.topic, first.queueIndex, records, states,
                cursors: cursors)
            let message = MQProtocol.publishBackup(payload)
            let failed = ArrayList<Int64>()
            for (target in group.targets) {
                match (transport.send(target, message)) {
                    case Some(_) => ()
                    case None =>
                        log.warn("backup to node ${target} failed for ${first.topic}/${first.queueIndex}")
                        failed.add(target)
                }
            }
            if (failed.size > 0) {
                let dest = failed.toArray()
                for (item in items) {
                    item.remainingTargets = dest
                    retry.add(item)
                }
            }
        }
        return retry
    }

    private func statesOf(topic: String, queueIndex: Int64, items: ArrayList<BackupItem>): Array<MQBackupState> {
        let positions = Array<LogPosition>(items.size) {i => items[i].position}
        match (stateSource) {
            case Some(source) =>
                let states = source.backupStates(topic, queueIndex, positions)
                if (states.size == positions.size) {
                    return states
                }
                log.warn("backup state source returned ${states.size} states for ${positions.size} records")
            case None => ()
        }
        // 没有状态来源（单节点 / 测试）：不伪造已确认，明确标成未确认
        Array<MQBackupState>(items.size) {i =>
            MQBackupState(items[i].position.seq, items[i].position.offset, 0, false)
        }
    }

    private func cursorsOf(topic: String, queueIndex: Int64): Array<MQBackupCursor> {
        match (stateSource) {
            case Some(source) => source.backupCursors(topic, queueIndex)
            case None => Array<MQBackupCursor>()
        }
    }

    private func requeue(items: ArrayList<BackupItem>): Unit {
        synchronized(lock) {
            // 放回队首，保持同队列顺序
            let survivors = ArrayList<BackupItem>()
            for (item in items) {
                item.attempts++
                if (item.attempts > MAX_ATTEMPTS) {
                    log.error("drop backup batch for ${item.topic}/${item.queueIndex} after ${item.attempts} attempts")
                    continue
                }
                survivors.add(item)
            }
            if (survivors.size == 0) {
                return
            }
            let merged = ArrayList<BackupItem>()
            for (item in survivors) {
                merged.add(item)
            }
            for (item in pending) {
                merged.add(item)
            }
            pending = merged
            if (oldestEnqueuedMs == 0) {
                oldestEnqueuedMs = nowMs()
            }
        }
    }

    protected func start(): Unit {
        if (backup <= 0) {
            return
        }
        workerRunning.store(true)
        spawn {
            while (!closed.load()) {
                sleep(POLL_INTERVAL)
                if (shouldFlush()) {
                    try {
                        flushOnce()
                    } catch (e: Exception) {
                        log.error("backup flush failed: ${e.message}")
                    }
                }
            }
            workerRunning.store(false)
        }
    }

    private func shouldFlush(): Bool {
        synchronized(lock) {
            if (pending.size == 0) {
                return false
            }
            pending.size >= BATCH_SIZE || nowMs() - oldestEnqueuedMs >= FLUSH_INTERVAL_MS
        }
    }

    /** 停止工作线程并 drain 剩余批次；等待上限覆盖一次发送的超时（R2-G6）。 */
    protected func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        var waited = 0i64
        while (workerRunning.load() && waited < CLOSE_WAIT_MS) {
            sleep(POLL_INTERVAL)
            waited += 10
        }
        flushOnce()
        let left = pendingCount
        if (left > 0) {
            log.error("backup replicator closed with ${left} unsent item(s)")
        }
    }

    private func warnRateLimited(message: String): Unit {
        let now = nowMs()
        synchronized(lock) {
            if (now - lastDropWarnMs < 1000) {
                return
            }
            lastDropWarnMs = now
        }
        log.warn(message)
    }

    private static func joinNodes(nodes: Array<Int64>): String {
        let buf = StringBuilder()
        for (i in 0..nodes.size) {
            if (i > 0) {
                buf.append(",")
            }
            buf.append(nodes[i].toString())
        }
        buf.toString()
    }

    private static func nowMs(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }
}
