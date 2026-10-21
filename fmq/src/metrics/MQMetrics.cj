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
package fountain::fmq.metrics

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64

/**
 * 节点内指标计数器。
 *
 * 只保存进程启动以来的累计值；`backlog` / `lagMs` 由查询方按游标位置实时计算。
 * 键为 `topic\0group\0name`，并发自增，不阻塞消息路径。
 */
protected class MQMetrics {
    private let counters = ConcurrentHashMap<String, AtomicInt64>()

    private static func key(topic: String, group: String, name: String): String {
        "${topic}\u{0}${group}\u{0}${name}"
    }

    private func bump(topic: String, group: String, name: String): Unit {
        let key = key(topic, group, name)
        counters.addIfAbsent(key, AtomicInt64(0))
        counters.get(key).getOrThrow().fetchAdd(1)
    }

    private func valueOf(topic: String, group: String, name: String): Int64 {
        match (counters.get(key(topic, group, name))) {
            case Some(counter) => counter.load()
            case None => 0
        }
    }

    /** 删除主题时清空计数器，避免同名重建复用旧值（A61）。 */
    protected func removeTopic(topic: String): Unit {
        let prefix = "${topic}\u{0}"
        let victims = ArrayList<String>()
        for ((key, _) in counters) {
            if (key.startsWith(prefix)) {
                victims.add(key)
            }
        }
        for (key in victims) {
            counters.remove(key)
        }
    }

    /** 删除订阅组时清空计数器。 */
    protected func removeGroup(topic: String, group: String): Unit {
        let prefix = "${topic}\u{0}${group}\u{0}"
        let victims = ArrayList<String>()
        for ((key, _) in counters) {
            if (key.startsWith(prefix)) {
                victims.add(key)
            }
        }
        for (key in victims) {
            counters.remove(key)
        }
    }

    /** 当前计数器条目数（用例断言清理效果）。 */
    protected prop size: Int64 {
        get() {
            counters.size
        }
    }

    protected func incDelivered(topic: String, group: String): Unit {
        bump(topic, group, "delivered")
    }

    protected func incAcked(topic: String, group: String): Unit {
        bump(topic, group, "acked")
    }

    protected func incRedelivered(topic: String, group: String): Unit {
        bump(topic, group, "redelivered")
    }

    protected func incDeadLettered(topic: String, group: String): Unit {
        bump(topic, group, "deadLettered")
    }

    protected func deliveredOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "delivered")
    }

    protected func ackedOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "acked")
    }

    protected func redeliveredOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "redelivered")
    }

    protected func deadLetteredOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "deadLettered")
    }

    // ===== 跳过计数（R3-M4/M8）：只统计「越过」，损坏不计入 =====

    protected func incSkippedUnreadable(topic: String, group: String): Unit {
        bump(topic, group, "skippedUnreadable")
    }

    protected func incSkippedNoMatch(topic: String, group: String): Unit {
        bump(topic, group, "skippedNoMatch")
    }

    protected func incSkippedUnsupported(topic: String, group: String): Unit {
        bump(topic, group, "skippedUnsupported")
    }

    protected func skippedUnreadableOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "skippedUnreadable")
    }

    protected func skippedNoMatchOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "skippedNoMatch")
    }

    protected func skippedUnsupportedOf(topic: String, group: String): Int64 {
        valueOf(topic, group, "skippedUnsupported")
    }
}