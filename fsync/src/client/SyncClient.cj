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
package fountain::fsync.client

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.Mutex
import fountain::f_data.*
import fountain::f_log.*
import fountain::f_net.client.*
import fountain::f_protocol.default.*
import fountain::fsync.base.{HostAndPort, HashRing, SyncData, KeyData, ValueData, PatternData, ScanResult, WatchData}
import fountain::fsync.config.SyncConfig

public class SyncClient {
    private static let log = LoggerFactory.getLogger('fountain::fsync.SyncClient')
    private let hashRing: HashRing
    private let nodes: ArrayList<HostAndPort>
    private let clients = ConcurrentHashMap<String, Client<Message, EncodedMessage, Message, SyncData, MessageID>>()
    private let clientLock = Mutex()
    private let requestTimeout: Duration

    public init(requestTimeout!: Duration = Duration.second * 10) {
        let hostsArr = SyncConfig.getHosts()
        this.nodes = ArrayList<HostAndPort>(hostsArr.size) { i => hostsArr[i] }
        this.hashRing = HashRing(this.nodes)
        this.requestTimeout = requestTimeout
    }

    public func get(key: String): ?Array<Byte> {
        if (let Some(owner) <- hashRing.getNode(key)) {
            let ownerNode = owner
            // 先试 Owner 节点
            if (let Some(v) <- tryReadNode(key, ownerNode)) {
                return v
            }
            // 故障转移：按 ring 顺序尝试其他节点
            for (j in 1..nodes.size) {
                if (let Some(n) <- hashRing.getNextNode(key, j)) {
                    if (n.host != ownerNode.host || n.port != ownerNode.port) {
                        if (let Some(v) <- tryReadNode(key, n)) {
                            return v
                        }
                    }
                }
            }
        }
        None
    }

    private func tryReadNode(key: String, node: HostAndPort): ?Array<Byte> {
        let client = getOrCreateClient(node)
        let req = Message(Command.ACK, KeyData(key).toData())
        if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
            let vd = convert<ValueData>(resp.data)
            match (vd) {
                case Some(v: ValueData) => v.value
                case _ => None
            }
        } else {
            None
        }
    }

    public func add(key: String, value: Array<Byte>): Unit {
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.REGISTER, SyncData(key, 0, value).toData())
            if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
                return ()
            }
        }
        throw Exception('add failed for key: ${key}')
    }

    public func delete(key: String): Unit {
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.DEREGISTER, KeyData(key).toData())
            if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
                return ()
            }
        }
        throw Exception('delete failed for key: ${key}')
    }

    public func prefix(pattern: String): ScanResult {
        if (let Some(owner) <- hashRing.getNode(pattern)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.ACK, PatternData(pattern).toData())
            if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
                if (let Some(result) <- convert<ScanResult>(resp.data)) {
                    return result
                }
            }
        }
        ScanResult()
    }

    public func glob(pattern: String): ScanResult {
        // GLOB 复用 PREFIX 扫描（由服务端做 * 通配符前缀截断）
        prefix(pattern)
    }

    public func watch(key: String, timeout!: Duration = Duration.Zero): Unit {
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.SUBSCRIBE, WatchData(key, timeout: timeout).toData())
            let _ = client.transfer(req.id, req, requestTimeout)
        }
    }

    public func unwatch(key: String): Unit {
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.UNSUBSCRIBE, KeyData(key).toData())
            let _ = client.transfer(req.id, req, requestTimeout)
        }
    }

    private func getOrCreateClient(node: HostAndPort): Client<Message, EncodedMessage, Message, SyncData, MessageID> {
        let key = '${node.host}:${node.port}'
        if (clients.contains(key)) {
            return clients.get(key).getOrThrow()
        }
        synchronized(clientLock) {
            if (clients.contains(key)) {
                return clients.get(key).getOrThrow()
            }
            let client = Client<Message, EncodedMessage, Message, SyncData, MessageID>.builder(
                queueSize: 1024,
                socketCount: 1,
                host: node.host,
                port: node.port,
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 30,
                checker: { buffer => true }
            ).noDelay(true).build()
            clients[key] = client
            client
        }
    }
}
