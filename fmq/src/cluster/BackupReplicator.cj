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
import std.sync.{AtomicBool, Mutex, Timer}
import fountain::f_io.LogPosition
import fountain::f_log.*
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.{MQBackupPayload, MQBackupState}

/** 待备份的一条记录。 */
private class BackupItem {
    let topic: String
    let queueIndex: Int64
    let position: LogPosition
    let record: Array<Byte>

    init(topic: String, queueIndex: Int64, position: LogPosition, record: Array<Byte>) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.position = position
        this.record = record
    }
}

/**
 * 备份副本：把发布成功的记录异步推送给环形后续的 `backup` 个节点。
 *
 * 批量在「累积 64 条」或「距上次 100ms」时触发；队列有界，满则丢弃并 WARN，不阻塞发布。
 */
protected class BackupReplicator {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.BackupReplicator")
    private static let BATCH_SIZE: Int64 = 64
    private static let FLUSH_INTERVAL = Duration.millisecond * 100

    private let transport: MQNodeTransport
    private let backup: Int64
    private let capacity: Int64
    private let lock = Mutex()
    private var pending = ArrayList<BackupItem>()
    private let closed = AtomicBool(false)
    private var timer: ?Timer = None

    protected init(transport: MQNodeTransport, backup: Int64, capacity!: Int64 = 8192) {
        this.transport = transport
        this.backup = backup
        this.capacity = capacity
    }

    /** 发布成功后调用：非阻塞入队。 */
    protected func record(topic: String, queueIndex: Int64, position: LogPosition, record: Array<Byte>): Unit {
        if (backup <= 0 || closed.load()) {
            return
        }
        var shouldFlush = false
        synchronized(lock) {
            if (pending.size >= capacity) {
                log.warn("backup queue is full (${capacity}), drop backup of ${topic}/${queueIndex}@${position.seq}:${position.offset}")
            } else {
                pending.add(BackupItem(topic, queueIndex, position, record))
                shouldFlush = pending.size >= BATCH_SIZE
            }
        }
        if (shouldFlush) {
            flush()
        }
    }

    /** 立即 flush（定时器与测试共用）。 */
    protected func flush(): Unit {
        if (backup <= 0) {
            return
        }
        var batch = ArrayList<BackupItem>()
        synchronized(lock) {
            batch = pending
            pending = ArrayList<BackupItem>()
        }
        if (batch.size == 0) {
            return
        }
        let groups = HashMap<String, ArrayList<BackupItem>>()
        for (item in batch) {
            let key = "${item.topic}\u{0}${item.queueIndex}"
            match (groups.get(key)) {
                case Some(items) => items.add(item)
                case None =>
                    let items = ArrayList<BackupItem>()
                    items.add(item)
                    groups.add(key, items)
            }
        }
        let targets = transport.successors(backup)
        if (targets.size == 0) {
            return
        }
        for ((_, items) in groups) {
            let first = items[0]
            let records = Array<Array<Byte>>(items.size) {i => items[i].record}
            let states = Array<MQBackupState>(items.size) {i =>
                MQBackupState(items[i].position.seq, items[i].position.offset, 0, false)
            }
            let payload = MQBackupPayload(transport.selfIndex, first.topic, first.queueIndex, records, states)
            let message = MQProtocol.publishBackup(payload)
            for (target in targets) {
                if (transport.send(target, message).isNone()) {
                    log.warn("backup to node ${target} failed for ${first.topic}/${first.queueIndex}")
                }
            }
        }
    }

    protected func start(): Unit {
        if (backup <= 0) {
            return
        }
        timer = Some(Timer.repeat(FLUSH_INTERVAL, FLUSH_INTERVAL, {=> flush()}))
    }

    /** 停止定时器并做最后一次 flush。 */
    protected func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        match (timer) {
            case Some(t) =>
                t.cancel()
                timer = None
            case None => ()
        }
        flush()
    }
}
