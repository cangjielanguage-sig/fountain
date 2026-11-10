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
package fountain::fprobe.supervisor

import fountain::fprobe.snapshot.ProbeSnapshot

/** 节点在当前 tick 的连通状态。 */
public enum NodeStatus <: Equatable<NodeStatus> {
    | ONLINE
    | OFFLINE

    public operator func ==(other: NodeStatus): Bool {
        match ((this, other)) {
            case (ONLINE, ONLINE) | (OFFLINE, OFFLINE) => true
            case _ => false
        }
    }
}

/** 节点级事件：连续失败达阈值时为 `UNREACHABLE`，恢复时为 `RECOVERED`。 */
public enum NodeEventType <: Equatable<NodeEventType> {
    | UNREACHABLE
    | RECOVERED

    public operator func ==(other: NodeEventType): Bool {
        match ((this, other)) {
            case (UNREACHABLE, UNREACHABLE) | (RECOVERED, RECOVERED) => true
            case _ => false
        }
    }
}

/**
 * 一个节点的监督状态快照。
 *
 * 每次 tick 整体替换，不在原地修改；失败时 `snapshot` 保留上一次成功的值，
 * `error` 携带本次失败原因，避免历史与 TUI 出现伪造的 0 值。
 */
public class NodeState {
    public let node: String
    public let status: NodeStatus
    public let consecutiveFailures: Int64
    public let snapshot: ?ProbeSnapshot
    public let error: String
    public let updatedAt: Int64

    public init(node: String, status: NodeStatus, consecutiveFailures: Int64, snapshot: ?ProbeSnapshot,
        error: String, updatedAt: Int64) {
        this.node = node
        this.status = status
        this.consecutiveFailures = consecutiveFailures
        this.snapshot = snapshot
        this.error = error
        this.updatedAt = updatedAt
    }
}

/** 节点不可达 / 恢复事件，供告警引擎与日志消费。 */
public class NodeEvent {
    public let eventType: NodeEventType
    public let node: String
    public let failures: Int64
    public let timestamp: Int64
    public let message: String

    public init(eventType: NodeEventType, node: String, failures: Int64, timestamp: Int64, message: String) {
        this.eventType = eventType
        this.node = node
        this.failures = failures
        this.timestamp = timestamp
        this.message = message
    }
}
