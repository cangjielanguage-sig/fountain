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

// 使用别名避免与 fountain::fmq.common.Message 冲突
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * MQ 服务端。
 * 封装 f_net::Server，管理连接生命周期。
 * T = DataAny 作为通用数据载荷类型。
 */
public class MqServer <: Resource {
    private let server: Server<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody>

    public init(bindPort!: UInt16, queueSize!: Int64 = 1024,
                checkDuration!: Duration = Duration.second * 30,
                checker!: (SocketBuffer) -> Bool = { _ => true }) {
        this.server = Server<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody>(
            queueSize: queueSize, bindAt: bindPort,
            checkDuration: checkDuration, checker: checker
        )
    }

    /**
     * 启动服务端，使用 handler 处理请求。
     */
    public func start(handler: (ProtocolMessage) -> ProtocolMessage): Future<Unit> {
        spawn {
            try {
                server.start(handler)
            } catch (e: Exception) {
                println("MqServer start failed: ${e.message}")
            }
        }
    }

    public func close(): Unit {
        if (!server.isClosed()) { server.close() }
    }

    public func isClosed(): Bool { server.isClosed() }
}

/**
 * MqCommand：SubCommand 'mq' 入口。
 * `fboot mq` 启动 MQ 服务端。
 */
public class MqCommand <: SubCommand {
    private static let log = LoggerFactory.getLogger('fountain::fmq.MqCommand')

    static init() {
        SubCommandMediator.register(MqCommand())
    }

    private init() {}

    public prop command: String {
        get() { 'mq' }
    }

    public func exec(args: Array<String>): Int64 {
        let config = loadConfig()
        if (config.mqHosts.isEmpty()) {
            log.error{"mq_hosts not configured"}
            return 1
        }

        let port = resolvePort(config.mqHosts)
        let nodeIndex = resolveNodeIndex(config.mqHosts, port)
        log.info{"starting MQ server on port ${port}, nodeIndex=${nodeIndex}"}

        // 创建各管理器 + CommandExecutor
        let server = MqServer(bindPort: UInt16(port))
        let topicManager = TopicManager(config)
        let queueManager = QueueManager(config, nodeIndex: nodeIndex)
        let deliveryManager = DeliveryManager(config)
        let consumerMatcher = ConsumerMatcher()
        let replicationManager = ReplicationManager(config)

        // 从 fsync 恢复持久化状态
        topicManager.restore()
        deliveryManager.restoreOffsets()

        // 为主题创建队列
        for (name in topicManager.listTopics()) {
            let meta = topicManager.getTopicMeta(name)
            if (let Some(m) <- meta) {
                queueManager.createQueues(name, m.getQueueCount())
            }
        }
        let executor = CommandExecutor(
            topicManager, queueManager, deliveryManager,
            consumerMatcher, replicationManager)

        // 设置 QueueManager 的 ReplicationManager（用于同步）
        queueManager.setReplicationManager(replicationManager)
        queueManager.startAll()

        server.start({ msg => executor.execute(msg) })
        let brokerManager = BrokerManager(config)
        brokerManager.startHeartbeat()

        // 保持主线程运行
        while (true) {
            sleep(Duration.second * 60)
        }
        brokerManager.close()
        queueManager.close()
        server.close()
        0
    }

    /**
     * 从 mq_hosts 列表中解析本机端口。
     * 默认取第一个 host:port 的 port。
     */
    private static func resolvePort(hosts: ArrayList<String>): Int64 {
        if (hosts.size > 0) {
            let parts = hosts[0].split(':')
            if (parts.size == 2) {
                return Int64.parse(parts[1])
            }
        }
        7201
    }

    /**
     * 从 mq_hosts 中查找本节点端口对应的索引。
     * 用于 QueueManager 分布算法中的 nodeIndex。
     */
    private static func resolveNodeIndex(hosts: ArrayList<String>, port: Int64): Int64 {
        for (i in 0..hosts.size) {
            let parts = hosts[i].split(':')
            if (parts.size == 2) {
                let p = Int64.parse(parts[1])
                if (p == port) {
                    return i
                }
            }
        }
        0
    }
}
