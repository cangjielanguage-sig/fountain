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

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * 协议命令处理器。
 * 接收 f_net::Server 解码后的 Message，按 command 分发到具体处理器。
 */
public class CommandExecutor {
    private let log = LoggerFactory.getLogger('fountain::fmq.CommandExecutor')
    let topicManager: TopicManager
    let queueManager: QueueManager
    let deliveryManager: DeliveryManager
    let consumerMatcher: ConsumerMatcher
    let replicationManager: ReplicationManager

    public init(topicManager: TopicManager, queueManager: QueueManager,
                deliveryManager: DeliveryManager, consumerMatcher: ConsumerMatcher,
                replicationManager: ReplicationManager) {
        this.topicManager = topicManager
        this.queueManager = queueManager
        this.deliveryManager = deliveryManager
        this.consumerMatcher = consumerMatcher
        this.replicationManager = replicationManager
    }

    /**
     * 执行命令路由，返回响应 Message。
     * Phase 6 为骨架占位，各 handler 提供基本功能。
     */
    public func execute(request: ProtocolMessage): ProtocolMessage {
        match (request.command) {
            case PUBLISH(_) => handleProduce(request)
            case SUBSCRIBE => handleSubscribe(request)
            case UNSUBSCRIBE => handleUnsubscribe(request)
            case CONSUME(_) => handleConsume(request)
            case ACK => handleAck(request)
            case PING(_) => handlePing(request)
            case REGISTER => handleRegister(request)
            case DEREGISTER => handleDeregister(request)
            case SLAVEOF(_) => handleSlaveOf(request)
            case ELECT(_) => handleElection(request)
            case _ => errorResp(request.id, "unknown command")
        }
    }

    // ───── PUBLISH ─────

    /**
     * 处理生产消息。
     * 1. 从请求体解码 topic / labels / payload
     * 2. 校验 topic
     * 3. 路由到队列并写入 SegmentedLog
     * 4. 返回 RESP
     */
    private func handleProduce(request: ProtocolMessage): ProtocolMessage {
        // 1. 解码请求体
        if (let Some(body) <- convert<MqBody>(request.data)) {
            if (body.bodyType != "produce") {
                return errorResp(request.id, "unexpected body type: ${body.bodyType}")
            }
            if (let Some((topic, labels, msgData)) <- ProduceCodec.decode(body.payload)) {
                // 2. 校验 topic
                if (!validateTopic(topic)) {
                    return errorResp(request.id, "invalid topic: ${topic}")
                }

                // 3. 路由到队列
                let queues = queueManager.createQueues(topic, 1)
                if (queues.size == 0) {
                    return errorResp(request.id, "no queue available for topic=${topic}")
                }
                let queue = queues[0]

                // 4. 写入 SegmentedLog
                queue.append(msgData)
                queue.sync()

                log.debug{"produced to ${topic}, size=${msgData.size}"}
                ProtocolMessage(Command.RESP(0), request.id, MqBody("ack", []).toData())
            } else {
                errorResp(request.id, "failed to decode produce payload")
            }
        } else {
            errorResp(request.id, "failed to decode request body")
        }
    }

    // ───── SUBSCRIBE / UNSUBSCRIBE ─────

    private func handleSubscribe(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleSubscribe (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    private func handleUnsubscribe(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleUnsubscribe (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── CONSUME ─────

    private func handleConsume(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleConsume (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── ACK ─────

    private func handleAck(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleAck (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── PING ─────

    private func handlePing(request: ProtocolMessage): ProtocolMessage {
        ProtocolMessage(Command.PING(1), request.id, MqBody("pong", []).toData())
    }

    // ───── REGISTER / DEREGISTER ─────

    private func handleRegister(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleRegister (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    private func handleDeregister(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleDeregister (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── SLAVEOF ─────

    private func handleSlaveOf(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleSlaveOf (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── ELECTION ─────

    private func handleElection(request: ProtocolMessage): ProtocolMessage {
        log.debug{"handleElection (placeholder)"}
        ProtocolMessage(Command.RESP(0), request.id, DataNone.INSTANCE)
    }

    // ───── 工具方法 ─────

    private func errorResp(id: MessageID, msg: String): ProtocolMessage {
        log.warn{"command error: ${msg}"}
        ProtocolMessage(Command.RESP(0), id, DataNone.INSTANCE)
    }
}
