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
    // offset: topic:queue:groupId → Int64
    private let offsets = ConcurrentHashMap<String, Int64>()

    public init(config: MqConfig) {
        this.config = config
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
     * 返回 true 表示已确认（存在且未之前确认过）。
     */
    public func onAck(messageId: String, topic: String, queueIndex: Int64): Bool {
        if (let Some(record) <- records.get(messageId)) {
            if (record.acked) { return false }
            record.acked = true
            records.remove(messageId)
            // 推进 offset
            let offsetKey = offsetKeyFor(topic, queueIndex, record.groupId)
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
     * 重试投递（Phase 4 占位）。
     * 返回 true 表示已重试，false 表示入死信队列。
     */
    public func retry(record: DeliveryRecord, consumerMatcher: ConsumerMatcher): Bool {
        record.retryCount += 1
        if (record.retryCount >= config.maxRetryCount) {
            log.warn("max retry reached for ${record.messageId}, move to DLQ")
            false
        } else {
            log.info("retry ${record.retryCount}/${config.maxRetryCount} for ${record.messageId}")
            // Phase 4: 重新投递逻辑（查找在线消费者，重新发送）
            record.deliverTime = DateTime.now()  // 重置计时
            true
        }
    }

    /**
     * 获取消费者组 offset。
     */
    public func getOffset(topic: String, queueIndex: Int64, groupId: String): Int64 {
        offsets.get(offsetKeyFor(topic, queueIndex, groupId)) ?? 0
    }

    /**
     * 持久化 offset 到 fsync（Phase 4 占位）。
     */
    private func persistOffset(offsetKey: String, offset: Int64): Unit {
        // Phase 4: 写入 fsync /mq/offset/<key>
        log.debug("persist offset ${offsetKey} = ${offset} (placeholder)")
    }

    private static func offsetKeyFor(topic: String, queueIndex: Int64, groupId: String): String {
        "${topic}:${queueIndex}:${groupId}"
    }
}
