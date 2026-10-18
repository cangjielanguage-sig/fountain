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
 * 匹配结果三态。
 *
 * `Unsupported` 表示「无法判定」而不是「不匹配」：BODY 是未在本进程注册的对象类型，
 * 非空 filter 无法求值。调用方既不能投递，也不能把记录标记为已决（否则静默丢消息）。
 */
protected enum MQMatchResult <: Equatable<MQMatchResult> & ToString {
    | Match
    | NoMatch
    | Unsupported

    public operator func ==(other: MQMatchResult): Bool {
        match ((this, other)) {
            case (Match, Match) => true
            case (NoMatch, NoMatch) => true
            case (Unsupported, Unsupported) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Match => "Match"
            case NoMatch => "NoMatch"
            case Unsupported => "Unsupported"
        }
    }
}

/**
 * 服务端权威匹配：topic 完全相等 → tags 子集（顺序无关）→ filter 求值为真。
 *
 * 前一步失败即短路；BODY 只在 filter 非空时才解码。BODY 无法解码（对象类型未在本进程注册）
 * 时返回 `Unsupported`，由调用方决定「不投递且不越过」。
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

    protected static func matches(subscription: MQSubscriptionView, record: Array<Byte>): MQMatchResult {
        match (MQMessageRecord.topic(record)) {
            case None => return NoMatch
            case Some(topic) =>
                if (topic != subscription.topic) {
                    return NoMatch
                }
        }
        let recordTags = match (MQMessageRecord.tags(record)) {
            case Some(tags) => tags
            case None => return NoMatch
        }
        if (!matchesTags(subscription.tags, recordTags)) {
            return NoMatch
        }
        if (subscription.filter.path.isEmpty()) {
            return Match
        }
        match (MQMessageRecord.body(record)) {
            case None => Unsupported
            case Some(body) =>
                if (subscription.filter.matches(body.data)) {
                    Match
                } else {
                    NoMatch
                }
        }
    }
}
