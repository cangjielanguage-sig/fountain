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

/**
 * 消费者匹配器。
 * 从本地缓存获取消费者注册信息，按 topic 模式匹配，同组 Round-Robin 选择。
 */
public class ConsumerMatcher {
    private let log = LoggerFactory.getLogger('fountain::fmq.ConsumerMatcher')
    private var registrations = ArrayList<ConsumerRegistration>()
    private var roundRobinIndex = HashMap<String, Int64>()  // groupId → next index

    /**
     * 注册消费者。
     * Phase 6: 本地缓存 + 持久化到 fleet /mq/consumes。
     */
    public func register(registration: ConsumerRegistration): Unit {
        registrations.add(registration)
        log.info{"registered consumer ${registration.consumerId} in group ${registration.groupId}"}
    }

    /**
     * 注销消费者。
     */
    public func deregister(groupId: String, consumerId: String): Bool {
        let before = registrations.size
        let remaining = ArrayList<ConsumerRegistration>()
        for (r in registrations) {
            if (!(r.groupId == groupId && r.consumerId == consumerId)) {
                remaining.add(r)
            }
        }
        registrations = remaining
        registrations.size < before
    }

    /**
     * 刷新消费者注册缓存。
     * Phase 7: 清理心跳超时的消费者（超时 = heartbeatIntervalSec × healthcheckMaxRetry）。
     * Phase 8: 从 fsync /mq/consumes 加载。
     */
    public func refresh(): Unit {
        let timeoutDuration = Duration.second * 5 * 3  // 5s × 3 = 15s 超时
        let now = DateTime.now()
        let remaining = ArrayList<ConsumerRegistration>()
        for (r in registrations) {
            if (now - r.lastHeartbeat < timeoutDuration) {
                remaining.add(r)
            } else {
                log.debug{"removed stale registration: ${r.consumerId}"}
            }
        }
        registrations = remaining
    }

    /**
     * 匹配消费者。
     * 输入：消息 topic
     * 输出：map[groupId → consumerId]
     */
    public func matchTopic(topic: String): HashMap<String, String> {
        let result = HashMap<String, String>()

        // 按消费者组分组
        let groups = HashMap<String, ArrayList<ConsumerRegistration>>()
        for (reg in registrations) {
            if (matchesTopic(reg.getMatchMode(), topic)) {
                let list = if (let Some(g) <- groups.get(reg.groupId)) {
                    g
                } else {
                    let g = ArrayList<ConsumerRegistration>()
                    groups[reg.groupId] = g
                    g
                }
                list.add(reg)
            }
        }

        // 每组 Round-Robin 选一个
        for ((groupId, consumers) in groups) {
            let index = roundRobinIndex.get(groupId) ?? 0
            let selected = consumers[index]
            result[groupId] = selected.consumerId
            roundRobinIndex[groupId] = (index + 1) % consumers.size
        }
        result
    }

    /**
     * 匹配 topic 与 MatchMode。
     */
    private func matchesTopic(mode: MatchMode, topic: String): Bool {
        match (mode) {
            case Exact(pattern) => pattern == topic
            case Glob(pattern) => globMatches(pattern, topic)
            case Prefix(pattern) => topic.startsWith(pattern)
        }
    }

    /**
     * PathPattern glob 匹配。
     */
    private func globMatches(pattern: String, topic: String): Bool {
        let pp = PathPattern()
        pp.compile(pattern)
        pp.matches(topic)
    }
}
