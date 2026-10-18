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
package fountain::fmq.queue

import fountain::f_data.DataAny
import fountain::f_mq.base.{MQFilter, MQMessageRecord}

/**
 * 订阅的最小视图：游标只依赖这些字段，不感知连接与节点。
 */
protected struct MQSubscriptionView {
    let subscribedId: String
    let topic: String
    let tags: Array<String>
    let filter: MQFilter
    let autoAck: Bool

    protected init(subscribedId: String, topic: String, tags: Array<String>, filter: MQFilter, autoAck: Bool) {
        this.subscribedId = subscribedId
        this.topic = topic
        this.tags = tags
        this.filter = filter
        this.autoAck = autoAck
    }
}

/**
 * 服务端权威匹配：topic 完全相等 → tags 子集（顺序无关）→ filter 求值为真。
 *
 * 前一步失败即短路；BODY 只在 filter 非空时才解码。BODY 无法解码（对象类型未在本进程注册）
 * 时视为不匹配，绝不误投。
 */
protected class MQMatcher {
    static func topicOf(record: Array<Byte>): ?String {
        MQMessageRecord.topic(record)
    }

    static func matchesTags(subscriptionTags: Array<String>, recordTags: Array<String>): Bool {
        if (subscriptionTags.size == 0) {
            return true
        }
        for (tag in subscriptionTags) {
            if (!recordTags.contains(tag)) {
                return false
            }
        }
        true
    }

    static func matches(subscription: MQSubscriptionView, record: Array<Byte>): Bool {
        match (MQMessageRecord.topic(record)) {
            case None => return false
            case Some(topic) =>
                if (topic != subscription.topic) {
                    return false
                }
        }
        let recordTags = match (MQMessageRecord.tags(record)) {
            case Some(tags) => tags
            case None => return false
        }
        if (!matchesTags(subscription.tags, recordTags)) {
            return false
        }
        if (subscription.filter.path.isEmpty()) {
            return true
        }
        match (MQMessageRecord.body(record)) {
            case None => false
            case Some(body) => subscription.filter.matches(body.data)
        }
    }
}
