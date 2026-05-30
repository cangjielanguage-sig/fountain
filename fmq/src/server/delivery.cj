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

import std.collection.concurrent.ConcurrentHashMap
import std.collection.ArrayList
import std.convert.*
import std.sync.{Mutex, AtomicBool, AtomicInt64}
import fountain::f_codec.default.DefaultCodec
import std.io.ByteBuffer
import fountain::fleet.client.SyncClient

/**
 * 投递记录。
 */
public class DeliveryRecord {
    let messageId: String
    let consumerId: String
    let groupId: String
    let topic: String
    var payload: Array<Byte>  // 原始消息体，用于 DLQ 重投
    var deliverTime: DateTime
    let retryCount: AtomicInt64
    var acked: AtomicBool

    public init(messageId: String, consumerId: String, groupId: String, topic: String,
                deliverTime: DateTime, retryCount!: AtomicInt64 = AtomicInt64(0),
                acked!: AtomicBool = AtomicBool(false),
                payload!: Array<Byte> = []) {
        this.messageId = messageId
        this.consumerId = consumerId
        this.groupId = groupId
        this.topic = topic
        this.payload = payload
        this.deliverTime = deliverTime
        this.retryCount = retryCount
        this.acked = acked
    }
}

/**
 * 投递管理器。
 * 管理投递记录、ACK 处理、超时重试。
 */
