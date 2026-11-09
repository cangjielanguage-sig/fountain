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

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

/**
 * 全部节点状态的并发仓库（设计 D9）。
 *
 * 写者每 tick 整体替换某个节点的 `NodeState`；读者（TUI、报告、告警）在锁内
 * 取出引用即可，锁覆盖的时间只有一次 HashMap 操作。
 */
public class NodeStateStore {
    private let lock = Mutex()
    private let states = HashMap<String, NodeState>()

    public init() {}

    /** 写入或替换一个节点的状态。 */
    public func update(state: NodeState): Unit {
        synchronized(lock) {
            states[state.node] = state
        }
    }

    /** 读取单个节点；不存在返回 `None`。 */
    public func get(node: String): ?NodeState {
        synchronized(lock) {
            states.get(node)
        }
    }

    /** 全部节点状态的快照，按节点名排序，便于渲染与断言稳定。 */
    public func all(): Array<NodeState> {
        synchronized(lock) {
            let result = ArrayList<NodeState>()
            for ((_, state) in states) {
                result.add(state)
            }
            let snapshot = result.toArray()
            sortByNode(snapshot)
            snapshot
        }
    }

    private static func sortByNode(values: Array<NodeState>): Unit {
        var i: Int64 = 1
        while (i < values.size) {
            let current = values[i]
            var j = i - 1
            while (j >= 0 && values[j].node > current.node) {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = current
            i += 1
        }
    }
}
