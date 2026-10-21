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

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import fountain::f_mq.base.MQErrorCode
import fountain::f_mq.base.payload.MQResult
import fountain::f_net.SocketBuffer

/**
 * 订阅表：`subscribedId → 订阅`，外加 `(topic, group) → [subscribedId]` 索引。
 *
 * 单把 `Mutex` 保护两个索引；读多写少，热点在 `GroupCursor` 内部（每组独立锁）。
 */
protected class SubscriberRegistry {
    private let lock = Mutex()
    private let byId = HashMap<String, MQSubscriptionInfo>()
    private let byGroup = HashMap<String, ArrayList<String>>()
    /** 每个 `subscribedId` 最近一次登记的代次（订阅注销后仍保留，避免代次回退）。 */
    private let generations = HashMap<String, Int64>()

    private static func groupKey(topic: String, group: String): String {
        "${topic}\u{0}${group}"
    }

    /** 登记订阅（幂等：同 id 重复登记只更新连接与参数）。 */
    func register(info: MQSubscriptionInfo): MQResult {
        synchronized(lock) {
            let key = groupKey(info.topic, info.subscribeGroup)
            match (byId.get(info.subscribedId)) {
                case Some(old) =>
                    // 从旧组索引中移除（参数可能变化）
                    removeFromGroup(old.topic, old.subscribeGroup, old.subscribedId)
                case None => ()
            }
            let next = match (generations.get(info.subscribedId)) {
                case Some(value) => value + 1
                case None => 1
            }
            generations.add(info.subscribedId, next)
            info.generation = next
            byId.add(info.subscribedId, info)
            match (byGroup.get(key)) {
                case Some(ids) =>
                    if (!ids.contains(info.subscribedId)) {
                        ids.add(info.subscribedId)
                    }
                case None =>
                    let ids = ArrayList<String>()
                    ids.add(info.subscribedId)
                    byGroup.add(key, ids)
            }
            MQResult(0, "ok")
        }
    }

    /**
     * 注销订阅。
     *
     * `generation` 给定时只删「同一代」：断链巡检拿到的是旧快照，
     * 若期间客户端用同一 `subscribedId` 重订阅，不能把新订阅删掉（A60）。
     */
    func unregister(subscribedId: String, generation!: Int64 = -1): MQResult {
        synchronized(lock) {
            match (byId.get(subscribedId)) {
                case Some(current) =>
                    if (generation >= 0 && current.generation != generation) {
                        return MQResult(MQErrorCode.SUBSCRIBE_NOT_EXIST,
                            MQErrorCode.messageOf(MQErrorCode.SUBSCRIBE_NOT_EXIST))
                    }
                    byId.remove(subscribedId)
                    removeFromGroup(current.topic, current.subscribeGroup, subscribedId)
                    MQResult(0, "ok")
                case None => MQResult(MQErrorCode.SUBSCRIBE_NOT_EXIST, MQErrorCode.messageOf(MQErrorCode.SUBSCRIBE_NOT_EXIST))
            }
        }
    }

    func of(subscribedId: String): ?MQSubscriptionInfo {
        synchronized(lock) {
            byId.get(subscribedId)
        }
    }

    func byGroupOf(topic: String, group: String): Array<MQSubscriptionInfo> {
        synchronized(lock) {
            let result = ArrayList<MQSubscriptionInfo>()
            match (byGroup.get(groupKey(topic, group))) {
                case Some(ids) =>
                    for (id in ids) {
                        if (let Some(info) <- byId.get(id)) {
                            result.add(info)
                        }
                    }
                case None => ()
            }
            result.toArray()
        }
    }

    /** 主题下全部订阅的只读快照（发布前 filter 可评估性检查）。 */
    func byTopicOf(topic: String): Array<MQSubscriptionInfo> {
        synchronized(lock) {
            let result = ArrayList<MQSubscriptionInfo>()
            for ((_, info) in byId) {
                if (info.topic == topic) {
                    result.add(info)
                }
            }
            result.toArray()
        }
    }

    /** 关闭时清空全部订阅：同一进程内重启服务端不残留旧订阅。 */
    func clear(): Unit {
        synchronized(lock) {
            byId.clear()
            byGroup.clear()
        }
    }

    /** 连接断开时清理其名下全部订阅。 */
    func removeByBuffer(buffer: SocketBuffer): Unit {
        synchronized(lock) {
            let victims = ArrayList<String>()
            for ((id, info) in byId) {
                if (info.hasBuffer(buffer)) {
                    victims.add(id)
                }
            }
            for (id in victims) {
                match (byId.remove(id)) {
                    case Some(info) => removeFromGroup(info.topic, info.subscribeGroup, id)
                    case None => ()
                }
            }
        }
    }

    /** 主题被删除时清理相关订阅。 */
    func removeByTopic(topic: String): Unit {
        synchronized(lock) {
            let victims = ArrayList<String>()
            for ((id, info) in byId) {
                if (info.topic == topic) {
                    victims.add(id)
                }
            }
            for (id in victims) {
                match (byId.remove(id)) {
                    case Some(info) => removeFromGroup(info.topic, info.subscribeGroup, id)
                    case None => ()
                }
            }
        }
    }

    /** 订阅组被删除时清理该组订阅。 */
    func removeByGroup(topic: String, group: String): Unit {
        synchronized(lock) {
            match (byGroup.remove(groupKey(topic, group))) {
                case Some(ids) =>
                    for (id in ids) {
                        byId.remove(id)
                    }
                case None => ()
            }
        }
    }

    /** 组内活跃订阅的 id 列表（游标 sweep 用）。 */
    func activeIds(topic: String, group: String): Array<String> {
        synchronized(lock) {
            let result = ArrayList<String>()
            match (byGroup.get(groupKey(topic, group))) {
                case Some(ids) =>
                    for (id in ids) {
                        match (byId.get(id)) {
                            case Some(info) =>
                                // 断链订阅不是「活跃」：否则它的记录永远不会退回组内（A55）
                                if (!info.isDisconnected()) {
                                    result.add(id)
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
            result.toArray()
        }
    }

    /** 全部订阅的只读快照（断链巡检用）。 */
    protected func infos(): Array<MQSubscriptionInfo> {
        synchronized(lock) {
            let result = ArrayList<MQSubscriptionInfo>()
            for ((_, info) in byId) {
                result.add(info)
            }
            result.toArray()
        }
    }

    func count(): Int64 {
        synchronized(lock) {
            byId.size
        }
    }

    private func removeFromGroup(topic: String, group: String, subscribedId: String): Unit {
        match (byGroup.get(groupKey(topic, group))) {
            case Some(ids) =>
                match (indexOf(ids, subscribedId)) {
                    case Some(index) => ids.remove(at: index)
                    case None => ()
                }
            case None => ()
        }
    }

    private func indexOf(ids: ArrayList<String>, value: String): ?Int64 {
        for (i in 0..ids.size) {
            if (ids[i] == value) {
                return Some(i)
            }
        }
        None<Int64>
    }
}
