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
package fountain::fmq.cluster

import std.collection.ArrayList
import std.sync.{AtomicBool, Mutex}
import fountain::f_data.DataAny
import fountain::f_log.*
import fountain::f_mq.base.MQHost
import fountain::f_net.client.Client
import fountain::f_protocol.default.Message

/**
 * 节点表、节点下标与到各节点的连接。
 *
 * 心跳 / 重连复用 `f_net` 客户端内建实现；MQ 侧只维护「最近一次调用是否成功」的存活标记。
 * 自身节点不建连（`clientOf(self) == None`）。
 */
protected class NodeRegistry <: MQNodeTransport & Resource {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.NodeRegistry")

    private let nodes: Array<String>
    private let self: Int64
    private let pingTimeout: Duration
    private let clients: Array<?Client<DataAny>>
    private let alive: Array<AtomicBool>
    private let lock = Mutex()
    private let closed = AtomicBool(false)
    private var revivedCallback: ?(() -> Unit) = None

    protected init(nodes: Array<String>, selfIndex: Int64, checkDuration!: Duration = Duration.second * 30,
        pingTimeout!: Duration = Duration.second) {
        if (selfIndex < 0 || selfIndex >= nodes.size) {
            throw IllegalArgumentException("selfIndex ${selfIndex} out of range [0, ${nodes.size})")
        }
        for (entry in nodes) {
            if (MQHost.parseHost(entry).isNone()) {
                throw IllegalArgumentException("invalid node '${entry}', expect host:port")
            }
        }
        this.nodes = nodes
        this.self = selfIndex
        this.pingTimeout = pingTimeout
        this.clients = Array<?Client<DataAny>>(nodes.size) {_ => None<Client<DataAny>>}
        this.alive = Array<AtomicBool>(nodes.size) {_ => AtomicBool(true)}
        this.checkDuration_ = checkDuration
    }

    private let checkDuration_: Duration

    public prop selfIndex: Int64 {
        get() {
            self
        }
    }

    public prop nodeCount: Int64 {
        get() {
            nodes.size
        }
    }

    /** 节点由死转活时的回调（服务装配里接到 `MetaSyncer.syncFromPeers`）。 */
    protected mut prop onRevived: ?(() -> Unit) {
        get() {
            revivedCallback
        }
        set(value) {
            revivedCallback = value
        }
    }

    protected func nodeAt(index: Int64): ?(String, UInt16) {
        if (index < 0 || index >= nodes.size) {
            None<(String, UInt16)>
        } else {
            MQHost.parseHost(nodes[index])
        }
    }

    /** 本节点返回 `None`；其余节点懒建连接（失败抛 `Exception`）。 */
    protected func clientOf(index: Int64): ?Client<DataAny> {
        if (index == self) {
            return None<Client<DataAny>>
        }
        if (index < 0 || index >= nodes.size) {
            throw IllegalArgumentException("node index ${index} out of range [0, ${nodes.size})")
        }
        synchronized(lock) {
            match (clients[index]) {
                case Some(client) =>
                    if (client.isClosed()) {
                        throw Exception("connection to node ${index} is closed")
                    }
                    client
                case None =>
                    let (host, port) = MQHost.parseHost(nodes[index]).getOrThrow {
                        IllegalArgumentException("invalid node '${nodes[index]}'")
                    }
                    let client = Client<DataAny>.builder(
                        address: "${host}:${port}",
                        checkDuration: checkDuration_,
                        checker: {=> Message.ping()}
                    ).pingTimeout(pingTimeout).build()
                    clients[index] = client
                    client
            }
        }
    }

    /** 向指定节点发请求；自身或失败返回 `None`。 */
    public func send(index: Int64, message: Message): ?Message {
        if (index == self || closed.load()) {
            return None<Message>
        }
        try {
            let result = clientOf(index).getOrThrow().transfer(message, pingTimeout * 5)
            markSeen(index)
            result
        } catch (e: Exception) {
            markFailed(index)
            log.warn("send to node ${index} failed: ${e.message}")
            None<Message>
        }
    }

    /** 环形后续节点：`(self + 1 .. self + count) % nodeCount`。 */
    public func successors(count: Int64): Array<Int64> {
        let result = ArrayList<Int64>()
        if (count <= 0 || nodes.size <= 1) {
            return result.toArray()
        }
        let limit = if (count < nodes.size) {
            count
        } else {
            nodes.size - 1
        }
        for (i in 1..=limit) {
            result.add((self + i) % nodes.size)
        }
        result.toArray()
    }

    protected func indexOf(address: String): ?Int64 {
        for (i in 0..nodes.size) {
            if (nodes[i] == address) {
                return Some(i)
            }
        }
        None<Int64>
    }

    protected func markSeen(index: Int64): Unit {
        if (index >= 0 && index < alive.size) {
            let wasAlive = alive[index].load()
            alive[index].store(true)
            if (!wasAlive) {
                log.info("node ${index} is back online")
                // 恢复后补齐离线期间错过的元数据变更；回调异常不得影响心跳/调用线程
                match (revivedCallback) {
                    case Some(callback) =>
                        try {
                            callback()
                        } catch (e: Exception) {
                            log.warn("resync after node ${index} revived failed: ${e.message}")
                        }
                    case None => ()
                }
            }
        }
    }

    protected func markFailed(index: Int64): Unit {
        if (index >= 0 && index < alive.size) {
            alive[index].store(false)
        }
    }

    protected func isAlive(index: Int64): Bool {
        if (index < 0 || index >= alive.size) {
            false
        } else {
            alive[index].load()
        }
    }

    public func isClosed(): Bool {
        closed.load()
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        synchronized(lock) {
            for (i in 0..clients.size) {
                match (clients[i]) {
                    case Some(client) =>
                        try {
                            client.close()
                        } catch (_: Exception) {}
                        clients[i] = None<Client<DataAny>>
                    case None => ()
                }
            }
        }
    }
}
