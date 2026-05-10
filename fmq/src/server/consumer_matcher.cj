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
package fountain::fmq.server

import std.collection.HashMap
import std.sync.Mutex

/**
 * 消费者匹配器。
 * 从本地缓存获取消费者注册信息，按 topic 模式匹配，同组 Round-Robin 选择。
 * 所有公共方法通过 Mutex 保证并发安全。
 */
public class ConsumerMatcher {
    private let log = LoggerFactory.getLogger('fountain::fmq.ConsumerMatcher')
    private var registrations = ArrayList<ConsumerRegistration>()
    private var roundRobinIndex = HashMap<String, Int64>()  // groupId → next index
    private let mutex = Mutex()

    public func register(registration: ConsumerRegistration): Unit {
        synchronized(mutex) {
            // 查找是否已存在相同 consumerId 的注册
            for (i in 0..registrations.size) {
                if (registrations[i].consumerId == registration.consumerId) {
                    // 更新已有注册（保留其 consumerId/groupId，刷新其他字段）
                    let existing = registrations[i]
                    registrations[i] = ConsumerRegistration(
                        consumerId: existing.consumerId,
                        groupId: existing.groupId,
                        matchModeStr: registration.matchModeStr,
                        labels: registration.labels,
                        dataFilter: registration.dataFilter,
                        lastHeartbeat: registration.lastHeartbeat)
                    return
                }
            }
            registrations.add(registration)
        }
    }

    public func deregister(groupId: String, consumerId: String): Bool {
        let result: Bool
        synchronized(mutex) {
            let remaining = ArrayList<ConsumerRegistration>()
            for (r in registrations) {
                if (!(r.groupId == groupId && r.consumerId == consumerId)) {
                    remaining.add(r)
                }
            }
            result = remaining.size < registrations.size
            registrations = remaining
        }
        result
    }

    public func refresh(): Unit {
        let timeoutDuration = Duration.second * 5 * 3
        let now = DateTime.now()
        synchronized(mutex) {
            let remaining = ArrayList<ConsumerRegistration>()
            for (r in registrations) {
                if (now - r.lastHeartbeat < timeoutDuration) {
                    remaining.add(r)
                }
            }
            registrations = remaining
        }
    }

    /**
     * 匹配消费者。通过快照方式读取，减少锁持有时间。
     */
    public func matchTopic(topic: String): HashMap<String, String> {
        let snapshot: ArrayList<ConsumerRegistration>
        let rrSnapshot: HashMap<String, Int64>
        synchronized(mutex) {
            snapshot = ArrayList<ConsumerRegistration>()
            for (r in registrations) { snapshot.add(r) }
            rrSnapshot = HashMap<String, Int64>()
            for ((k, v) in roundRobinIndex) { rrSnapshot[k] = v }
        }
        let result = HashMap<String, String>()
        let groups = HashMap<String, ArrayList<ConsumerRegistration>>()
        for (reg in snapshot) {
            if (matchesTopic(reg.getMatchMode(), topic)) {
                let list = if (let Some(g) <- groups.get(reg.groupId)) { g }
                    else { let g = ArrayList<ConsumerRegistration>(); groups[reg.groupId] = g; g }
                list.add(reg)
            }
        }
        for ((groupId, consumers) in groups) {
            let index = (rrSnapshot.get(groupId) ?? 0) % consumers.size
            let selected = consumers[index]
            result[groupId] = selected.consumerId
            rrSnapshot[groupId] = (index + 1) % consumers.size
        }
        synchronized(mutex) {
            for ((k, v) in rrSnapshot) { roundRobinIndex[k] = v }
        }
        result
    }

    private func matchesTopic(mode: MatchMode, topic: String): Bool {
        match (mode) {
            case Exact(pattern) => pattern == topic
            case Glob(pattern) => globMatches(pattern, topic)
            case Prefix(pattern) => topic.startsWith(pattern)
        }
    }

    private func globMatches(pattern: String, topic: String): Bool {
        let pp = PathPattern()
        pp.compile(pattern)
        pp.matches(topic)
    }
}
