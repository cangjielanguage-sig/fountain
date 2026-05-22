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

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, Command, MessageID}
import fountain::fmq.common.{MqBody}
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicBool
import std.sync.AtomicInt64

/**
 * 节点健康信息。
 */
public class NodeHealth {
    let host: String
    let port: UInt16
    var lastSeen: DateTime
    var isAlive: AtomicBool
    var failedCount: AtomicInt64

    public init(host: String, port: UInt16) {
        this.host = host
        this.port = port
        this.lastSeen = DateTime.now()
        this.isAlive = AtomicBool(true)
        this.failedCount = AtomicInt64(0)
    }
}

/**
 * Broker 节点管理器。
 * 管理 MQ 集群节点列表，通过 PING 做健康检查。
 */
public class BrokerManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.BrokerManager')
    private let closed = AtomicBool(false)
    private let nodes = ConcurrentHashMap<String, NodeHealth>()  // "host:port" → NodeHealth
    private let connectionPool = ConcurrentHashMap<String, Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>>()  // 连接池：复用以减少 TCP 握手
    private var heartbeatThread: ?Future<Unit> = None

    public init(config: MqConfig) {
        this.config = config
        // 从 mqHosts 初始化节点列表
        for (hostPort in config.mqHosts) {
            let parts = hostPort.split(':')
            if (parts.size == 2) {
                if (let Some(port) <- Int64.tryParse(parts[1])) {
                    let host = parts[0]
                    nodes[hostPort] = NodeHealth(host, UInt16(port))
                } else {
                    log.warn{"BrokerManager.init: invalid port in mqHosts entry '${hostPort}'"}
                }
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
            while (!selfRef.closed.load()) {
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
            if (!nh.isAlive.load()) { return false }
        }
        true
    }

    /**
     * 获取在线节点数。
     */
    public func aliveCount(): Int64 {
        var count: Int64 = 0
        for ((_, nh) in nodes) {
            if (nh.isAlive.load()) { count += 1 }
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
        closed.store(true)
        if (let Some(f) <- heartbeatThread) {
            f.get()
        }
        // 关闭连接池中所有连接
        for ((key, c) in connectionPool) {
            if (!c.isClosed()) { c.close() }
        }
    }

    /**
     * ping 单个节点。复用连接池中的长连接，避免每次心跳建立新 TCP 连接。
     * 连接失败时销毁并重建。
     */
    private func pingNode(nh: NodeHealth): Unit {
        if (closed.load()) { return }
        let key = "${nh.host}:${nh.port}"
        var c = connectionPool.get(key)
        if (let Some(conn) <- c) {
            if (conn.isClosed()) {
                // 连接已关闭，从池中移除
                connectionPool.remove(key)
                c = None
            }
        }
        var conn: ?Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID> = c
        if (conn.isNone()) {
            // 创建新连接
            var newConn: ?Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID> = None
            try {
                let nc = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
                    queueSize: 16, socketCount: 1,
                    host: nh.host, port: nh.port,
                    idGetter: { msg => msg.id },
                    checkDuration: Duration.second * 30,
                    checker: { _ => true }
                ).noDelay(true).build()
                connectionPool[key] = nc
                newConn = Some(nc)
                conn = newConn
            } catch (e: Exception) {
                log.warn{"create connection to ${nh.host}:${nh.port} failed: ${e.message}"}
                recordFailure(nh)
                return
            }
        }
        var localConn = conn  // capture let for catch
        try {
            let req = ProtocolMessage(Command.PING(0), MessageID(),
                MqBody("ping", []).toData())
            if (let Some(c) <- localConn) {
                let resp = c.transfer(req.id, req, Duration.second * 3)
                if (resp.isSome()) {
                    nh.lastSeen = DateTime.now()
                    if (!nh.isAlive.load()) {
                        nh.isAlive.store(true)
                        nh.failedCount.store(0)
                        log.info{"node ${nh.host}:${nh.port} back online"}
                    }
                } else {
                    recordFailure(nh)
                }
            }
        } catch (e: Exception) {
            log.warn{"pingNode ${nh.host}:${nh.port} failed: ${e.message}"}
            // 连接异常，销毁并移出池
            if (let Some(c) <- localConn) {
                if (!c.isClosed()) { c.close() }
            }
            connectionPool.remove(key)
            recordFailure(nh)
        }
    }

    private func recordFailure(nh: NodeHealth): Unit {
        let count = nh.failedCount.fetchAdd(1) + 1
        if (count >= config.healthcheckMaxRetry) {
            if (nh.isAlive.load()) {
                nh.isAlive.store(false)
                log.warn{"node ${nh.host}:${nh.port} marked offline after ${count} failures"}
            }
        }
    }
}
