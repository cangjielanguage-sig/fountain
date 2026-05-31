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
import std.sync.{Mutex, AtomicBool}
import std.env.atExit

/**
 * MQ 服务端。
 * 封装 f_net::Server，管理连接生命周期。
 * T = DataAny 作为通用数据载荷类型。
 */
public class MqServer <: Resource {
    private let server: Server<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody>
    private let log = LoggerFactory.getLogger<MqServer>()
    private let startFailed = AtomicBool(false)  // 启动失败标志

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
     * 返回 Future<Unit>，调用方可通过 isStartFailed() 检查启动状态。
     */
    public func start(handler: (ProtocolMessage) -> ProtocolMessage): Future<Unit> {
        spawn {
            try {
                server.start(handler)
            } catch (e: Exception) {
                log.error{"MqServer start failed: ${e.message}"}
                startFailed.store(true)
            }
        }
    }

    /**
     * 检查服务端启动是否失败。
     */
    public func isStartFailed(): Bool { startFailed.load() }

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
        let server = MqServer(bindPort: port)
        let topicManager = TopicManager(config)
        let queueManager = QueueManager(config, nodeIndex: nodeIndex)
        let deliveryManager = DeliveryManager(config)
        let consumerMatcher = ConsumerMatcher()
        let replicationManager = ReplicationManager(config)

        // 从 fleet 恢复持久化状态
        topicManager.restore()
        deliveryManager.setTopicManager(topicManager)
        deliveryManager.restoreOffsets()
        deliveryManager.cleanupOrphanOffsets()  // P2-5: 清理已删除 topic 的孤儿 offset

        // 为主题创建队列
        for (name in topicManager.listTopics()) {
            let meta = topicManager.getTopicMeta(name)
            if (let Some(m) <- meta) {
                queueManager.createQueues(name, m.getQueueCount())
                queueManager.startWritersForTopic(name)
            }
        }
        let executor = CommandExecutor(
            topicManager, queueManager, deliveryManager,
            consumerMatcher, replicationManager, config: config)

        // 设置依赖注入
        queueManager.setReplicationManager(replicationManager)
        queueManager.startAll()
        queueManager.startAllSyncThreads()
        deliveryManager.setConsumerMatcher(consumerMatcher)
        deliveryManager.setQueueManager(queueManager)
        deliveryManager.startTimeoutChecker()

        server.start({ msg => executor.execute(msg) })
        // 启动消息过期清理线程
        let cleaner = QueueCleaner(config, queueManager)
        // P3-3: spawn 后立即设置 runFuture，避免窗口期 cleaner 线程已运行但 future 未设置
        let cleanerFuture = spawn { cleaner.run() }
        cleaner.setRunFuture(cleanerFuture)
        let brokerManager = BrokerManager(config)
        brokerManager.startHeartbeat()
        // 定期清理过期消费者注册（P3-1: 添加关闭检查）
        let consumerRefreshInterval = config.heartbeatIntervalSec
        let refreshClosed = AtomicBool(false)
        // P4-1: heartbeatIntervalSec=0 时跳过启动 refresh 线程，避免 sleep(0) 紧密循环
        var refreshFuture: ?Future<Unit> = None
        if (consumerRefreshInterval > 0) {
            refreshFuture = Some(spawn {
                while (!refreshClosed.load()) {
                    sleep(Duration.second * consumerRefreshInterval)
                    consumerMatcher.refresh()
                }
            })
        }

        // 保持主线程运行（等待关闭信号）
        let shutdownMutex = Mutex()
        let shutdownCond = synchronized(shutdownMutex) { shutdownMutex.condition() }
        let shuttingDown = AtomicBool(false)
        // 注册关闭信号处理器
        atExit {
            synchronized(shutdownMutex) {
                shuttingDown.store(true)
                refreshClosed.store(true)
                shutdownCond.notify()
            }
        }
        synchronized(shutdownMutex) {
            while (!shuttingDown.load()) {
                shutdownCond.wait(timeout: Duration.second * 60)
            }
        }
        cleaner.close()
        if (let Some(f) <- refreshFuture) {
            try { f.get() } catch (_: Exception) {}
        }
        brokerManager.close()
        deliveryManager.close()
        queueManager.close()
        server.close()
        0
    }

    /**
     * 从 mq_hosts 列表中解析本机端口。
     * 默认取第一个 host:port 的 port。
     */
    private static func resolvePort(hosts: ArrayList<String>): UInt16 {
        if (hosts.size > 0) {
            let parts = hosts[0].split(':')
            if (parts.size == 2) {
                try { return UInt16.parse(parts[1]) } catch (e: Exception) {
                    log.warn{"invalid port in mq_hosts '${hosts[0]}': ${e.message}, using default 7201"}
                }
            }
        }
        7201u16
    }

    /**
     * 从 mq_hosts 中查找本节点端口对应的索引。
     * 用于 QueueManager 分布算法中的 nodeIndex。
     */
    private static func resolveNodeIndex(hosts: ArrayList<String>, port: UInt16): Int64 {
        for (i in 0..hosts.size) {
            let parts = hosts[i].split(':')
            if (parts.size == 2) {
                try {
                    let p = UInt16.parse(parts[1])
                    if (p == port) {
                        return i
                    }
                } catch (e: Exception) {
                    log.warn{"resolveNodeIndex: invalid port in mq_hosts '${hosts[i]}': ${e.message}"}
                }
            }
        }
        0
    }
}
