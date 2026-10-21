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
package fountain::f_mq.client

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.time.DateTime

/**
 * 主题 → 所有者节点下标缓存（带 TTL）。
 *
 * 时间源可注入，便于用例在不等待真实时间的前提下验证过期与替换。
 */
internal class MQOwnershipCache {
    private let ttl: Duration
    private let now: () -> DateTime
    private let entries = ConcurrentHashMap<String, (Array<Int64>, DateTime)>()

    init(ttl!: Duration = Duration.minute, now!: () -> DateTime = {=> DateTime.now()}) {
        this.ttl = ttl
        this.now = now
    }

    func ownersOf(topic: String): ?Array<Int64> {
        match (entries.get(topic)) {
            case None => None<Array<Int64>>
            case Some(entry) =>
                if (now() >= entry[1]) {
                    entries.remove(topic)
                    None<Array<Int64>>
                } else {
                    Some(entry[0])
                }
        }
    }

    func put(topic: String, owners: Array<Int64>): Unit {
        entries.add(topic, (owners, now() + ttl))
    }

    func invalidate(topic: String): Unit {
        entries.remove(topic)
    }

    func clear(): Unit {
        let topics = ArrayList<String>()
        for ((topic, _) in entries) {
            topics.add(topic)
        }
        for (topic in topics) {
            entries.remove(topic)
        }
    }
}
