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
package fountain::fprobe.collect

import fountain::f_data.*
import fountain::f_probe.ProbeAgent
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}

/**
 * 把探针输出转换成 RPC 可传输的快照结构。
 *
 * `dataJson` 是 `JsonValue.from(agent.data).toString()`：`data` 本身是
 * `JsonObject`，不能直接作为 `DataFields` 跨 RPC，因此统一转成 JSON 文本。
 */
public class ProbeSnapshotBuilder {
    public init() {}

    /** 单个探针的数据编码。 */
    public static func encode(agent: ProbeAgent): String {
        JsonValue.from(agent.data).toString()
    }

    /**
     * 构造单个探针的数据项。
     *
     * `agent.host` 为空时使用节点级默认 host；`error` 由调用方传入，
     * 便于在失败时复用上一次成功的数据。
     */
    public static func agentData(agent: ProbeAgent, defaultHost: String, collectedAt: Int64,
        error!: String = ""): ProbeAgentData {
        let host = if (agent.host.isEmpty()) {
            defaultHost
        } else {
            agent.host
        }
        ProbeAgentData(agent.kind, host, encode(agent), collectedAt, error)
    }

    /** 组装整批快照。 */
    public static func build(node: String, host: String, timestamp: Int64,
        agents: Array<ProbeAgentData>): ProbeSnapshot {
        ProbeSnapshot(node, host, timestamp, agents)
    }
}
