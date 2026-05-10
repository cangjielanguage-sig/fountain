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
package fountain::fmq.client

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}
import fountain::f_codec.default.DefaultCodec
import std.io.ByteBuffer

/**
 * 订阅管理器。
 * 向 MQ 服务端发送 REGISTER / SUBSCRIBE / UNSUBSCRIBE / DEREGISTER 命令。
 */
public class Subscriber {
    private let config: MqConfig
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let log = LoggerFactory.getLogger('fountain::fmq.Subscriber')
    private let subscriptions = ArrayList<(String, String, String)>()  // (groupId, topic, dataFilter)

    public init(config: MqConfig,
                client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>) {
        this.config = config
        this.client = client
    }

    /**
     * 注册消费者身份并订阅主题。
     * 1. 发送 REGISTER 命令注册 consumerId
     * 2. 发送 SUBSCRIBE 命令订阅 topic
     */
    public func subscribe(groupId: String, matchMode: MatchMode,
                          labels!: ArrayList<String> = ArrayList(),
                          dataFilter!: String = ""): Bool {
        // 1. 注册消费者身份
        let regBody = encodeRegistrationPayload(groupId, matchMode)
        let regReq = ProtocolMessage(Command.REGISTER, MessageID(),
            MqBody("register", regBody).toData())
        let regResp = client.transfer(regReq.id, regReq, Duration.second * 10)
        if (regResp.isNone()) {
            log.warn{"register failed for group=${groupId}"}
            return false
        }

        // 2. 订阅 topic
        let subBody = encodeTopicAndMode(extractTopic(matchMode), modeToString(matchMode))
        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", subBody).toData())
        let subResp = client.transfer(subReq.id, subReq, Duration.second * 10)
        let dataFilterVal = dataFilter
        if (subResp.isSome()) {
            subscriptions.add((groupId, extractTopic(matchMode), dataFilterVal))
            log.info{"subscribed group=${groupId} to ${modeToString(matchMode)}"}
            true
        } else {
            log.warn{"subscribe failed for group=${groupId}"}
            false
        }
    }

    /**
     * 取消订阅。
     */
    public func unsubscribe(groupId: String, matchMode: MatchMode): Bool {
        let topic = extractTopic(matchMode)
        let subBody = encodeTopicAndMode(topic, modeToString(matchMode))
        let req = ProtocolMessage(Command.UNSUBSCRIBE, MessageID(),
            MqBody("unsubscribe", subBody).toData())
        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (resp.isSome()) {
            // 从本地列表移除
            var i = 0
            while (i < subscriptions.size) {
                let (g, t, _) = subscriptions[i]
                if (g == groupId && t == topic) {
                    subscriptions.remove(at: i)
                } else {
                    i += 1
                }
            }
            log.info{"unsubscribed group=${groupId} from ${topic}"}
            true
        } else {
            log.warn{"unsubscribe failed for group=${groupId}"}
            false
        }
    }

    /**
     * 获取活跃订阅列表。
     */
    public func getSubscriptions(): ArrayList<(String, String, String)> {
        let copy = ArrayList<(String, String, String)>()
        for (s in subscriptions) {
            copy.add(s)
        }
        copy
    }

    /**
     * 注销消费者身份。
     * 发送 DEREGISTER 命令移除指定 groupId 下的 consumerId。
     * 与 REGISTER 配套使用，UNSUBSCRIBE 不能替代 DEREGISTER。
     */
    public func deregister(groupId: String, consumerId: String): Bool {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(groupId)
            .encode(consumerId)
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)

        let req = ProtocolMessage(Command.DEREGISTER, MessageID(),
            MqBody("deregister", raw).toData())
        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (resp.isSome()) {
            log.info{"deregistered group=${groupId} consumer=${consumerId}"}
            true
        } else {
            log.warn{"deregister failed for group=${groupId}"}
            false
        }
    }

    // ───── 编码工具 ─────

    private static func encodeRegistrationPayload(groupId: String, mode: MatchMode): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(groupId)
            .encode(groupId)  // consumerId = groupId
            .encode(modeToString(mode))
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        raw
    }

    private static func encodeTopicAndMode(topic: String, mode: String): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(topic)
            .encode(mode)
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        raw
    }

    private static func extractTopic(mode: MatchMode): String {
        match (mode) {
            case Exact(t) => t
            case Glob(t) => t
            case Prefix(t) => t
        }
    }

    private static func modeToString(mode: MatchMode): String {
        match (mode) {
            case Exact(_) => "exact"
            case Glob(_) => "glob"
            case Prefix(_) => "prefix"
        }
    }
}
