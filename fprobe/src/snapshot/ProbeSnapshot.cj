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
package fountain::fprobe.snapshot

import std.sync.Mutex
import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 单个监控项的 RPC 视图。
 *
 * `JsonObject` 不是 `DataFields`，跨 RPC 只能传 JSON 文本；`dataJson` 就是
 * `JsonValue.from(agent.data).toString()` 的结果。失败时 `error` 非空，
 * `dataJson` 与 `collectedAt` 保留上一次成功的值。
 */
@DataAssist[fields props]
public class ProbeAgentData {
    private var kind: String = ""
    private var host: String = ""
    private var dataJson: String = "{}"
    private var collectedAt: Int64 = 0
    private var error: String = ""

    public init() {}

    public init(kind: String, host: String, dataJson: String, collectedAt: Int64, error: String) {
        this.kind = kind
        this.host = host
        this.dataJson = dataJson
        this.collectedAt = collectedAt
        this.error = error
    }
}

/** 一个节点一次采集的完整快照，作为 RPC 响应体整体传输。 */
@DataAssist[fields props]
public class ProbeSnapshot {
    private var node: String = ""
    private var host: String = ""
    private var timestamp: Int64 = 0
    private var agents: Array<ProbeAgentData> = []

    public init() {}

    public init(node: String, host: String, timestamp: Int64, agents: Array<ProbeAgentData>) {
        this.node = node
        this.host = host
        this.timestamp = timestamp
        this.agents = agents
    }
}

/** `kinds()` 的响应 DTO；`Array<String>` 不能直接作为 `DataFields` 返回。 */
@DataAssist[fields props]
public class ProbeKinds {
    private var kinds: Array<String> = []

    public init() {}

    public init(kinds: Array<String>) {
        this.kinds = kinds
    }
}

/**
 * 快照仓库：单写者整体替换，多读者无锁竞争地拿到同一批不可变快照。
 *
 * 锁只保护引用赋值与读取；发布后的 `ProbeSnapshot` 约定不再修改，
 * 因此 `collect()` 返回后可以安全地在锁外遍历。
 */
public class SnapshotStore {
    private let lock = Mutex()
    private var current = ProbeSnapshot()

    public init() {}

    /** 整体替换当前快照。 */
    public func replace(snapshot: ProbeSnapshot): Unit {
        synchronized(lock) {
            current = snapshot
        }
    }

    /** 读取当前快照；不复制、不触发采集。 */
    public func collect(): ProbeSnapshot {
        synchronized(lock) {
            current
        }
    }
}
