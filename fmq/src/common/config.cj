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
package fountain::fmq.common

import std.env

let log = LoggerFactory.getLogger<MqConfig>()

/**
 * MQ 配置，所有字段从环境变量加载。
 */
public class MqConfig {
    public let mqHosts: ArrayList<String>
    public let syncHosts: ArrayList<String>
    public let heartbeatIntervalSec: Int64
    public let healthcheckMaxRetry: Int64
    public let idleTimeoutMinutes: Int64
    public let ackTimeoutMs: Int64
    public let dataDir: String
    public let segmentMaxSize: Int64
    public let retentionHours: Int64
    public let maxRetryCount: Int64
    public let retryIntervalMs: Int64
    public let dlqRetentionHours: Int64
    public let maxMessageSize: Int64
    public let maxLabelsPerMessage: Int64
    public let syncQuorum: Int64
    public let cleanupBatchSize: Int64

    public init(mqHosts!: ArrayList<String>, syncHosts!: ArrayList<String> = ArrayList<String>(),
                dataDir!: String = "/var/fmq/data/", segmentMaxSize!: Int64 = 512 * 1024 * 1024,
                heartbeatIntervalSec!: Int64 = 5, healthcheckMaxRetry!: Int64 = 3,
                idleTimeoutMinutes!: Int64 = 30, ackTimeoutMs!: Int64 = 30000,
                maxRetryCount!: Int64 = 3, retryIntervalMs!: Int64 = 1000,
                dlqRetentionHours!: Int64 = 168, maxMessageSize!: Int64 = 4 * 1024 * 1024,
                maxLabelsPerMessage!: Int64 = 64, retentionHours!: Int64 = 72,
                syncQuorum!: Int64 = 1, cleanupBatchSize!: Int64 = 10) {
        this.mqHosts = mqHosts
        this.syncHosts = syncHosts
        this.dataDir = dataDir
        this.segmentMaxSize = segmentMaxSize
        this.heartbeatIntervalSec = heartbeatIntervalSec
        this.healthcheckMaxRetry = healthcheckMaxRetry
        this.idleTimeoutMinutes = idleTimeoutMinutes
        this.ackTimeoutMs = ackTimeoutMs
        this.maxRetryCount = maxRetryCount
        this.retryIntervalMs = retryIntervalMs
        this.dlqRetentionHours = dlqRetentionHours
        this.maxMessageSize = maxMessageSize
        this.maxLabelsPerMessage = maxLabelsPerMessage
        this.retentionHours = retentionHours
        this.syncQuorum = syncQuorum
        this.cleanupBatchSize = cleanupBatchSize
    }

    /**
     * 测试用工厂方法。仅设置测试必需字段，其余使用 MqConfig 默认值。
     * COM-5: 不再硬编码所有字段，默认值集中到 init 参数。
     */
    public static func forTest(dataDir!: String = "/tmp/fmq_test",
                               mqHosts!: ArrayList<String> = ArrayList<String>(),
                               segmentMaxSize!: Int64 = 1024 * 1024): MqConfig {
        MqConfig(mqHosts: mqHosts, dataDir: dataDir, segmentMaxSize: segmentMaxSize)
    }
}

/**
 * 从环境变量加载 MQ 配置。
 */
public func loadConfig(): MqConfig {
    MqConfig(
        mqHosts: readEnvList("mq_hosts"),
        syncHosts: readEnvList("sync_hosts"),
        dataDir: readEnv("mq_data_dir") ?? "/var/fmq/data/",
        segmentMaxSize: clampPositive(readEnvInt("mq_segment_max_size"), 512 * 1024 * 1024, "segmentMaxSize"),
        heartbeatIntervalSec: clampPositive(readEnvInt("mq_heartbeat_interval_sec"), 5, "heartbeatIntervalSec"),
        healthcheckMaxRetry: clampPositive(readEnvInt("mq_healthcheck_max_retry"), 3, "healthcheckMaxRetry"),
        idleTimeoutMinutes: clampPositive(readEnvInt("mq_idle_timeout_minutes"), 30, "idleTimeoutMinutes"),
        ackTimeoutMs: clampPositive(readEnvInt("mq_ack_timeout_ms"), 30000, "ackTimeoutMs"),
        maxRetryCount: clampPositive(readEnvInt("mq_max_retry_count"), 3, "maxRetryCount"),
        retryIntervalMs: clampPositive(readEnvInt("mq_retry_interval_ms"), 1000, "retryIntervalMs"),
        dlqRetentionHours: clampPositive(readEnvInt("mq_dlq_retention_hours"), 168, "dlqRetentionHours"),
        maxMessageSize: clampPositive(readEnvInt("mq_max_message_size"), 4 * 1024 * 1024, "maxMessageSize"),
        maxLabelsPerMessage: clampPositive(readEnvInt("mq_max_labels_per_message"), 64, "maxLabelsPerMessage"),
        retentionHours: clampPositive(readEnvInt("mq_retention_hours"), 72, "retentionHours"),
        syncQuorum: clampPositive(readEnvInt("mq_sync_quorum"), 1, "syncQuorum"),
        cleanupBatchSize: clampPositive(readEnvInt("mq_cleanup_batch_size"), 10, "cleanupBatchSize")
    )
}

/**
 * 读取环境变量，返回 ?String。
 */
public func readEnv(key: String): ?String {
    try {
        let v = env.getVariable(key)
        if (let Some(s) <- v) {
            if (s.isEmpty()) { None } else { Some(s) }
        } else {
            None
        }
    } catch (e: Exception) {
        log.warn{"readEnv(${key}) unexpected error: ${e.message}"}
        None
    }
}

/**
 * 按英文逗号分割字符串，trim 空项过滤。COM-6: 提取为 public 以支持单元测试。
 */
public func parseEnvList(raw: String): ArrayList<String> {
    let parts = raw.split(',')
    let result = ArrayList<String>()
    for (p in parts) {
        let trimmed = p.trimAscii()
        if (!trimmed.isEmpty()) {
            result.add(trimmed)
        }
    }
    result
}

/**
 * 读取环境变量，按英文逗号分割为 ArrayList<String>。
 * 空变量返回空列表。
 */
public func readEnvList(key: String): ArrayList<String> {
    let raw = readEnv(key)
    if (let Some(v) <- raw) {
        parseEnvList(v)
    } else {
        ArrayList()
    }
}

/**
 * 范围校验辅助函数，确保整型配置值为正数。
 */
internal func clampPositive(raw: ?Int64, defaultVal: Int64, paramName: String): Int64 {
    let v = raw ?? defaultVal
    if (v <= 0) {
        log.warn{"${paramName} must be positive, got ${v}, using default ${defaultVal}"}
        defaultVal
    } else { v }
}

/**
 * 读取环境变量，解析为 Int64。
 */
public func readEnvInt(key: String): ?Int64 {
    let raw = readEnv(key)
    if (let Some(v) <- raw) {
        if (let Some(val) <- Int64.tryParse(v)) {
            Some(val)
        } else {
            log.warn{"readEnvInt(${key}) parse failed for value '${v}'"}
            None
        }
    } else {
        None
    }
}
