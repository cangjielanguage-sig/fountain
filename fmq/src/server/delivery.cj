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
    var deliverTime: DateTime
    var retryCount: Int64
    var acked: Bool

    public init(messageId: String, consumerId: String, groupId: String,
                deliverTime: DateTime, retryCount!: Int64 = 0, acked!: Bool = false) {
        this.messageId = messageId
        this.consumerId = consumerId
        this.groupId = groupId
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
     * 记录投递。
     */
    public func recordDelivery(messageId: String, consumerId: String, groupId: String): DeliveryRecord {
        let record = DeliveryRecord(messageId, consumerId, groupId, DateTime.now())
        records[messageId] = record
        record
    }

    /**
     * ACK 处理。
     * 按 (topic, queueIndex, groupId) 查找最早未确认的投递记录。
     * 返回 true 表示已确认。
     */
    public func onAck(messageId: String, topic: String, queueIndex: Int64): Bool {
        if (let Some(record) <- records.get(messageId)) {
            if (record.acked) { return false }
            record.acked = true
            records.remove(messageId)
            let offsetKey = offsetKeyFor(topic, queueIndex, serverId, record.groupId)
            let current = offsets.get(offsetKey) ?? 0
            offsets[offsetKey] = current + 1
            persistOffset(offsetKey, current + 1)
            true
        } else {
            false
        }
    }

    /**
     * 超时扫描。
     * 返回所有超时记录（当前时间 - deliverTime > ackTimeoutMs）。
     */
    public func checkTimeout(): ArrayList<DeliveryRecord> {
        let now = DateTime.now()
        let timeoutMs = config.ackTimeoutMs
        let expired = ArrayList<DeliveryRecord>()
        for ((_, record) in records) {
            if (record.acked) { continue }
            let elapsed = DateTime.now() - record.deliverTime
            // Duration 通过对比实现超时检查
            if (elapsed > Duration.millisecond * timeoutMs) {
                expired.add(record)
            }
        }
        expired
    }

    /**
     * 重试投递。
     * 使用 ConsumerMatcher 查找当前在线消费者。
     * 返回 true 表示可重试，false 表示入死信队列。
     */
    public func retry(record: DeliveryRecord, consumerMatcher: ConsumerMatcher): Bool {
        record.retryCount += 1
        if (record.retryCount >= config.maxRetryCount) {
            log.warn{"max retry reached for ${record.messageId}, move to DLQ"}
            return false
        }
        // 查找在线消费者（使用 messageId 作为 topic 占位，实际需从记录中提取）
        let groups = consumerMatcher.matchTopic(record.groupId)
        if (groups.size > 0) {
            log.info{"retry ${record.retryCount}/${config.maxRetryCount} for ${record.messageId}"}
            record.deliverTime = DateTime.now()
            true
        } else {
            log.warn{"no consumer available for ${record.messageId}, move to DLQ"}
            false
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

    private static func tryCreateSyncClient(): ?SyncClient {
        try { SyncClient.getInstance() } catch (_: Exception) { None }
    }

    private static func offsetKeyFor(topic: String, queueIndex: Int64, server: String, groupId: String): String {
        "${topic}:${queueIndex}:${server}:${groupId}"
    }
}
