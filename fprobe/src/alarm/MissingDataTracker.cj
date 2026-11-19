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
package fountain::fprobe.alarm

import std.collection.{ArrayList, HashMap, HashSet}

/**
 * 数据缺失条件去重表。
 *
 * 同一 `(节点, 类别, kind)` 只告警一次；条件消失时把原事件交给调用方决定
 * 是否发送恢复通知。
 */
public class MissingDataTracker {
    private let active = HashMap<String, AlarmEvent>()

    public init() {}

    /** 记录一个缺失条件；首次出现返回 true。 */
    public func raise(key: String, event: AlarmEvent): Bool {
        if (active.contains(key)) {
            return false
        }
        active[key] = event
        true
    }

    /** 本批节点中已消失的条件；返回后从活动集合移除。 */
    public func collectRecovered(nodes: HashSet<String>, currentKeys: HashSet<String>): Array<AlarmEvent> {
        let recovered = ArrayList<AlarmEvent>()
        let stale = ArrayList<String>()
        for ((key, event) in active) {
            if (nodes.contains(event.node) && !currentKeys.contains(key)) {
                stale.add(key)
                recovered.add(event)
            }
        }
        for (key in stale) {
            active.remove(key)
        }
        recovered.toArray()
    }
}
