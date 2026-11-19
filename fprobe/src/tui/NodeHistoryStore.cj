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
package fountain::fprobe.tui

import std.collection.HashMap
import std.sync.Mutex
import fountain::fprobe.snapshot.ProbeAgentData
import fountain::fprobe.supervisor.HistoryRing

/**
 * 每个节点、每个指标一个定长历史窗口。
 *
 * 拉取线程每 tick 调 [observe] 追加；TUI 只调 [values] 读副本，锁覆盖范围
 * 仅一次 HashMap 查找与一次数组复制。
 */
public class NodeHistoryStore <: HistorySource {
    private let capacity: Int64
    private let lock = Mutex()
    private let rings = HashMap<String, HistoryRing>()

    public init(capacity: Int64) {
        this.capacity = capacity
    }

    public func record(node: String, metricKey: String, value: Float64): Unit {
        synchronized(lock) {
            let key = ringKey(node, metricKey)
            match (rings.get(key)) {
                case Some(ring) => ring.append(value)
                case None =>
                    let ring = HistoryRing(capacity)
                    ring.append(value)
                    rings[key] = ring
            }
        }
    }

    public func values(node: String, metricKey: String): Array<Float64> {
        synchronized(lock) {
            match (rings.get(ringKey(node, metricKey))) {
                case Some(ring) => ring.values()
                case None => Array<Float64>()
            }
        }
    }

    /** 按指标目录把一次快照中所有可数值化的指标写入历史。 */
    public func observe(node: String, agents: Array<ProbeAgentData>): Unit {
        for (spec in ProjectionCatalog.all()) {
            let kind = spec.projection.kind
            for (agent in agents) {
                if (agent.kind != kind || !agent.error.isEmpty()) {
                    continue
                }
                match (spec.projection.evaluate(agent.dataJson)) {
                    case Some(value) => record(node, spec.projection.key(), value)
                    case None => ()
                }
            }
        }
    }

    private static func ringKey(node: String, metricKey: String): String {
        "${node}|${metricKey}"
    }
}
