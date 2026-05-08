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

/**
 * MQ 配置，所有字段从环境变量加载。
 */
public class MqConfig {
    let mqHosts: ArrayList<String>
    let syncHosts: ArrayList<String>
    let heartbeatIntervalSec: Int64
    let healthcheckMaxRetry: Int64
    let idleTimeoutMinutes: Int64
    let ackTimeoutMs: Int64
    let dataDir: String
    let segmentMaxSize: Int64
    let retentionHours: Int64
    let maxRetryCount: Int64
    let retryIntervalMs: Int64
    let dlqRetentionHours: Int64
    let maxMessageSize: Int64
    let maxLabelsPerMessage: Int64
    let syncQuorum: Int64

    public init(mqHosts!: ArrayList<String>, syncHosts!: ArrayList<String>,
                dataDir!: String, segmentMaxSize!: Int64,
                heartbeatIntervalSec!: Int64, healthcheckMaxRetry!: Int64,
                idleTimeoutMinutes!: Int64, ackTimeoutMs!: Int64,
                maxRetryCount!: Int64, retryIntervalMs!: Int64,
                dlqRetentionHours!: Int64, maxMessageSize!: Int64,
                maxLabelsPerMessage!: Int64, retentionHours!: Int64,
                syncQuorum!: Int64) {
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
        segmentMaxSize: readEnvInt("mq_segment_max_size") ?? 512 * 1024 * 1024,
        heartbeatIntervalSec: readEnvInt("mq_heartbeat_interval_sec") ?? 5,
        healthcheckMaxRetry: readEnvInt("mq_healthcheck_max_retry") ?? 3,
        idleTimeoutMinutes: readEnvInt("mq_idle_timeout_minutes") ?? 30,
        ackTimeoutMs: readEnvInt("mq_ack_timeout_ms") ?? 30000,
        maxRetryCount: readEnvInt("mq_max_retry_count") ?? 3,
        retryIntervalMs: readEnvInt("mq_retry_interval_ms") ?? 1000,
        dlqRetentionHours: readEnvInt("mq_dlq_retention_hours") ?? 168,
        maxMessageSize: readEnvInt("mq_max_message_size") ?? 4 * 1024 * 1024,
        maxLabelsPerMessage: readEnvInt("mq_max_labels_per_message") ?? 64,
        retentionHours: readEnvInt("mq_retention_hours") ?? 72,
        syncQuorum: readEnvInt("mq_sync_quorum") ?? 1
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
    } catch (_: Exception) {
        None
    }
}

/**
 * 读取环境变量，按英文逗号分割为 ArrayList<String>。
 * 空变量返回空列表。
 */
public func readEnvList(key: String): ArrayList<String> {
    let raw = readEnv(key)
    if (let Some(v) <- raw) {
        let parts = v.split(',')
        let result = ArrayList<String>()
        for (p in parts) {
            let trimmed = p.trimAscii()
            if (!trimmed.isEmpty()) {
                result.add(trimmed)
            }
        }
        result
    } else {
        ArrayList()
    }
}

/**
 * 读取环境变量，解析为 Int64。
 */
public func readEnvInt(key: String): ?Int64 {
    let raw = readEnv(key)
    if (let Some(v) <- raw) {
        try {
            Some(Int64.parse(v))
        } catch (_: Exception) {
            None
        }
    } else {
        None
    }
}
