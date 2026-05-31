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
import std.sync.{AtomicBool, Mutex}
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
    /** 同步队列（写线程入队，各 slave 专用线程并行出队）。P2-2: per-slave queue。*/
    private let slaveSyncQueues = ConcurrentHashMap<String, ConcurrentLinkedQueue<Array<Byte>>>()
    private let syncClosed = AtomicBool(false)
    private var syncThreads = ConcurrentHashMap<String, Future<Unit>>()
    private let syncLock = Mutex()  // 保护 syncThreads check-then-act
    private let slaveConnLock = Mutex()  // P3-2: 保护 slaveConns check-and-create 原子性
    /** 缓存 (topic+queueIndex) 编码前缀，避免每次 syncToSlaves 重编码 */
    private let syncPrefix: Array<Byte>

    public init(queue: MqQueue, config: MqConfig, replicationManager!: ReplicationManager, queueSize!: Int64 = 1024) {
        this.queue = queue
        this.config = config
        this.replicationManager = replicationManager
        this.inboundQueue = ConcurrentLinkedQueue<Array<Byte>>()
        // 预计算同步前缀（topic + queueIndex 编码），SRV-5
        let prefixBuf = ByteBuffer()
        DefaultCodec()
            .encode(queue.topic).encode(queue.index)
            .finish().copy(to: prefixBuf, closeFromOnEnd: true, closeToOnEnd: false)
        this.syncPrefix = extractBytes(prefixBuf)
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
     * 关闭 Writer。幂等，可多次安全调用。
     * 设置 closed 标志让 run() 循环退出，等待同步线程结束，关闭从节点连接。
     * 注意：不排空 inboundQueue/syncQueue 中的待处理消息。关闭前需确认无新提交。
     */
    public func close(): Unit {
        if (closed.load()) { return }
        closed.store(true)
        syncClosed.store(true)
        // P2-3: synchronized 确保 startSyncThread 的 put 不遗漏
        let snapshot: ArrayList<Future<Unit>>
        synchronized(syncLock) {
            snapshot = ArrayList<Future<Unit>>()
            for ((_, f) in syncThreads) { snapshot.add(f) }
        }
        for (f in snapshot) {
            try { f.get() } catch (_: Exception) {}
        }
        syncThreads = ConcurrentHashMap<String, Future<Unit>>()
        for ((_, c) in slaveConns) {
            if (!c.isClosed()) { c.close() }
        }
    }

    public func isClosed(): Bool { closed.load() }

    /**
     * 同步 message 到所有已注册的从节点。
     * 将 sync entry 入队到各 slave 专用队列，由各 slave 线程异步处理。
     * P2-2: 每个 slave 有自己的队列和线程，不互相阻塞。
     */
    private func syncToSlaves(data: Array<Byte>): Unit {
        let slaves = replicationManager.getSlaves()
        if (slaves.size == 0) { return }

        // 编码 topic + queueIndex + data 到单个 sync entry（前缀已缓存，SRV-5）
        let dataBuf = ByteBuffer()
        DefaultCodec().encode(data)
            .finish().copy(to: dataBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let encodedData = extractBytes(dataBuf)
        let total = Array<Byte>(syncPrefix.size + encodedData.size, repeat: 0u8)
        for (i in 0..syncPrefix.size) { total[i] = syncPrefix[i] }
        for (i in 0..encodedData.size) { total[syncPrefix.size + i] = encodedData[i] }
        // 写入每个 slave 的专用队列
        for (slave in slaves) {
            let key = slave.nodeId
            if (let Some(q) <- slaveSyncQueues.get(key)) {
                q.add(total)
            } else {
                log.warn{"sync queue not ready for slave ${key}, sync data discarded"}
            }
        }
    }

    /**
     * 启动后台同步线程（每个 slave 一个专用线程）。
     * 各 slave 线程独立从自己的队列消费，互不阻塞。
     * P2-2: 用 per-slave 线程替代每消息内层 spawn。
     */
    public func startSyncThread(): Unit {
        let slaves = replicationManager.getSlaves()
        if (slaves.size == 0) { return }
        let selfRef = this
        for (slave in slaves) {
            let nodeId = slave.nodeId
            synchronized(syncLock) {
                if (syncThreads.get(nodeId).isSome()) { continue }
                // 为每个 slave 创建专用队列
                slaveSyncQueues[nodeId] = ConcurrentLinkedQueue<Array<Byte>>()
                let slaveId = nodeId
                syncThreads[slaveId] = spawn {
                    while (!selfRef.syncClosed.load()) {
                        if (let Some(q) <- selfRef.slaveSyncQueues.get(slaveId)) {
                            if (let Some(entry) <- q.remove()) {
                                selfRef.syncToSlave(slaveId, entry)
                            } else { sleep(Duration.millisecond * 10) }
                        } else { sleep(Duration.millisecond * 10) }
                    }
                }
            }
        }
        log.info{"startSyncThread: ${slaves.size} slave sync threads started"}
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
            let port = if (let Some(p) <- UInt16.tryParse(parts[1])) {
                p
            } else {
                log.warn{"syncToSlave: invalid port '${parts[1]}' for node ${nodeId}"}
                return false
            }
            var conn = slaveConns.get(nodeId)
            if (let Some(c) <- conn) {
                if (c.isClosed()) {
                    slaveConns.remove(nodeId)
                    conn = None
                }
            }
            if (conn.isNone()) {
                // P3-2: synchronized 防止两线程同时创建连接 → 旧连接被覆盖且泄漏
                synchronized(slaveConnLock) {
                    if (let Some(existing) <- slaveConns.get(nodeId)) {
                        conn = Some(existing)
                    } else {
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