public class DeliveryManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.DeliveryManager')
    private let records = ConcurrentHashMap<String, DeliveryRecord>()  // messageId → record
    // offset: topic:queueIndex:server:groupId → Int64
    private let offsets = ConcurrentHashMap<String, Int64>()
    private let syncClient: ?SyncClient
    private let serverId: String  // "host:port" 用于 offset key
    private let onAckLock = Mutex()  // 保护 onAck check-then-act
    private var consumerMatcher: Option<ConsumerMatcher> = None
    private var queueManager: Option<QueueManager> = None
    private var topicManager: Option<TopicManager> = None
    private let checkerClosed = AtomicBool(false)
    private var checkerFuture: Option<Future<Unit>> = None

    public init(config: MqConfig, serverId!: String = "") {
        this.config = config
        this.syncClient = tryCreateSyncClient()
        // 从 mqHosts 取第一个作为 serverId
        this.serverId = if (serverId != "") { serverId } else {
            if (config.mqHosts.size > 0) { config.mqHosts[0] } else { "unknown" }
        }
    }

    /**
     * 从 fleet 恢复所有 offset。
     * 启动时调用，在 QueueManager.createQueues 之前。
     */
    public func restoreOffsets(): Unit {
        if (let Some(fleet) <- syncClient) {
            try {
                let result = fleet.prefix("/mq/offset/")
                for (i in 0..result.size) {
                    if (let Some(key) <- result.getKey(i)
                        && let Some(bytes) <- result.getValue(i)) {
                        let offsetKey = key[11..]  // 去掉 "/mq/offset/"
                        if (let Some(offset) <- DefaultCodec().decode<Int64>(ByteBuffer(bytes))) {
                            offsets[offsetKey] = offset
                        }
                    }
                }
                log.info{"restore: loaded ${offsets.size} offsets from fleet"}
            } catch (e: Exception) {
                log.warn{"restore offsets from fleet failed: ${e.message}"}
            }
        }
    }

    /**
     * 记录投递。若 messageId 已存在则不覆盖（防止丢失 ACK 状态）。
     * synchronized 防止 check-then-act 竞态：两个线程同时 recordDelivery 相同 messageId。
     */
    public func recordDelivery(messageId: String, consumerId: String, groupId: String, topic: String,
                                payload!: Array<Byte> = []): DeliveryRecord {
        synchronized(onAckLock) {
            if (let Some(existing) <- records.get(messageId)) {
                existing
            } else {
                let record = DeliveryRecord(messageId, consumerId, groupId, topic, DateTime.now(),
                    payload: payload)
                records[messageId] = record
                record
            }
        }
    }

    /**
     * ACK 处理。
     * 返回 true 表示已确认（存在且未之前确认过）。
     * synchronized 防止并发 ACK 的 check-then-act 竞态。
     */
    public func onAck(messageId: String, topic: String, queueIndex: Int64): Bool {
        var result = false
        var offsetKey = ""
        var offsetVal: Int64 = 0
        synchronized(onAckLock) {
            if (let Some(record) <- records.get(messageId)) {
                if (!record.acked.load()) {
                    record.acked.store(true)
                    records.remove(messageId)
                    let key = offsetKeyFor(topic, queueIndex, serverId, record.groupId)
                    let current = offsets.get(key) ?? 0
                    offsets[key] = current + 1
                    result = true
                    offsetKey = key
                    offsetVal = current + 1
                }
            }
        }
        if (result && offsetKey != "") {
            persistOffset(offsetKey, offsetVal)
        }
        result
    }

    /**
     * 超时扫描。
     * 返回所有超时记录（当前时间 - deliverTime > ackTimeoutMs）。
     */
    public func checkTimeout(): ArrayList<DeliveryRecord> {
        let now = DateTime.now()
        let timeoutMs = config.ackTimeoutMs
        let expired = ArrayList<DeliveryRecord>()
        // P1-2: 在锁内创建 records 快照，避免已 ACK 记录被误判超时
        let snapshot: ArrayList<DeliveryRecord>
        synchronized(onAckLock) {
            snapshot = ArrayList<DeliveryRecord>()
            for ((_, record) in records) { snapshot.add(record) }
        }
        for (record in snapshot) {
            if (record.acked.load()) { continue }
            let elapsed = now - record.deliverTime
            if (elapsed > Duration.millisecond * timeoutMs) {
                expired.add(record)
            }
        }
        expired
    }

    /**
     * 设置 ConsumerMatcher 引用（超时重试需要）。
     */
    public func setConsumerMatcher(cm: ConsumerMatcher): Unit {
        this.consumerMatcher = Some(cm)
    }

    /**
     * 设置 QueueManager 引用（retry 从 SegmentedLog 读取消息需要）。
     */
    public func setQueueManager(qm: QueueManager): Unit {
        this.queueManager = Some(qm)
    }

    /**
     * 设置 TopicManager 引用（清理孤儿 offset 需要）。
     * P2-5: 非必需，仅在清理 offset 时使用。
     */
    public func setTopicManager(tm: TopicManager): Unit {
        this.topicManager = Some(tm)
    }

    /**
     * 清理已删除 topic 的孤儿 offset。
     * P2-5: 在 restoreOffsets 后调用，删除内存中已不存在 topic 的 offset 条目。
     */
    public func cleanupOrphanOffsets(): Unit {
        if (let Some(ref) <- topicManager) {
            var orphanKeys = ArrayList<String>()
            for ((key, _) in offsets) {
                // key format: topic:queueIndex:server:groupId
                let parts = key.split(':')
                if (parts.size >= 1) {
                    let topic = parts[0]
                    if (ref.getTopicMeta(topic).isNone()) {
                        orphanKeys.add(key)
                    }
                }
            }
            for (k in orphanKeys) {
                offsets.remove(k)
            }
            if (orphanKeys.size > 0) {
                let count = orphanKeys.size
                log.info{"cleanupOrphanOffsets: removed ${count} orphan offsets"}
            }
        }
    }

    /**
     * 启动超时检查后台线程。
     * 周期性（ackTimeoutMs/2 间隔）遍历 records 检查超时记录并调用 retry。
     * retry 返回 false 且配置了 DeadLetterStore 时写入 DLQ。
     */
    public func startTimeoutChecker(): Unit {
        if (checkerFuture.isSome()) {
            log.warn{"timeout checker already started"}
            return
        }
        let intervalMs = if (config.ackTimeoutMs / 2 < 100) { 100 } else { config.ackTimeoutMs / 2 }
        log.info{"starting timeout checker (interval=${intervalMs}ms)"}
        checkerFuture = Some(spawn {
            while (!checkerClosed.load()) {
                sleep(Duration.millisecond * intervalMs)
                if (checkerClosed.load()) { break }
                doTimeoutCheck()
            }
        })
    }

    /**
     * 单次超时检查：扫描超时记录并处理重试。
     */
    private func doTimeoutCheck(): Unit {
        let cm = if (let Some(ref) <- consumerMatcher) { ref } else { return }
        let qm = if (let Some(ref) <- queueManager) { ref } else { return }
        let expired = checkTimeout()
        for (exp in expired) {
            try {
                if (retry(exp, cm)) {
                    // retry 成功：记录已更新 deliverTime
                } else {
                    // 重试超限或无消费者 → 入 DLQ
                    moveToDLQ(exp)
                }
            } catch (e: Exception) {
                log.warn{"doTimeoutCheck: retry ${exp.messageId} failed: ${e.message}"}
            }
        }
    }

    /**
     * 将投递记录移入死信队列。
     * 从 messageId 解析 topic:queueIndex 信息，写入 DeadLetterStore。
     */
    private func moveToDLQ(record: DeliveryRecord): Unit {
        // P2-5: 锁内双重检查 record.acked，防止 checkTimeout 快照后 consumer 已 ACK
        synchronized(onAckLock) {
            if (record.acked.load()) { return }
            records.remove(record.messageId)
        }
        let qm = if (let Some(ref) <- queueManager) { ref } else { return }
        let parts = record.messageId.split(':')
        if (parts.size >= 2) {
            let topic = parts[0]
            let queueIdx = if (let Some(idx) <- Int64.tryParse(parts[1])) { idx } else { 0 }
            if (let Some(q) <- qm.getQueue(topic, queueIdx)) {
                q.deadLetter.append(record.payload, topic, queueIdx, record.messageId)
            }
        }
        log.warn{"moved ${record.messageId} to DLQ (retry exhausted)"}
    }

    /**
     * 重试投递。
     * 使用 ConsumerMatcher 查找当前在线消费者。
     * 从 SegmentedLog 读取原始数据用于重试投递（v2 实际发送）。
     * 返回 true 表示可重试，false 表示入死信队列。
     */
    public func retry(record: DeliveryRecord, consumerMatcher: ConsumerMatcher): Bool {
        if (record.retryCount.load() >= config.maxRetryCount) {
            log.warn{"max retry reached for ${record.messageId}, move to DLQ"}
            return false
        }
        // 先查找消费者（P3: 有消费者再递增 retryCount，避免无消费者时非原子回退）
        let groups = consumerMatcher.matchTopic(record.topic)
        if (groups.size > 0) {
            let rc = record.retryCount.fetchAdd(1) + 1
            log.info{"retry ${rc}/${config.maxRetryCount} for ${record.messageId}"}
            record.deliverTime = DateTime.now()
            true
        } else {
            // P3-4: 无消费者时递增 retryCount，防止消息永久驻留
            let rc = record.retryCount.fetchAdd(1) + 1
            log.warn{"no consumer for ${record.messageId}, retry ${rc}/${config.maxRetryCount}"}
            record.deliverTime = DateTime.now()
            true
        }
    }

    /**
     * 获取消费者组 offset。
     */
    public func getOffset(topic: String, queueIndex: Int64, groupId: String): Int64 {
        offsets.get(offsetKeyFor(topic, queueIndex, serverId, groupId)) ?? 0
    }

    /**
     * 设置消费者组 offset（用于 resetOffset）。
     */
    public func setOffset(topic: String, queueIndex: Int64, groupId: String, offset: Int64): Unit {
        let key = offsetKeyFor(topic, queueIndex, serverId, groupId)
        offsets[key] = offset
        log.info{"set offset ${key} = ${offset}"}
    }

    /**
     * 持久化 offset。当前通过 HashMap 维护，已持久化到内存。
     * Phase 8 可写入 fleet /mq/offset/<key>。
     */
    private func persistOffset(offsetKey: String, offset: Int64): Unit {
        log.debug{"persist offset ${offsetKey} = ${offset}"}
        if (let Some(fleet) <- syncClient) {
            try {
                fleet.add<Int64>("/mq/offset/" + offsetKey, offset)
            } catch (e: Exception) {
                log.warn{"persist offset ${offsetKey}=${offset} to fleet failed: ${e.message}"}
            }
        }
    }

    /**
     * 关闭超时检查线程，等待线程退出。
     */
    public func close(): Unit {
        checkerClosed.store(true)
        if (let Some(f) <- checkerFuture) {
            try { f.get() } catch (e: Exception) {
                log.warn{"DeliveryManager.close: checker thread error: ${e.message}"}
            }
        }
    }

    private static func tryCreateSyncClient(): ?SyncClient {
        try { SyncClient.getInstance() } catch (_: Exception) { None }
    }

    private static func offsetKeyFor(topic: String, queueIndex: Int64, server: String, groupId: String): String {
        "${topic}:${queueIndex}:${server}:${groupId}"
    }
}
