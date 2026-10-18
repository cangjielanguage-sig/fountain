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
package fountain::f_mq.client

import std.sync.{Mutex, AtomicBool}
import fountain::f_data.DataAny
import fountain::f_mq.base.MQHost
import fountain::f_mq.exception.MQConnectionException
import fountain::f_net.client.Client
import fountain::f_protocol.default.Message

/**
 * 到各节点的 `Client<DataAny>` 连接池（懒建，每节点一条）。
 *
 * 心跳、重连、失败容忍全部复用 `f_net` 内建实现，MQ 不重复造。
 */
internal class MQNodePool {
    private let hosts: Array<String>
    private var clients: Array<?Client<DataAny>>
    private let lock = Mutex()
    private let closed = AtomicBool(false)

    init(hosts: Array<String>) {
        if (hosts.size == 0) {
            throw MQConnectionException("node list is empty")
        }
        for (entry in hosts) {
            if (MQHost.parseHost(entry).isNone()) {
                throw MQConnectionException("invalid node '${entry}', expect host:port")
            }
        }
        this.hosts = hosts
        this.clients = Array<?Client<DataAny>>(hosts.size) {_ => None<Client<DataAny>>}
    }

    prop size: Int64 {
        get() {
            hosts.size
        }
    }

    func hostOf(nodeIndex: Int64): String {
        hosts[nodeIndex]
    }

    /** 取（必要时创建）指定节点的连接；节点不可用时抛 `MQConnectionException`。 */
    func clientOf(nodeIndex: Int64): Client<DataAny> {
        if (nodeIndex < 0 || nodeIndex >= hosts.size) {
            throw MQConnectionException("node index ${nodeIndex} out of range [0, ${hosts.size})")
        }
        if (closed.load()) {
            throw MQConnectionException("client pool is closed")
        }
        synchronized(lock) {
            match (clients[nodeIndex]) {
                case Some(c) =>
                    if (c.isClosed()) {
                        throw MQConnectionException("connection to node ${nodeIndex} (${hosts[nodeIndex]}) is closed")
                    }
                    c
                case None => createClient(nodeIndex)
            }
        }
    }

    private func createClient(nodeIndex: Int64): Client<DataAny> {
        var created: ?Client<DataAny> = None
        try {
            created = Some(buildClient(hosts[nodeIndex]))
        } catch (e: Exception) {
            throw MQConnectionException("cannot connect to node ${nodeIndex} (${hosts[nodeIndex]})", e)
        }
        let client = created.getOrThrow()
        clients[nodeIndex] = client
        client
    }

    private static func buildClient(entry: String): Client<DataAny> {
        let (host, port) = MQHost.parseHost(entry).getOrThrow {
            MQConnectionException("invalid node '${entry}', expect host:port")
        }
        Client<DataAny>.builder(
            address: "${host}:${port}",
            checkDuration: Duration.second * 30,
            checker: {=> Message.ping()}
        ).pingTimeout(Duration.second).build()
    }

    /** 当前可用节点下标（已建连且未关闭；尚未建连的节点视为可用，由首次调用去探测）。 */
    func aliveNodes(): Array<Int64> {
        if (closed.load()) {
            return Array<Int64>()
        }
        let result = Array<Int64>(hosts.size) {_ => 0i64}
        var count = 0i64
        synchronized(lock) {
            for (i in 0..clients.size) {
                let available = match (clients[i]) {
                    case Some(c) => !c.isClosed()
                    case None => true
                }
                if (available) {
                    result[count] = i
                    count++
                }
            }
        }
        result[0..count]
    }

    /** 幂等关闭。 */
    func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        synchronized(lock) {
            for (i in 0..clients.size) {
                match (clients[i]) {
                    case Some(c) =>
                        try {
                            c.close()
                        } catch (_: Exception) {}
                        clients[i] = None<Client<DataAny>>
                    case None => ()
                }
            }
        }
    }

    func isClosed(): Bool {
        closed.load()
    }
}
