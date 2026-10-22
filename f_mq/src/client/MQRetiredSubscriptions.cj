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

import std.collection.{ArrayList, HashSet}
import std.sync.Mutex

/**
 * 已成功退订的订阅 id 记忆。
 *
 * 退订必须幂等（R5-4）：重复退订返回成功且不再发请求，而从未订阅过的 id 要报错。
 * 两者只能靠「记住退过的 id」区分，但无限增长会泄漏内存，因此按容量 FIFO 淘汰：
 * 被淘汰的 id 再退订会退化成「未知 id」——容量 4096 足以覆盖调用方的重试窗口。
 */
internal class MQRetiredSubscriptions {
    static const DEFAULT_CAPACITY: Int64 = 4096

    private let capacity: Int64
    private let order = ArrayList<String>()
    private let members = HashSet<String>()
    private let lock = Mutex()

    init(capacity!: Int64 = DEFAULT_CAPACITY) {
        this.capacity = if (capacity < 1) { 1 } else { capacity }
    }

    func add(subscribedId: String): Unit {
        synchronized(lock) {
            if (members.contains(subscribedId)) {
                // 重复加入不刷新 FIFO 位置，淘汰顺序才是稳定的
                return
            }
            while (order.size >= capacity) {
                let evicted = order.remove(at: 0)
                members.remove(evicted)
            }
            order.add(subscribedId)
            members.add(subscribedId)
        }
    }

    func contains(subscribedId: String): Bool {
        synchronized(lock) {
            members.contains(subscribedId)
        }
    }
}
