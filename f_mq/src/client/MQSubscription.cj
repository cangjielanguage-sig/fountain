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

import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64
import fountain::f_mq.base.MQFilter

/**
 * 客户端侧订阅状态。
 *
 * `deliveries` 记录「队列 + 位置 → 投递该位置的节点下标」，`ack` 据此把确认发回正确节点；
 * 每个队列的段日志位置都会重复，键必须包含 `queueIndex` 才能避免串台。
 * `autoAck` 订阅不记录，显式 ack 走广播路径。
 */
internal class MQSubscription {
    let subscribedId: String
    let topic: String
    let subscribeGroup: String
    let tags: Array<String>
    let filter: MQFilter
    let autoAck: Bool
    let owners: Array<Int64>
    let deliveries = ConcurrentHashMap<String, Int64>()
    private let cursor = AtomicInt64(0)

    init(subscribedId: String, topic: String, subscribeGroup: String, tags: Array<String>, filter: MQFilter,
        autoAck: Bool, owners: Array<Int64>) {
        this.subscribedId = subscribedId
        this.topic = topic
        this.subscribeGroup = subscribeGroup
        this.tags = tags
        this.filter = filter
        this.autoAck = autoAck
        this.owners = owners
    }

    static func keyOf(queueIndex: Int64, segmentedIndex: Int64, segmentedOffset: Int64): String {
        "${queueIndex}:${segmentedIndex}:${segmentedOffset}"
    }

    /** 轮询游标：每轮从下一个 owner 开始，避免总是打同一个节点。 */
    func nextStart(): Int64 {
        cursor.fetchAdd(1) % owners.size
    }
}
