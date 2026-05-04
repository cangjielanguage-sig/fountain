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
package fountain::fsync.server

import std.collection.ArrayList
import std.sync.AtomicInt64
import fountain::f_base.*
import fountain::f_log.*
import fountain::f_net.client.*
import fountain::f_protocol.default.*
import fountain::fsync.base.{HostAndPort, HashRing, SyncData}

public class NodeManager {
    private static let log = LoggerFactory.getLogger('fountain::fsync.NodeManager')
    private let nodes: ArrayList<HostAndPort>       // 所有节点
    private let alive: AtomicInt64                   // 活跃节点数
    private let localIndex: Int64                    // 本地节点在列表中的索引
    private let hashRing: HashRing                   // 一致性哈希环

    public init(nodes: ArrayList<HostAndPort>, localIndex: Int64) {
        this.nodes = nodes
        this.localIndex = localIndex
        this.alive = AtomicInt64(nodes.size)
        this.hashRing = HashRing(nodes)
        // 健康检查后台线程：每 5 秒向其他节点发送 PING
        if (nodes.size > 1) {
            let others = this.allOthers()
            let aliveRef = this.alive
            spawn {
                while (true) {
                    try {
                        sleep(Duration.second * 5)
                        var count = 1i64  // 自己总是存活
                        for (node in others) {
                            if (pingNode(node.host, node.port)) {
                                count++
                            }
                        }
                        aliveRef.store(count)
                    } catch (_: Exception) {
                        // 异常不中断健康检查线程
                    }
                }
            }
        }
    }

    /** 向目标节点发送 PING，成功返回 true */
    private static func pingNode(host: String, port: UInt16): Bool {
        try {
            let c = Client<Message, EncodedMessage, Message, SyncData, MessageID>.builder(
                queueSize: 64,
                socketCount: 1,
                host: host,
                port: port,
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 10,
                checker: { buf => true }
            ).noDelay(true).build()
            let msg = Message(Command.PING(1))
            let resp = c.transfer(msg.id, msg, Duration.second * 2)
            c.close()
            if (let Some(r) <- resp) {
                match (r.command) {
                    case PING(_) => true
                    case _ => false
                }
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    public func canServeWrites(): Bool {
        alive.load() > nodes.size / 2
    }

    public func isOwner(key: String): Bool {
        hashRing.isOwner(key, localIndex)
    }

    public func getOwner(key: String): ?HostAndPort {
        hashRing.getNode(key)
    }

    public func getReadNode(key: String): ?HostAndPort {
        hashRing.getNode(key)
    }

    public func localNode(): HostAndPort {
        nodes[localIndex]
    }

    public func allOthers(): ArrayList<HostAndPort> {
        let others = ArrayList<HostAndPort>()
        for (i in 0..nodes.size) {
            if (i != localIndex) {
                others.add(nodes[i])
            }
        }
        others
    }
}
