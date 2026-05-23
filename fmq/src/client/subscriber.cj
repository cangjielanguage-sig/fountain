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
import std.sync.Mutex

/**
 * 订阅管理器。
 * 向 MQ 服务端发送 REGISTER / SUBSCRIBE / UNSUBSCRIBE / DEREGISTER 命令。
 */
public class Subscriber {
    private let config: MqConfig
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let log = LoggerFactory.getLogger('fountain::fmq.Subscriber')
    private let subscriptions = ArrayList<(String, String, String, String)>()  // (groupId, topic, dataFilter, matchModeStr)
    private let subLock = Mutex()  // 保护 subscriptions 并发读写

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

        // 2. 订阅 topic (topic + groupId + modeStr)
        let subBody = encodeSubscribePayload(matchModeTopic(matchMode), groupId, matchModeToString(matchMode))
        let subReq = ProtocolMessage(Command.SUBSCRIBE, MessageID(),
            MqBody("subscribe", subBody).toData())
        let subResp = client.transfer(subReq.id, subReq, Duration.second * 10)
        let dataFilterVal = dataFilter
        if (subResp.isSome()) {
            synchronized(subLock) {
                // 检查是否已存在相同 groupId+topic+dataFilter 的订阅，避免重复
                for ((g, t, _, m) in subscriptions) {
                    if (g == groupId && t == matchModeTopic(matchMode) && m == matchModeToString(matchMode)) {
                        log.info{"already subscribed group=${groupId} to ${matchModeTopic(matchMode)}, skipping duplicate"}
                        return true
                    }
                }
                subscriptions.add((groupId, matchModeTopic(matchMode), dataFilterVal, matchModeToString(matchMode)))
            }
            log.info{"subscribed group=${groupId} to ${matchModeToString(matchMode)}"}
            true
        } else {
            // SUBSCRIBE 失败：清理已成功的 REGISTER 避免遗留注册
            if (!deregister(groupId, groupId)) {
                // deregister 回滚也失败：警告，心跳超时会自动清理
                log.warn{"subscribe rollback failed: deregister(${groupId}) unsuccessful, registration may linger until heartbeat timeout"}
            }
            log.warn{"subscribe failed for group=${groupId}"}
            false
        }
    }

    /**
     * 取消订阅。
     */
    public func unsubscribe(groupId: String, matchMode: MatchMode): Bool {
        let topic = matchModeTopic(matchMode)
        let subBody = encodeSubscribePayload(topic, groupId, matchModeToString(matchMode))
        let req = ProtocolMessage(Command.UNSUBSCRIBE, MessageID(),
            MqBody("unsubscribe", subBody).toData())
        let resp = client.transfer(req.id, req, Duration.second * 10)
        if (resp.isSome()) {
            // 从本地列表移除（加锁与 poll/getSubscriptions 互斥）
            synchronized(subLock) {
                var i = 0
                while (i < subscriptions.size) {
                    let (g, t, _, m) = subscriptions[i]
                    if (g == groupId && t == topic && m == matchModeToString(matchMode)) {
                        subscriptions.remove(at: i)
                    } else {
                        i += 1
                    }
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
    public func getSubscriptions(): ArrayList<(String, String, String, String)> {
        synchronized(subLock) {
            let copy = ArrayList<(String, String, String, String)>()
            for (s in subscriptions) {
                copy.add(s)
            }
            copy
        }
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
            // 从本地订阅列表移除匹配条目
            synchronized(subLock) {
                var i = 0
                while (i < subscriptions.size) {
                    let (g, _, _, _) = subscriptions[i]
                    if (g == groupId) {
                        subscriptions.remove(at: i)
                    } else { i += 1 }
                }
            }
            log.info{"deregistered group=${groupId} consumer=${consumerId}"}
            true
        } else {
            log.warn{"deregister failed for group=${groupId}"}
            false
        }
    }

    // ───── 编码工具 ─────

    private static func encodeRegistrationPayload(groupId: String, mode: MatchMode): Array<Byte> {
        let modeStr = encodeMatchMode(mode)
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(groupId)
            .encode(groupId)  // consumerId = groupId
            .encode(modeStr)
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

    /**
     * 编码订阅 payload: topic + groupId + modeStr
     */
    private static func encodeSubscribePayload(topic: String, groupId: String, mode: String): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(topic)
            .encode(groupId)
            .encode(mode)
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        raw
    }
}
