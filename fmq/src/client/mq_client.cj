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

/**
 * MQ 客户端单例。
 * 连接 MQ 服务端，提供生产、订阅、消费 API。
 */
public class MqClient <: Resource {
    private static var instance: ?MqClient = None
    private let log = LoggerFactory.getLogger('fountain::fmq.MqClient')

    // MQ 服务端连接
    let mqConn: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    // 订阅/消费管理器
    let sender: Sender
    let subscriber: Subscriber
    let consumer: Consumer
    let syncRegistry: SyncRegistry

    private let config: MqConfig
    private var closed: Bool = false

    private init(config: MqConfig, mqConn: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>) {
        this.config = config
        this.mqConn = mqConn
        this.sender = Sender(mqConn)
        this.subscriber = Subscriber(config)
        this.consumer = Consumer(mqConn, subscriber)
        this.syncRegistry = SyncRegistry(config, mqConn)
    }

    /**
     * 获取单例实例。
     */
    public static func getInstance(config: MqConfig): MqClient {
        if (let Some(inst) <- instance) { return inst }

        let hostPort = if (config.mqHosts.size > 0) { config.mqHosts[0] } else { "" }
        let parts = hostPort.split(':')
        if (parts.size != 2) {
            throw MqException("invalid mq_hosts: ${config.mqHosts}")
        }

        let conn = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
            queueSize: 1024,
            socketCount: 1,
            host: parts[0],
            port: UInt16(Int64.parse(parts[1])),
            idGetter: { msg => msg.id },
            checkDuration: Duration.second * 30,
            checker: { buffer => true }
        ).noDelay(true).build()

        let inst = MqClient(config, conn)
        instance = inst
        inst
    }

    // ───── 生产 API ─────

    public func produce(topic: String, labels: ArrayList<String>, data: Array<Byte>): ProduceResult {
        sender.produce(topic, labels, data)
    }

    // ───── 订阅 API ─────

    public func subscribe(groupId: String, matchMode: MatchMode): Bool {
        subscriber.subscribe(groupId, matchMode, labels: ArrayList())
    }

    public func subscribe(groupId: String, matchMode: MatchMode, labels!: ArrayList<String> = ArrayList()): Bool {
        subscriber.subscribe(groupId, matchMode, labels: labels)
    }

    public func subscribe(groupId: String, matchMode: MatchMode, dataFilter!: String = ""): Bool {
        subscriber.subscribe(groupId, matchMode, dataFilter: dataFilter)
    }

    public func unsubscribe(groupId: String, matchMode: MatchMode): Bool {
        subscriber.unsubscribe(groupId, matchMode)
    }

    // ───── 消费 API ─────

    public func poll<T>(timeout: Duration): ?Message where T <: DataFields<T> {
        consumer.poll<T>(timeout)
    }

    public func ack(messageId: MessageID): Bool {
        consumer.ack(messageId)
    }

    // ───── 生命周期 ─────

    public func close(): Unit {
        if (closed) { return }
        closed = true
        mqConn.close()
    }

    public func isClosed(): Bool { closed }
}
