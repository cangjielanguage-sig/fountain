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

import std.collection.concurrent.{ConcurrentHashMap, ConcurrentLinkedQueue}
import std.io.ByteBuffer
import std.sync.AtomicBool
import fountain::f_codec.default.DefaultCodec
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, Command, MessageID}
import fountain::fmq.common.{MqBody, MqConfig, extractBytes}

/**
 * 队列写线程。
 * 从 inboundQueue 接收消息，写入 SegmentedLog，同步到从节点。
 */
public class QueueWriter {
    private let queue: MqQueue
    private let replicationManager: ReplicationManager
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueWriter')
    private let closed = AtomicBool(false)
    private let inboundQueue: ConcurrentLinkedQueue<Array<Byte>>
    /** 从节点连接池：nodeId → Client，复用长连接减少 TCP 握手。 */
    private let slaveConns = ConcurrentHashMap<String, Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>>()

    public init(queue: MqQueue, config: MqConfig, replicationManager!: ReplicationManager, queueSize!: Int64 = 1024) {
        this.queue = queue
        this.config = config
        this.replicationManager = replicationManager
        this.inboundQueue = ConcurrentLinkedQueue<Array<Byte>>()
    }

    /**
     * 提交数据到写入队列。
     */
    public func submit(data: Array<Byte>): Unit {
        inboundQueue.add(data)
    }

    /**
     * 写线程主循环。
     */
    public func run(): Unit {
        while (!closed.load()) {
            try {
                if (let Some(data) <- inboundQueue.remove()) {
                    queue.append(data)
                    queue.sync()
                    syncToSlaves(data)
                } else {
                    sleep(Duration.millisecond * 10)
                }
            } catch (e: Exception) {
                log.error{"QueueWriter error: ${e.message}"}
            }
        }
    }

    /**
     * 关闭 Writer。设置 closed 标志让 run() 循环退出。
     * 关闭所有从节点长连接。
     * 注意：不排空 inboundQueue 中的待处理消息。关闭前需确认无新提交。
     */
    public func close(): Unit {
        closed.store(true)
        for ((_, c) in slaveConns) {
            if (!c.isClosed()) { c.close() }
        }
    }

    /**
     * 同步 message 到所有已注册的从节点。
     * 编码 queueIndex + data 以便从节点正确写入对应队列。
     */
    private func syncToSlaves(data: Array<Byte>): Unit {
        let slaves = replicationManager.getSlaves()
        if (slaves.size == 0) { return }

        // 编码 topic + queueIndex + data 到单个 sync entry
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(queue.topic).encode(queue.index).encode(data)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let syncEntry = extractBytes(buf)

        // 异步同步到每个从节点 — 不阻塞主写循环
        // 同步失败只记录日志，不影响消息写入
        for (slave in slaves) {
            spawn { syncToSlave(slave.nodeId, syncEntry) }
        }
    }

    /**
     * 向单个从节点发送同步数据。
     * 通过 f_net::Client 的长连接发送 MqBody("sync", data) 并等待确认。
     * 连接失败时自动重建。
     */
    private func syncToSlave(nodeId: String, data: Array<Byte>): Bool {
        // 从 mqHosts 中查找 nodeId 对应的地址
        var addr: ?String = None
        for (hostPort in config.mqHosts) {
            if (hostPort.startsWith(nodeId) || hostPort == nodeId) {
                addr = Some(hostPort)
                break
            }
        }
        if (let Some(target) <- addr) {
            let parts = target.split(':')
            if (parts.size != 2) {
                log.warn{"syncToSlave: invalid addr ${target} for node ${nodeId}"}
                return false
            }
            let host = parts[0]
            let port = UInt16(Int64.parse(parts[1]))
            var conn = slaveConns.get(nodeId)
            if (let Some(c) <- conn) {
                if (c.isClosed()) {
                    slaveConns.remove(nodeId)
                    conn = None
                }
            }
            if (conn.isNone()) {
                try {
                    let c = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
                        queueSize: 16, socketCount: 1, host: host, port: port,
                        idGetter: { msg => msg.id },
                        checkDuration: Duration.second * 30,
                        checker: { _ => true }
                    ).noDelay(true).build()
                    slaveConns[nodeId] = c
                    conn = Some(c)
                } catch (e: Exception) {
                    log.warn{"syncToSlave: connect to ${nodeId}(${target}) failed: ${e.message}"}
                    return false
                }
            }
            if (let Some(c) <- conn) {
                try {
                    let req = ProtocolMessage(Command.PUBLISH(0), MessageID(),
                        MqBody("sync", data).toData())
                    let resp = c.transfer(req.id, req, Duration.second * 5)
                    if (resp.isSome()) {
                        return true
                    } else {
                        log.warn{"syncToSlave: ${nodeId} no response"}
                        return false
                    }
                } catch (e: Exception) {
                    log.warn{"syncToSlave: send to ${nodeId} failed: ${e.message}"}
                    // 连接异常，销毁并移出池
                    if (!c.isClosed()) { c.close() }
                    slaveConns.remove(nodeId)
                    return false
                }
            }
        } else {
            log.warn{"syncToSlave: no address found for node ${nodeId} in mqHosts"}
        }
        false
    }
}
