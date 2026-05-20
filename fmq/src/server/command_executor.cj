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
import fountain::f_codec.default.DefaultCodec
import std.collection.HashMap
import std.io.{ByteBuffer, SeekPosition}

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
    private let consumerGroupManager: ConsumerGroupManager
    private let config: MqConfig

    public init(topicManager: TopicManager, queueManager: QueueManager,
                deliveryManager: DeliveryManager, consumerMatcher: ConsumerMatcher,
                replicationManager: ReplicationManager,
                config!: MqConfig = MqConfig.forTest()) {
        this.topicManager = topicManager
        this.queueManager = queueManager
        this.deliveryManager = deliveryManager
        this.consumerMatcher = consumerMatcher
        this.replicationManager = replicationManager
        this.config = config
        this.consumerGroupManager = ConsumerGroupManager(topicManager, consumerMatcher, deliveryManager)
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
            case DLQ_LIST => handleDlqList(request)
            case DLQ_REDELIVER => handleDlqRedeliver(request)
            case DLQ_REDELIVER_ALL => handleDlqRedeliverAll(request)
            case TOPIC_OP => handleTopicOp(request)
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
        if (let Some(body) <- convert<MqBody>(request.data)) {
            if (body.bodyType == "produce") {
                return handleSingleProduce(request, body)
            } else if (body.bodyType == "batch_produce") {
                return handleBatchProduce(request, body)
            } else if (body.bodyType == "sync") {
                return handleSyncProduce(request, body)
            } else {
                return errorResp(request.id, "unexpected body type: ${body.bodyType}")
            }
        } else {
            errorResp(request.id, "failed to decode request body")
        }
    }

    /**
     * 处理单条消息生产。
     */
    private func handleSingleProduce(request: ProtocolMessage, body: MqBody): ProtocolMessage {
        if (let Some((topic, labels, msgData)) <- ProduceCodec.decode(body.payload)) {
            if (!validateTopic(topic)) {
                return errorResp(request.id, "invalid topic: ${topic}")
            }
            // 检查消息大小和标签数
            if (msgData.size > config.maxMessageSize) {
                return errorResp(request.id, "message too large: ${msgData.size} > ${config.maxMessageSize}")
            }
            if (labels.size > config.maxLabelsPerMessage) {
                return errorResp(request.id, "too many labels: ${labels.size} > ${config.maxLabelsPerMessage}")
            }
            let queues = if (let Some(qs) <- queueManager.getQueues(topic)) { qs }
                else { queueManager.createQueues(topic, 1) }
            if (queues.size == 0) {
                return errorResp(request.id, "no queue available for topic=${topic}")
            }
            let q = queueManager.routeToQueue(topic, queues)
            // 通过 QueueWriter 提交消息（若 writer 已启动则走复制链，否则直接写）
            if (let Some(writer) <- queueManager.getWriterForQueue(q)) {
                writer.submit(msgData)
            } else {
                q.append(msgData)
                q.sync()
            }
            log.debug{"produced to ${topic}, size=${msgData.size}"}
            ProtocolMessage(Command.RESP(0), request.id, MqBody("ack", []).toData())
        } else {
            errorResp(request.id, "failed to decode produce payload")
        }
    }

    /**
     * 处理批量消息生产。
     * body payload 格式：count + (topic + labelsCount + label*N + data)*N
     */
    private func handleBatchProduce(request: ProtocolMessage, body: MqBody): ProtocolMessage {
        let buf = ByteBuffer(body.payload)
        let dec = DefaultCodec()
        if (let Some(count) <- dec.decode<Int64>(buf)) {
            var ok: Int64 = 0
            var fail: Int64 = 0
            var i: Int64 = 0
            while (i < count) {
                if (let Some(topic) <- dec.decode<String>(buf)
                    && let Some(lc) <- dec.decode<Int64>(buf)) {
                    let labels = ArrayList<String>()
                    for (_ in 0..lc) {
                        if (let Some(l) <- dec.decode<String>(buf)) { labels.add(l) }
                    }
                    if (let Some(data) <- dec.decode<Array<Byte>>(buf)) {
                        if (validateTopic(topic)) {
                            if (data.size > config.maxMessageSize) { fail += 1 }
                            else if (labels.size > config.maxLabelsPerMessage) { fail += 1 }
                            else {
                                let queues = if (let Some(qs) <- queueManager.getQueues(topic)) { qs }
                                    else { queueManager.createQueues(topic, 1) }
                                if (queues.size > 0) {
                                    let q = queueManager.routeToQueue(topic, queues)
                                    // 通过 QueueWriter 提交（优先走复制链），无 writer 时直接写
                                    if (let Some(writer) <- queueManager.getWriterForQueue(q)) {
                                        writer.submit(data)
                                    } else {
                                        q.append(data)
                                        q.sync()
                                    }
                                    ok += 1
                                } else { fail += 1 }
                            }
                        } else { fail += 1 }
                    } else {
                        // 数据解码失败：buffer 位已偏移，终止批量处理
                        fail += (count - i)
                        break
                    }
                } else {
                    // 字段解码失败：buffer 位已偏移，终止批量处理
                    fail += (count - i)
                    break
                }
                i += 1
            }
            // Cangjie lambda 不能捕获可变变量（var），
            // 将 var 值复制到 let 变量供闭包使用。
            let okCount = ok
            let failCount = fail
            log.info{"batch produced: ${okCount} ok, ${failCount} fail"}
            ProtocolMessage(Command.RESP(0), request.id,
                MqBody("batch_ack", encodeBatchResult(ok, fail)).toData())
        } else {
            errorResp(request.id, "failed to decode batch produce body")
        }
    }

    // ───── SYNC (主从复制) ─────

    /**
     * 处理从主节点同步的 PUBLISH bodyType="sync" 命令。
     * Payload 格式为 DefaultCodec 编码的 (topic, queueIndex, rawProduceData)。
     * 直接追加到对应队列的 SegmentedLog，不经过常规生产流程。
     */
    private func handleSyncProduce(request: ProtocolMessage, body: MqBody): ProtocolMessage {
        try {
            let dec = DefaultCodec()
            let stream = ByteBuffer(body.payload)
            if (let Some(topic) <- dec.decode<String>(stream)
                && let Some(queueIndex) <- dec.decode<Int64>(stream)
                && let Some(data) <- dec.decode<Array<Byte>>(stream)) {
                if (let Some(queue) <- queueManager.getQueue(topic, queueIndex)) {
                    if (!queue.isClosed()) {
                        queue.append(data)
                        queue.sync()
                        return ProtocolMessage(Command.RESP(0), request.id,
                            MqBody("sync_ack", []).toData())
                    } else {
                        log.warn{"handleSync: queue ${topic}[${queueIndex}] is closed"}
                        return errorResp(request.id, "queue closed")
                    }
                } else {
                    log.warn{"handleSync: queue ${topic}[${queueIndex}] not found"}
                    return errorResp(request.id, "queue not found")
                }
            } else {
                log.warn{"handleSync: failed to decode sync payload"}
                return errorResp(request.id, "decode failed")
            }
        } catch (e: Exception) {
            log.warn{"handleSync error: ${e.message}"}
            errorResp(request.id, "sync error")
        }
    }

    // ───── SUBSCRIBE / UNSUBSCRIBE ─────

    /**
     * 处理订阅。
     */
    private func handleSubscribe(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let decoded = decodeTopicAndMode(body.payload)
            if (let Some((topic, mode)) <- decoded) {
                if (!validateTopic(topic)) {
                    return errorResp(request.id, "invalid topic: ${topic}")
                }
                // 注册消费者：用 topic + pid 组合作为唯一 consumerId，支持同组多消费者
                let consumerId = "sub@${request.id.pid}:${topic}"
                let reg = ConsumerRegistration(
                    consumerId: consumerId, groupId: topic,
                    matchModeStr: modeToEncodedString(mode),
                    labels: None, dataFilter: None,
                    lastHeartbeat: DateTime.now())
                consumerMatcher.register(reg)
                log.info{"subscribe ${topic}"}
                ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
            } else {
                errorResp(request.id, "failed to decode topic/mode")
            }
        } else {
            errorResp(request.id, "no body in subscribe request")
        }
    }

    private func handleUnsubscribe(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let decoded = decodeTopicAndMode(body.payload)
            if (let Some((topic, _)) <- decoded) {
                // 注销时使用与 SUBSCRIBE 一致的 consumerId = "sub@${pid}:${topic}"
                let consumerId = "sub@${request.id.pid}:${topic}"
                consumerMatcher.deregister(topic, consumerId)
                log.info{"unsubscribed ${topic}"}
                ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
            } else {
                errorResp(request.id, "failed to decode topic")
            }
        } else {
            errorResp(request.id, "no body in unsubscribe request")
        }
    }

    // ───── CONSUME ─────

    /**
     * 处理拉取消息。
     * 请求体：topic + groupId + batchSize（DefaultCodec 编码）。
     */
    private func handleConsume(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (body.bodyType == "batch_consume") {
                return handleBatchConsume(buf, dec, request)
            }
            // 单 topic CONSUME (兼容旧客户端)
            if (let Some(topic) <- dec.decode<String>(buf)
                && let Some(groupId) <- dec.decode<String>(buf)
                && let Some(batchSize) <- dec.decode<Int64>(buf)) {
                if (let Some(queues) <- queueManager.getQueues(topic)) {
                    var consumed = ArrayList<(String, ArrayList<String>, Array<Byte>)>()  // (deliveryId, labels, data)
                    for (q in queues) {
                        let offset = deliveryManager.getOffset(topic, q.index, groupId)
                        if (consumed.size < batchSize) {
                            if (let Some(framed) <- q.tryReadFromLog(offset)) {
                                // 解码 framed entry，提取 labels 和 payload
                                let (labels, payload) = if (let Some((_, ls, p)) <- ProduceCodec.decode(framed)) {
                                    (ls, p)
                                } else {
                                    (ArrayList<String>(), framed)
                                }
                                let deliveryId = "${topic}:${q.index}:${groupId}:${offset}"
                                deliveryManager.recordDelivery(deliveryId, groupId, groupId, topic)
                                consumed.add((deliveryId, labels, payload))
                            }
                        } else {
                            break
                        }
                    }
                    let consumedCount = consumed.size
                    log.info{"consumed ${consumedCount} msgs from ${topic}"}
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("consume", encodeMessageListWithIds(consumed)).toData())
                } else {
                    errorResp(request.id, "no queues for topic=${topic}")
                }
            } else {
                errorResp(request.id, "failed to decode consume request")
            }
        } else {
            errorResp(request.id, "no body in consume request")
        }
    }

    /**
     * 批量 CONSUME: 单次请求拉取多个 topic 的消息。
     * 请求格式: topicCount(Int64) × [topic(String) + groupId(String) + batchSize(Int64)]
     * 响应格式: topicCount(Int64) × [topic + groupId + msgCount × [deliveryId + labelCount + labels + data]]
     */
    private func handleBatchConsume(buf: ByteBuffer, dec: DefaultCodec, request: ProtocolMessage): ProtocolMessage {
        let allResults = HashMap<String, (String, ArrayList<(String, ArrayList<String>, Array<Byte>)>)>()  // topic → (groupId, msgs)
        if (let Some(topicCount) <- dec.decode<Int64>(buf)) {
            for (ti in 0..topicCount) {
                if (let Some(topic) <- dec.decode<String>(buf)
                    && let Some(groupId) <- dec.decode<String>(buf)
                    && let Some(batchSize) <- dec.decode<Int64>(buf)) {
                    var consumed = ArrayList<(String, ArrayList<String>, Array<Byte>)>()
                    if (let Some(queues) <- queueManager.getQueues(topic)) {
                        for (q in queues) {
                            let offset = deliveryManager.getOffset(topic, q.index, groupId)
                            if (consumed.size < batchSize) {
                                if (let Some(framed) <- q.tryReadFromLog(offset)) {
                                    let (labels, payload) = if (let Some((_, ls, p)) <- ProduceCodec.decode(framed)) {
                                        (ls, p)
                                    } else {
                                        (ArrayList<String>(), framed)
                                    }
                                    let deliveryId = "${topic}:${q.index}:${groupId}:${offset}"
                                    deliveryManager.recordDelivery(deliveryId, groupId, groupId, topic)
                                    consumed.add((deliveryId, labels, payload))
                                }
                            } else {
                                break
                            }
                        }
                    }
                    allResults[topic] = (groupId, consumed)
                } else {
                    log.warn{"handleBatchConsume: decode failure at topic index ${ti}"}
                }
            }
        }
        // 编码响应
        let respBuf = ByteBuffer()
        let enc = DefaultCodec().encode(allResults.size)
        for ((topic, (groupId, msgs)) in allResults) {
            enc.encode(topic).encode(groupId).encode(msgs.size)
            for ((id, labels, data) in msgs) {
                enc.encode(id).encode(labels.size)
                for (l in labels) { enc.encode(l) }
                enc.encode(data)
            }
        }
        enc.finish().copy(to: respBuf, closeFromOnEnd: true, closeToOnEnd: false)
        ProtocolMessage(Command.RESP(0), request.id,
            MqBody("batch_consume", extractBytes(respBuf)).toData())
    }

    // ───── ACK ─────

    /**
     * 处理消息确认。
     * 请求体：messageId + topic + queueIndex（DefaultCodec 编码）。
     */
    private func handleAck(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            if (body.bodyType == "ack") {
                singleAck(request, body)
            } else if (body.bodyType == "batch_ack") {
                batchAck(request, body)
            } else {
                errorResp(request.id, "unexpected ack body type: ${body.bodyType}")
            }
        } else {
            errorResp(request.id, "no body in ack request")
        }
    }

    /**
     * 单条 ACK。
     */
    private func singleAck(request: ProtocolMessage, body: MqBody): ProtocolMessage {
        let buf = ByteBuffer(body.payload)
        let dec = DefaultCodec()
        if (let Some(msgId) <- dec.decode<String>(buf)
            && let Some(topic) <- dec.decode<String>(buf)
            && let Some(queueIdx) <- dec.decode<Int64>(buf)) {
            if (deliveryManager.onAck(msgId, topic, queueIdx)) {
                ProtocolMessage(Command.RESP(0), request.id, MqBody("ack", []).toData())
            } else {
                errorResp(request.id, "duplicate ack or unknown msg: ${msgId}")
            }
        } else {
            errorResp(request.id, "failed to decode ack request")
        }
    }

    /**
     * 批量 ACK。
     * body payload 格式：count + (msgId + topic + queueIndex)*N
     */
    private func batchAck(request: ProtocolMessage, body: MqBody): ProtocolMessage {
        let buf = ByteBuffer(body.payload)
        let dec = DefaultCodec()
        if (let Some(count) <- dec.decode<Int64>(buf)) {
            var ok: Int64 = 0
            var fail: Int64 = 0
            for (_ in 0..count) {
                if (let Some(msgId) <- dec.decode<String>(buf)
                    && let Some(topic) <- dec.decode<String>(buf)
                    && let Some(queueIdx) <- dec.decode<Int64>(buf)) {
                    if (deliveryManager.onAck(msgId, topic, queueIdx)) {
                        ok += 1
                    } else { fail += 1 }
                } else { fail += 1 }
            }
            // Cangjie lambda 不能捕获可变变量（var），
            // 将 var 值复制到 let 变量供闭包使用。
            let okCount = ok
            let failCount = fail
            log.info{"batch ack: ${okCount} ok, ${failCount} fail"}
            ProtocolMessage(Command.RESP(0), request.id,
                MqBody("batch_ack", encodeBatchResult(ok, fail)).toData())
        } else {
            errorResp(request.id, "failed to decode batch ack body")
        }
    }

    // ───── PING ─────

    private func handlePing(request: ProtocolMessage): ProtocolMessage {
        ProtocolMessage(Command.PING(1), request.id, MqBody("pong", []).toData())
    }

    // ───── REGISTER / DEREGISTER ─────

    /**
     * 处理消费者注册。
     */
    private func handleRegister(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(groupId) <- dec.decode<String>(buf)
                && let Some(consumerId) <- dec.decode<String>(buf)
                && let Some(matchModeStr) <- dec.decode<String>(buf)) {
                let reg = ConsumerRegistration(
                    consumerId: consumerId, groupId: groupId,
                    matchModeStr: matchModeStr,
                    labels: None, dataFilter: None,
                    lastHeartbeat: DateTime.now())
                consumerMatcher.register(reg)
                log.info{"registered group=${groupId} consumer=${consumerId} mode=${matchModeStr}"}
                ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
            } else {
                errorResp(request.id, "failed to decode register payload (need groupId + consumerId + matchModeStr)")
            }
        } else {
            errorResp(request.id, "no body in register request")
        }
    }

    private func handleDeregister(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(groupId) <- dec.decode<String>(buf)
                && let Some(consumerId) <- dec.decode<String>(buf)) {
                if (consumerMatcher.deregister(groupId, consumerId)) {
                    log.info{"deregistered group=${groupId} consumer=${consumerId}"}
                    ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
                } else {
                    errorResp(request.id, "deregister failed: group=${groupId} consumer=${consumerId} not found")
                }
            } else {
                errorResp(request.id, "failed to decode deregister payload (need groupId + consumerId)")
            }
        } else {
            errorResp(request.id, "no body in deregister request")
        }
    }

    // ───── 死信队列 ─────

    /**
     * 列出死信。
     * 请求体：topic + queueIndex（DefaultCodec 编码）。
     * 响应：消息体列表编码为 MqBody("dlq_list", encodeMessageList)。
     */
    private func handleDlqList(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(topic) <- dec.decode<String>(buf)
                && let Some(queueIdx) <- dec.decode<Int64>(buf)) {
                if (let Some(q) <- queueManager.getQueue(topic, queueIdx)) {
                    let entries = q.deadLetter.list(topic, queueIdx)
                    // 编码返回 (messageId, data) 列表
                    let result = encodeDeadLetterList(entries)
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("dlq_list", result).toData())
                } else {
                    errorResp(request.id, "no queue ${topic}[${queueIdx}]")
                }
            } else {
                errorResp(request.id, "failed to decode dlq list request")
            }
        } else {
            errorResp(request.id, "no body in dlq list request")
        }
    }

    /**
     * 重投单条死信。
     * 请求体：topic + queueIndex + messageId（DefaultCodec 编码）。
     */
    private func handleDlqRedeliver(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(topic) <- dec.decode<String>(buf)
                && let Some(queueIdx) <- dec.decode<Int64>(buf)
                && let Some(msgId) <- dec.decode<String>(buf)) {
                if (let Some(q) <- queueManager.getQueue(topic, queueIdx)) {
                    if (let Some(data) <- q.deadLetter.redeliver(topic, queueIdx, msgId)) {
                        log.info{"redelivered DLQ ${msgId}"}
                        ProtocolMessage(Command.RESP(0), request.id,
                            MqBody("dlq_ok", data).toData())
                    } else {
                        errorResp(request.id, "DLQ entry not found: ${msgId}")
                    }
                } else {
                    errorResp(request.id, "no queue ${topic}[${queueIdx}]")
                }
            } else {
                errorResp(request.id, "failed to decode dlq redeliver request")
            }
        } else {
            errorResp(request.id, "no body in dlq redeliver request")
        }
    }

    /**
     * 重投所有死信。
     * 请求体：topic + queueIndex（DefaultCodec 编码）。
     */
    private func handleDlqRedeliverAll(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(topic) <- dec.decode<String>(buf)
                && let Some(queueIdx) <- dec.decode<Int64>(buf)) {
                if (let Some(q) <- queueManager.getQueue(topic, queueIdx)) {
                    q.deadLetter.redeliverAll(topic, queueIdx)
                    log.info{"redelivered all DLQ from ${topic}[${queueIdx}]"}
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("dlq_ok", []).toData())
                } else {
                    errorResp(request.id, "no queue ${topic}[${queueIdx}]")
                }
            } else {
                errorResp(request.id, "failed to decode dlq redeliver all request")
            }
        } else {
            errorResp(request.id, "no body in dlq redeliver all request")
        }
    }

    // ───── 主题管理 ─────

    /**
     * 处理主题操作（create / delete / list）。
     * 请求体：operation + name + queueCount（DefaultCodec 编码）。
     */
    private func handleTopicOp(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let buf = ByteBuffer(body.payload)
            let dec = DefaultCodec()
            if (let Some(op) <- dec.decode<String>(buf)
                && let Some(name) <- dec.decode<String>(buf)) {
                if (op == "create") {
                    let qc = if (let Some(q) <- dec.decode<Int64>(buf)) { q } else { 1 }
                    if (!validateTopic(name)) {
                        return errorResp(request.id, "invalid topic: '${name}'")
                    }
                    let code = topicManager.createTopic(name, queueCount: qc)
                    if (code == MqErrorCode.SUCCESS) {
                        queueManager.createQueues(name, qc)
                        queueManager.startWritersForTopic(name)
                        ProtocolMessage(Command.RESP(0), request.id,
                            MqBody("ok", []).toData())
                    } else {
                        errorResp(request.id, "create topic failed: ${code}")
                    }
                } else if (op == "delete") {
                    let code = topicManager.deleteTopic(name)
                    if (code == MqErrorCode.SUCCESS) {
                        queueManager.destroyQueues(name)
                        ProtocolMessage(Command.RESP(0), request.id,
                            MqBody("ok", []).toData())
                    } else {
                        errorResp(request.id, "delete topic failed: ${code}")
                    }
                } else if (op == "list") {
                    let topics = topicManager.listTopics()
                    let encoded = encodeTopicNameList(topics)
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("topic_list", encoded).toData())
                } else if (op == "addGroup") {
                    let group = if (let Some(g) <- dec.decode<String>(buf)) { g } else {
                        return errorResp(request.id, "missing group name")
                    }
                    let code = consumerGroupManager.createGroup(name, group)
                    if (code == MqErrorCode.SUCCESS) {
                        ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
                    } else {
                        errorResp(request.id, "add group failed: ${code}")
                    }
                } else if (op == "removeGroup") {
                    let group = if (let Some(g) <- dec.decode<String>(buf)) { g } else {
                        return errorResp(request.id, "missing group name")
                    }
                    let code = consumerGroupManager.deleteGroup(name, group)
                    if (code == MqErrorCode.SUCCESS) {
                        ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
                    } else {
                        errorResp(request.id, "remove group failed: ${code}")
                    }
                } else if (op == "showTopic") {
                    if (let Some(meta) <- topicManager.getTopicMeta(name)) {
                        let info = encodeTopicInfo(name, meta)
                        ProtocolMessage(Command.RESP(0), request.id,
                            MqBody("topic_info", info).toData())
                    } else {
                        errorResp(request.id, "topic not found: ${name}")
                    }
                } else if (op == "resetOffset") {
                    let group = if (let Some(g) <- dec.decode<String>(buf)) { g } else {
                        return errorResp(request.id, "missing group name")
                    }
                    let offsetVal = if (let Some(o) <- dec.decode<Int64>(buf)) { o } else {
                        return errorResp(request.id, "missing offset value")
                    }
                    var queueIdx: Int64 = 0
                    if (let Some(qi) <- dec.decode<Int64>(buf)) { queueIdx = qi }
                    deliveryManager.setOffset(name, queueIdx, group, offsetVal)
                    ProtocolMessage(Command.RESP(0), request.id, MqBody("ok", []).toData())
                } else if (op == "listGroups") {
                    let groups = topicManager.getConsumerGroups(name)
                    let encoded = encodeTopicNameList(groups)
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("group_list", encoded).toData())
                } else if (op == "listConsumers") {
                    let regs = consumerMatcher.getRegistrations()
                    let encoded = encodeConsumerList(regs, name)
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("consumer_list", encoded).toData())
                } else if (op == "listAllGroups") {
                    let allGroups = topicManager.listAllConsumerGroups()
                    let encoded = encodeGroupListByTopic(allGroups)
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("all_group_list", encoded).toData())
                } else {
                    errorResp(request.id, "unknown topic op: ${op}")
                }
            } else {
                errorResp(request.id, "failed to decode topic op request")
            }
        } else {
            errorResp(request.id, "no body in topic op request")
        }
    }

    // ───── SLAVEOF ─────

    /**
     * 处理 SLAVEOF 命令。
     * 从 MqBody.payload 解码 nodeId，注册到 ReplicationManager。
     */
    private func handleSlaveOf(request: ProtocolMessage): ProtocolMessage {
        if (let Some(body) <- convert<MqBody>(request.data)) {
            let decoded = decodeNodeId(body.payload)
            if (let Some(nodeId) <- decoded) {
                if (replicationManager.onSlaveOf(nodeId)) {
                    log.info{"slave ${nodeId} connected"}
                    ProtocolMessage(Command.RESP(0), request.id,
                        MqBody("ok", []).toData())
                } else {
                    errorResp(request.id, "SLAVEOF rejected (not master)")
                }
            } else {
                errorResp(request.id, "failed to decode SLAVEOF nodeId")
            }
        } else {
            errorResp(request.id, "no body in SLAVEOF request")
        }
    }

    // ───── ELECTION ─────

    /**
     * 处理选举命令。
     * VOTE→ACK/APPROVE→升 Master/ASSUME→确认。
     */
    private func handleElection(request: ProtocolMessage): ProtocolMessage {
        let b = request.command.value
        let vote = b & VOTE
        let approve = b & APPROVE
        if (vote != 0u8) {
            // 请求投票 → ACK
            ProtocolMessage(Command.ELECT(APPROVE), request.id,
                MqBody("elect_ack", []).toData())
        } else if (approve != 0u8) {
            // 收到批准 → 升 Master
            replicationManager.promoteToMaster()
            ProtocolMessage(Command.ELECT(ASSUME), request.id,
                MqBody("ok", []).toData())
        } else {
            // ASSUME 确认
            ProtocolMessage(Command.RESP(0), request.id,
                MqBody("ok", []).toData())
        }
    }

    // ───── 工具方法 ─────

    private func errorResp(id: MessageID, msg: String): ProtocolMessage {
        log.warn{"command error: ${msg}"}
        let encoded = DefaultCodec().encode(msg).finish()
        let buf = ByteBuffer()
        encoded.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        ProtocolMessage(Command.RESP(0), id,
            MqBody("error", raw).toData())
    }

    /**
     * 从 payload 解码 topic 和 MatchMode。
     * 格式：topic + matchMode (DefaultCodec 编码)。
     */
    private static func decodeTopicAndMode(payload: Array<Byte>): ?(String, MatchMode) {
        try {
            let buf = ByteBuffer(payload)
            let dec = DefaultCodec()
            if (let Some(topic) <- dec.decode<String>(buf)
                && let Some(modeStr) <- dec.decode<String>(buf)) {
                let mode = if (modeStr == "exact") {
                    MatchMode.Exact(topic)
                } else if (modeStr == "glob") {
                    MatchMode.Glob(topic)
                } else if (modeStr == "prefix") {
                    MatchMode.Prefix(topic)
                } else {
                    return None
                }
                Some((topic, mode))
            } else { None }
        } catch (_: Exception) { None }
    }

    /**
     * 编码消息列表为 Array<Byte>。
     * 格式：count + msg1 + msg2 + ...（DefaultCodec 编码）。
     */
    private static func encodeMessageList(msgs: ArrayList<Array<Byte>>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(msgs.size)
        for (m in msgs) {
            enc.encode(m)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /**
     * 编码带 ID 和 labels 的消息列表。格式：count + (deliveryId + labelCount + labels*N + data)*N
     */
    private static func encodeMessageListWithIds(msgs: ArrayList<(String, ArrayList<String>, Array<Byte>)>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(msgs.size)
        for ((id, labels, data) in msgs) {
            enc.encode(id).encode(labels.size)
            for (l in labels) { enc.encode(l) }
            enc.encode(data)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /**
     * 编码死信列表为 Array<Byte>。
     * 格式：count + (msgId + data)*N（DefaultCodec 顺序）。
     */
    private static func encodeDeadLetterList(entries: ArrayList<(String, Array<Byte>)>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(entries.size)
        for ((msgId, data) in entries) {
            enc.encode(msgId).encode(data)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeTopicNameList(names: ArrayList<String>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(names.size)
        for (n in names) {
            enc.encode(n)
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    /**
     * 编码消费者列表：size + per-entry (consumerId, groupId, matchModeStr, lastHeartbeatMs)
     */
    private static func encodeConsumerList(regs: ArrayList<ConsumerRegistration>, filterTopic: String): Array<Byte> {
        // 按 topic 过滤：匹配 topic 或 topic 在 matchMode 中
        let matched = ArrayList<ConsumerRegistration>()
        for (r in regs) {
            let mode = r.getMatchMode()
            if (matchesTopicForList(mode, filterTopic)) {
                matched.add(r)
            }
        }
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode(matched.size)
        for (r in matched) {
            enc.encode(r.getConsumerId())
                .encode(r.getGroupId())
                .encode(matchModeToString(r.getMatchMode()))
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func matchesTopicForList(mode: MatchMode, topic: String): Bool {
        if (topic.isEmpty()) { return true }  // 空 topic = 返回全部
        match (mode) {
            case Exact(pattern) => pattern == topic
            case Glob(pattern) =>
                let pp = PathPattern()
                pp.compile(pattern)
                pp.matches(topic)
            case Prefix(pattern) => topic.startsWith(pattern)
        }
    }

    private static func encodeGroupListByTopic(all: HashMap<String, ArrayList<String>>): Array<Byte> {
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode(all.size)
        for ((topic, groups) in all) {
            enc.encode(topic).encode(groups.size)
            for (g in groups) { enc.encode(g) }
        }
        enc.finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeTopicInfo(name: String, meta: TopicMeta): Array<Byte> {
        let groups = meta.getConsumerGroups()
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(name)
            .encode(meta.getQueueCount())
            .encode(groups.size)
        for (g in groups) {
            enc.encode(g)
        }
        enc.encode(meta.getCreateTime().toString())
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func encodeBatchResult(ok: Int64, fail: Int64): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(ok).encode(fail)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        extractBytes(buf)
    }

    private static func decodeNodeId(payload: Array<Byte>): ?String {
        try {
            let buf = ByteBuffer(payload)
            let dec = DefaultCodec()
            dec.decode<String>(buf)
        } catch (_: Exception) { None }
    }

    private static func modeToEncodedString(mode: MatchMode): String {
        match (mode) {
            case Exact(p) => "Exact:${p}"
            case Glob(p) => "Glob:${p}"
            case Prefix(p) => "Prefix:${p}"
        }
    }

}
