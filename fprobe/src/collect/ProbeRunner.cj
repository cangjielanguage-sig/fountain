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

import fountain::f_probe.ProbeAgent
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot, SnapshotStore}

/** 单个探针的运行期槽位：保存最后一次成功的数据与当前错误。 */
class ProbeSlot {
    let agent: ProbeAgent
    var dataJson: String = ""
    var collectedAt: Int64 = 0
    var error: String = ""

    init(agent: ProbeAgent) {
        this.agent = agent
    }
}

/**
 * 采集运行器：周期性对全部探针取数，并把结果整体发布到 [SnapshotStore]。
 *
 * - 每个探针的异常在 tick 内被收敛为 `error`，不影响其它探针；
 * - 失败时保留上一次成功的数据与时间戳；
 * - `warmup()` 在首帧前先取一轮建立差分基线，CPU 使用率不会从 0 开始。
 */
public class ProbeRunner {
    private let slots: Array<ProbeSlot>
    private let store: SnapshotStore
    private let clock: Clock
    private let node: String
    private let host: String
    private let warmupMs: Int64

    public init(agents: Array<ProbeAgent>, store: SnapshotStore, clock: Clock, node!: String = "",
        host!: String = "", warmupMs!: Int64 = 200) {
        this.slots = Array<ProbeSlot>(agents.size) {i => ProbeSlot(agents[i])}
        this.store = store
        this.clock = clock
        this.node = node
        this.host = host
        this.warmupMs = warmupMs
    }

    /**
     * 预热：先取一轮建立差分基线，再等待 `warmupMs`。
     *
     * 预热结果不发布；CPU/磁盘/网络探针在第二次取数时才有有效速率。
     */
    public func warmup(): Unit {
        for (slot in slots) {
            try {
                slot.agent.data
            } catch (_: Exception) {
                ()
            } catch (_: Error) {
                ()
            }
        }
        clock.wait(warmupMs)
    }

    /** 执行一轮采集并整体替换快照；返回刚发布的快照。 */
    public func tick(): ProbeSnapshot {
        let collectedAt = clock.nowMs()
        let entries = Array<ProbeAgentData>(slots.size) {i =>
            let slot = slots[i]
            try {
                slot.dataJson = ProbeSnapshotBuilder.encode(slot.agent)
                slot.collectedAt = collectedAt
                slot.error = ""
            } catch (e: Exception) {
                slot.error = e.message
            } catch (e: Error) {
                slot.error = e.message
            }
            let resolvedHost = if (slot.agent.host.isEmpty()) {
                host
            } else {
                slot.agent.host
            }
            ProbeAgentData(slot.agent.kind, resolvedHost, slot.dataJson, slot.collectedAt, slot.error)
        }
        let snapshot = ProbeSnapshotBuilder.build(node, host, collectedAt, entries)
        store.replace(snapshot)
        snapshot
    }

    /** 最近一次发布的快照；不触发采集。 */
    public func snapshot(): ProbeSnapshot {
        store.collect()
    }
}
