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
import std.collection.HashMap

/**
 * 节点健康信息。
 */
public class NodeHealth {
    let host: String
    let port: UInt16
    var lastSeen: DateTime
    var isAlive: Bool
    var failedCount: Int64

    public init(host: String, port: UInt16) {
        this.host = host
        this.port = port
        this.lastSeen = DateTime.now()
        this.isAlive = true
        this.failedCount = 0
    }
}

/**
 * Broker 节点管理器。
 * 管理 MQ 集群节点列表，通过 PING 做健康检查。
 */
public class BrokerManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.BrokerManager')
    private var closed: Bool = false
    private let nodes = HashMap<String, NodeHealth>()  // "host:port" → NodeHealth
    private var heartbeatThread: ?Future<Unit> = None

    public init(config: MqConfig) {
        this.config = config
        // 从 mqHosts 初始化节点列表
        for (hostPort in config.mqHosts) {
            let parts = hostPort.split(':')
            if (parts.size == 2) {
                let host = parts[0]
                let port = UInt16(Int64.parse(parts[1]))
                nodes[hostPort] = NodeHealth(host, port)
            }
        }
    }

    /**
     * 启动心跳线程。按 heartbeatIntervalSec 间隔 ping 所有节点。
     */
    public func startHeartbeat(): Unit {
        if (heartbeatThread.isSome()) { return }
        let selfRef = this
        heartbeatThread = spawn {
            while (!selfRef.closed) {
                for ((key, nh) in selfRef.nodes) {
                    selfRef.pingNode(nh)
                }
                sleep(Duration.second * selfRef.config.heartbeatIntervalSec)
            }
        }
        log.info{"BrokerManager heartbeat started (${nodes.size} nodes)"}
    }

    /**
     * 检查集群节点是否全部可达。
     */
    public func checkConsistency(): Bool {
        for ((_, nh) in nodes) {
            if (!nh.isAlive) { return false }
        }
        true
    }

    /**
     * 获取在线节点数。
     */
    public func aliveCount(): Int64 {
        var count: Int64 = 0
        for ((_, nh) in nodes) {
            if (nh.isAlive) { count += 1 }
        }
        count
    }

    /**
     * 获取所有节点健康信息。
     */
    public func getNodes(): ArrayList<NodeHealth> {
        let result = ArrayList<NodeHealth>()
        for ((_, nh) in nodes) {
            result.add(nh)
        }
        result
    }

    public func close(): Unit {
        closed = true
        if (let Some(f) <- heartbeatThread) {
            f.get()
        }
    }

    /**
     * ping 单个节点。连接并发送 PING，超时 3 秒。
     */
    private func pingNode(nh: NodeHealth): Unit {
        if (closed) { return }
        try {
            let conn = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
                queueSize: 16, socketCount: 1,
                host: nh.host, port: nh.port,
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 30,
                checker: { _ => true }
            ).noDelay(true).build()
            let req = ProtocolMessage(Command.PING(0), MessageID(),
                MqBody("ping", []).toData())
            let resp = conn.transfer(req.id, req, Duration.second * 3)
            conn.close()
            if (resp.isSome()) {
                nh.lastSeen = DateTime.now()
                if (!nh.isAlive) {
                    nh.isAlive = true
                    nh.failedCount = 0
                    log.info{"node ${nh.host}:${nh.port} back online"}
                }
            } else {
                recordFailure(nh)
            }
        } catch (_: Exception) {
            recordFailure(nh)
        }
    }

    private func recordFailure(nh: NodeHealth): Unit {
        nh.failedCount += 1
        if (nh.failedCount >= config.healthcheckMaxRetry) {
            if (nh.isAlive) {
                nh.isAlive = false
                log.warn{"node ${nh.host}:${nh.port} marked offline after ${nh.failedCount} failures"}
            }
        }
    }
}
