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
    private var consumerIdIndex = HashMap<String, Int64>()  // consumerId → position for O(1) lookup
    private var roundRobinIndex = HashMap<String, Int64>()  // groupId → next index
    private let mutex = Mutex()
    // P3-4: 缓存编译后的 PathPattern，避免每次匹配重新 compile
    private var compiledPatterns = HashMap<String, PathPattern>()
    private let timeoutDuration: Duration  // 消费者心跳超时阈值

    public init(heartbeatIntervalSec!: Int64 = 5) {
        // 超时 = 心跳间隔 × 3（允许丢失 2 次心跳）
        this.timeoutDuration = Duration.second * heartbeatIntervalSec * 3
    }

    public func register(registration: ConsumerRegistration): Unit {
        synchronized(mutex) {
            // O(1) lookup using consumerIdIndex
            if (let Some(existingPos) <- consumerIdIndex.get(registration.consumerId)) {
                let existing = registrations[existingPos]
                registrations[existingPos] = ConsumerRegistration(
                    consumerId: existing.consumerId,
                    groupId: existing.groupId,
                    matchModeStr: registration.matchModeStr,
                    labels: registration.labels,
                    dataFilter: registration.dataFilter,
                    lastHeartbeat: registration.lastHeartbeat)
                return
            }
            let pos = registrations.size
            registrations.add(registration)
            consumerIdIndex[registration.consumerId] = pos
        }
    }

    public func deregister(groupId: String, consumerId: String): Bool {
        let result: Bool
        synchronized(mutex) {
            // O(1) lookup
            if (let Some(pos) <- consumerIdIndex.get(consumerId)) {
                let r = registrations[pos]
                if (r.groupId == groupId) {
                    registrations.remove(at: pos)
                    consumerIdIndex.remove(consumerId)
                    // 修正移除位置之后所有条目的索引
                    for (i in pos..registrations.size) {
                        consumerIdIndex[registrations[i].consumerId] = i
                    }
                    // P2-2: 修正 roundRobinIndex，使用组内消费者数而非全局 registrations.size
                    if (let Some(idx) <- roundRobinIndex.get(groupId)) {
                        var groupCount = 0
                        for (reg in registrations) {
                            if (reg.groupId == groupId) { groupCount += 1 }
                        }
                        if (groupCount > 0) {
                            roundRobinIndex[groupId] = idx % groupCount
                        } else {
                            roundRobinIndex.remove(groupId)
                        }
                    }
                    result = true
                } else { result = false }
            } else { result = false }
        }
        result
    }

    public func refresh(): Unit {
        let now = DateTime.now()
        let td = timeoutDuration
        synchronized(mutex) {
            let remaining = ArrayList<ConsumerRegistration>()
            let newIndex = HashMap<String, Int64>()
            for (r in registrations) {
                if (now - r.lastHeartbeat < td) {
                    newIndex[r.consumerId] = remaining.size
                    remaining.add(r)
                }
            }
            registrations = remaining
            consumerIdIndex = newIndex
        }
    }

    /**
     * 匹配消费者。全程持锁确保 Round-Robin 索引原子更新。
     */
    public func matchTopic(topic: String): HashMap<String, String> {
        let result = HashMap<String, String>()
        synchronized(mutex) {
            let groups = HashMap<String, ArrayList<ConsumerRegistration>>()
            for (reg in registrations) {
                if (matchesTopic(reg.getMatchMode(), topic)) {
                    let list = if (let Some(g) <- groups.get(reg.groupId)) { g }
                        else { let g = ArrayList<ConsumerRegistration>(); groups[reg.groupId] = g; g }
                    list.add(reg)
                }
            }
            for ((groupId, consumers) in groups) {
                let index = (roundRobinIndex.get(groupId) ?? 0) % consumers.size
                let selected = consumers[index]
                result[groupId] = selected.consumerId
                roundRobinIndex[groupId] = (index + 1) % consumers.size
            }
        }
        result
    }

    /**
     * 获取所有在线消费者注册的快照。
     */
    public func getRegistrations(): ArrayList<ConsumerRegistration> {
        let result = ArrayList<ConsumerRegistration>()
        synchronized(mutex) {
            for (r in registrations) {
                result.add(r)
            }
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

    private static let MAX_COMPILED_PATTERNS: Int64 = 1000

    private func globMatches(pattern: String, topic: String): Bool {
        let pp = if (let Some(cached) <- compiledPatterns.get(pattern)) { cached }
            else {
                // 缓存超限时整体清空（简单策略，避免 LRU 复杂度）
                if (compiledPatterns.size >= MAX_COMPILED_PATTERNS) {
                    compiledPatterns = HashMap<String, PathPattern>()
                    log.warn{"compiledPatterns cache full (${MAX_COMPILED_PATTERNS}), cleared"}
                }
                let p = PathPattern()
                p.compile(pattern)
                compiledPatterns[pattern] = p
                p
            }
        pp.matches(topic)
    }
}
