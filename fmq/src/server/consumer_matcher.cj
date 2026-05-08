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
     * 刷新消费者注册缓存（从 fsync /mq/consumes 读取）。
     * Phase 4 为本地空实现，fsync 集成在后续阶段。
     */
    public func refresh(): Unit {
        // Phase 4: 从 fsync 读取 /mq/consumes 并反序列化为 registrations
        // this.registrations = loadFromFsync()
        log.debug("ConsumerMatcher refresh (placeholder)")
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
