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
package fountain::fprobe.collect.health

import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 与 `f_health.HealthData` 同名的可写快照。
 *
 * `HealthData` 的字段是只读计算属性，无法从 RPC/HTTP 响应中回填（`ReadonlyField` 没有 setter）；
 * 这里用同名字段声明一个可反序列化的 DTO，保证对端真实的健康数值能落到本端数据里。
 */
@DataAssist[props fields]
public class HealthMetrics {
    private var allocatedHeapSize: Int64 = 0
    private var heapPhysicalMemory: Int64 = 0
    private var blockingThreadCount: Int64 = 0
    private var gcCount: Int64 = 0
    private var gcFreedSize: Int64 = 0
    private var gcTime: Int64 = 0
    private var maxHeapSize: Int64 = 0
    private var nativeThreadCount: Int64 = 0
    private var processorCount: Int64 = 0
    private var threadCount: Int64 = 0
    private var usedHeapSize: Int64 = 0

    public init() {}

    public init(allocatedHeapSize: Int64, heapPhysicalMemory: Int64, blockingThreadCount: Int64, gcCount: Int64,
        gcFreedSize: Int64, gcTime: Int64, maxHeapSize: Int64, nativeThreadCount: Int64, processorCount: Int64,
        threadCount: Int64, usedHeapSize: Int64) {
        this.allocatedHeapSize = allocatedHeapSize
        this.heapPhysicalMemory = heapPhysicalMemory
        this.blockingThreadCount = blockingThreadCount
        this.gcCount = gcCount
        this.gcFreedSize = gcFreedSize
        this.gcTime = gcTime
        this.maxHeapSize = maxHeapSize
        this.nativeThreadCount = nativeThreadCount
        this.processorCount = processorCount
        this.threadCount = threadCount
        this.usedHeapSize = usedHeapSize
    }

    /** 从 JSON 文本解析；失败返回 None，由探针转成可读错误。 */
    public static func tryParse(text: String): ?HealthMetrics {
        try {
            match (JsonValue.fromStr(text)) {
                case object: JsonObject => tryFrom(object.toData())
                case _ => None<HealthMetrics>
            }
        } catch (_: Exception) {
            None<HealthMetrics>
        }
    }

    /** 从 RPC/HTTP 的 `Data` 树解析。 */
    public static func tryFrom(data: Data): ?HealthMetrics {
        match (HealthMetrics.tryFromData(data)) {
            case metrics: HealthMetrics => Some(metrics)
            case metrics: ?HealthMetrics => metrics
            case _ => None<HealthMetrics>
        }
    }
}

/** 健康探针的统一数据形状：HealthData 全字段 + 耗时 + 状态码/错误。 */
@DataAssist[props fields]
public class HealthSample {
    private var allocatedHeapSize: Int64 = 0
    private var heapPhysicalMemory: Int64 = 0
    private var blockingThreadCount: Int64 = 0
    private var gcCount: Int64 = 0
    private var gcFreedSize: Int64 = 0
    private var gcTime: Int64 = 0
    private var maxHeapSize: Int64 = 0
    private var nativeThreadCount: Int64 = 0
    private var processorCount: Int64 = 0
    private var threadCount: Int64 = 0
    private var usedHeapSize: Int64 = 0
    private var latencyMs: Float64 = 0.0
    private var statusCode: Int64 = 0
    private var error: String = ""

    public init() {}

    public init(metrics: HealthMetrics, latencyMs: Float64, statusCode: Int64, error: String) {
        this.allocatedHeapSize = metrics.allocatedHeapSize
        this.heapPhysicalMemory = metrics.heapPhysicalMemory
        this.blockingThreadCount = metrics.blockingThreadCount
        this.gcCount = metrics.gcCount
        this.gcFreedSize = metrics.gcFreedSize
        this.gcTime = metrics.gcTime
        this.maxHeapSize = metrics.maxHeapSize
        this.nativeThreadCount = metrics.nativeThreadCount
        this.processorCount = metrics.processorCount
        this.threadCount = metrics.threadCount
        this.usedHeapSize = metrics.usedHeapSize
        this.latencyMs = latencyMs
        this.statusCode = statusCode
        this.error = error
    }

    public init(latencyMs: Float64, statusCode: Int64, error: String) {
        this(HealthMetrics(), latencyMs, statusCode, error)
    }
}
