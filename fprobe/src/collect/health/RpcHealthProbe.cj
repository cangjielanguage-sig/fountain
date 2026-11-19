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

import std.collection.ArrayList
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_probe.ProbeAgent
import fountain::fprobe.rpc.NodeEndpoint

/** 单个 RPC 健康目标的读数。 */
@DataAssist[props fields]
public class RpcHealthTarget {
    private var name: String = ""
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
    private var error: String = ""

    public init() {}

    public init(name: String, metrics: ?HealthMetrics, latencyMs: Float64, error: String) {
        this.name = name
        this.latencyMs = latencyMs
        this.error = error
        match (metrics) {
            case Some(value) =>
                this.allocatedHeapSize = value.allocatedHeapSize
                this.heapPhysicalMemory = value.heapPhysicalMemory
                this.blockingThreadCount = value.blockingThreadCount
                this.gcCount = value.gcCount
                this.gcFreedSize = value.gcFreedSize
                this.gcTime = value.gcTime
                this.maxHeapSize = value.maxHeapSize
                this.nativeThreadCount = value.nativeThreadCount
                this.processorCount = value.processorCount
                this.threadCount = value.threadCount
                this.usedHeapSize = value.usedHeapSize
            case None => ()
        }
    }
}

/** `rpc-health` 监控项的数据形状。 */
@DataAssist[props fields]
public class RpcHealthSample {
    private var targets: Array<RpcHealthTarget> = []

    public init() {}

    public init(targets: Array<RpcHealthTarget>) {
        this.targets = targets
    }
}

/**
 * RPC 健康探针。
 *
 * 每个 `probe_rpcHealthTargets` 目标一次定向调用，失败只影响该目标。
 */
public class RpcHealthProbe <: ProbeAgent {
    private let transport: HealthRpcTransport
    private let targets: Array<NodeEndpoint>
    private let timeoutMs: Int64

    public init(transport: HealthRpcTransport, targets: Array<NodeEndpoint>, timeoutMs!: Int64 = 3000) {
        this.transport = transport
        this.targets = targets
        this.timeoutMs = timeoutMs
    }

    public prop kind: String {
        get() {
            "rpc-health"
        }
    }

    public prop data: JsonObject {
        get() {
            let readings = ArrayList<RpcHealthTarget>()
            for (target in targets) {
                var result = HealthRpcResult(None, "", false, 0.0)
                try {
                    result = transport.call(target, timeoutMs)
                } catch (e: Exception) {
                    result = HealthRpcResult(None, 'RPC 调用失败: ${e.message}', false, 0.0)
                }
                readings.add(RpcHealthTarget(target.name, result.metrics, result.latencyMs, result.error))
            }
            JsonValue.from(RpcHealthSample(readings.toArray()).toData()).asObject()
        }
    }
}
