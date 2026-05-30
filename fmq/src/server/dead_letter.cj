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

import std.collection.HashMap
import std.io.ByteBuffer
import std.sync.{Mutex, AtomicInt64}
import std.time.DateTime
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.{SegmentedLog, LogConfig}

/**
 * 死信队列存储。
 * 写入 SegmentedLog 持久化，内存 HashMap 索引 (messageId → (topic, queueIndex, data))。
 * list/redeliver 通过 HashMap 索引实现，SegmentedLog 用于崩溃恢复（后续阶段重建索引）。
 */
public class DeadLetterStore {
    private let dlqDir: String
    private let dlqLog: SegmentedLog
    private let retentionHours: Int64
    private let syncBatchSize: Int64
    private let log = LoggerFactory.getLogger('fountain::fmq.DeadLetterStore')
    // 内存索引：messageId → (topic, queueIndex, data, insertedAt)
    private let index = HashMap<String, (String, Int64, Array<Byte>, DateTime)>()
    private let mutex = Mutex()
    private let unsyncedCount = AtomicInt64(0)

    public init(queueDir: String, retentionHours!: Int64 = 168, syncBatchSize!: Int64 = 10) {
        this.dlqDir = "${queueDir}/dlq"
        this.retentionHours = retentionHours
        this.syncBatchSize = syncBatchSize
        let config = LogConfig(this.dlqDir, "dlq", 1048576, 100, fileExt: ".dlq")
        this.dlqLog = SegmentedLog(config)
        // 从 SegmentedLog 重建内存索引（崩溃恢复）
        rebuildIndex()
    }

    /**
     * 写入死信消息。
     * 写入 SegmentedLog + 加入内存索引。
     * 日志条目编码：messageId(String) + topic(String) + queueIndex(Int64) + data(Array<Byte>)。
     *
     * 性能：按 syncBatchSize 批量 sync 降低 fsync 频率。close() 时强制最终 sync。
     */
    public func append(data: Array<Byte>, topic: String, queueIndex: Int64, messageId: String): Unit {
        // 编码 metadata + data 到单条 entry
        let entry = encodeDlqEntry(messageId, topic, queueIndex, data)
        dlqLog.append(entry)
        let count = unsyncedCount.fetchAdd(1) + 1
        if (count >= syncBatchSize) {
            dlqLog.sync()
            unsyncedCount.store(0)
        }
        synchronized(mutex) { index[messageId] = (topic, queueIndex, data, DateTime.now()) }
        log.warn{"dead letter: ${messageId}"}
    }

    /**
     * 强制同步。在关闭前调用确保数据落盘。
     */
    public func sync(): Unit {
        if (unsyncedCount.load() > 0) {
            dlqLog.sync()
            unsyncedCount.store(0)
        }
    }

    /**
     * 列出指定 topic + queue 的死信。
     */
    public func list(topic: String, queueIndex: Int64): ArrayList<(String, Array<Byte>)> {
        let result = ArrayList<(String, Array<Byte>)>()
        synchronized(mutex) {
            for ((msgId, (t, qi, data, _)) in index) {
                if (t == topic && qi == queueIndex) {
                    result.add((msgId, data))
                }
            }
        }
        result
    }

    /**
     * 重投单条死信。从索引删除，返回消息体。
     */
    public func redeliver(topic: String, queueIndex: Int64, messageId: String): ?Array<Byte> {
        synchronized(mutex) {
            if (let Some((t, qi, data, _)) <- index.get(messageId)) {
                if (t == topic && qi == queueIndex) {
                    index.remove(messageId)
                    return Some(data)
                }
            }
        }
        None
    }

    /**
     * 重投所有死信。返回所有匹配的消息体。
     */
    public func redeliverAll(topic: String, queueIndex: Int64): ArrayList<Array<Byte>> {
        let result = ArrayList<Array<Byte>>()
        let keys = ArrayList<String>()
        synchronized(mutex) {
            for ((msgId, (t, qi, _, _)) in index) {
                if (t == topic && qi == queueIndex) {
                    keys.add(msgId)
                }
            }
            for (msgId in keys) {
                if (let Some((_, _, data, _)) <- index.get(msgId)) {
                    index.remove(msgId)
                    result.add(data)
                }
            }
        }
        result
    }

    /**
     * 清理过期死信。基于 retentionHours 移除超过保留时间的条目。
     * retentionHours=0 表示无限保留，跳过清理。
     */
    public func cleanup(): Unit {
        if (retentionHours <= 0) { return }
        let cutoff = DateTime.now() - Duration.hour * retentionHours
        var removed: Int64 = 0
        synchronized(mutex) {
            let expired = ArrayList<String>()
            for ((msgId, (_, _, _, at)) in index) {
                if (at < cutoff) {
                    expired.add(msgId)
                }
            }
            for (msgId in expired) {
                index.remove(msgId)
                removed += 1
            }
        }
        let rh = retentionHours  // capture let for log lambda
        if (removed > 0) {
            let rm = removed
            log.info{"cleanup: removed ${rm} expired dead letters (retention=${rh}h)"}
        }
    }

    /**
     * 从 SegmentedLog 重建内存索引。
     * 通过 openEntryStream() 流式读取所有 entry，无需全量加载。
     */
    public func rebuildIndex(): Unit {
        let stream = dlqLog.openEntryStream()
        try {
            let dec = DefaultCodec()
            var count: Int64 = 0
            while (true) {
                if (let Some(msgId) <- dec.decode<String>(stream)
                    && let Some(topic) <- dec.decode<String>(stream)
                    && let Some(qi) <- dec.decode<Int64>(stream)
                    && let Some(data) <- dec.decode<Array<Byte>>(stream)) {
                    synchronized(mutex) {
                        index[msgId] = (topic, qi, data, DateTime.now())
                    }
                    count += 1
                } else {
                    break
                }
            }
            if (count > 0) {
                let restored = count
                log.info{"rebuildIndex: restored ${restored} dead letters"}
            }
        } finally {
            if (let r: Resource <- stream) {
                r.close()
            }
        }
    }

    // ───── 编解码 ─────

    private static func encodeDlqEntry(msgId: String, topic: String, queueIndex: Int64,
                                        data: Array<Byte>): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(msgId).encode(topic).encode(queueIndex).encode(data)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /**
     * 关闭 SegmentedLog，释放文件描述符。
     */
    public func close(): Unit {
        dlqLog.close()
    }
}
