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

import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, Mutex}
import std.time.DateTime
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.*
import fountain::f_log.*
import fountain::f_net.client.*
import fountain::f_protocol.default.*
import fountain::fsync.base.{HostAndPort, HashRing, SyncData, KeyData, ValueData, PatternData, ScanResult, WatchData}
import fountain::fsync.config.SyncConfig
import fountain::fsync.exception.{WriteFailedException, InvalidKeyException}

public class SyncClient {
    private static let log = LoggerFactory.getLogger('fountain::fsync.SyncClient')
    private let hashRing: HashRing
    private let nodes: ArrayList<HostAndPort>
    private let clients = ConcurrentHashMap<String, Client<Message, EncodedMessage, Message, SyncData, MessageID>>()
    private let clientLock = Mutex()
    private let requestTimeout: Duration
    private let watchCancelled = ConcurrentHashMap<String, AtomicBool>()

    public init(requestTimeout!: Duration = Duration.second * 10) {
        let hostsArr = SyncConfig.getHosts()
        this.nodes = ArrayList<HostAndPort>(hostsArr.size) { i => hostsArr[i] }
        this.hashRing = HashRing(this.nodes)
        this.requestTimeout = requestTimeout
    }

    public func get<T>(key: String): ?T where T <: DataFields<T> {
        requireAbsolutePath(key)
        if (let Some(bytes) <- getBytes(key)) {
            DefaultCodec().decode<T>(ByteBuffer(bytes))
        } else {
            None
        }
    }

    /** 获取原始字节值（非 Generic 版本） */
    public func getBytes(key: String): ?Array<Byte> {
        requireAbsolutePath(key)
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

    public func add<T>(key: String, value: T): Unit where T <: DataFields<T> {
        requireAbsolutePath(key)
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.REGISTER, SyncData.encodeValue<T>(key, value).toData())
            if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
                return
            }
        }
        throw WriteFailedException(key)
    }

    public func delete(key: String): Unit {
        requireAbsolutePath(key)
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.DEREGISTER, KeyData(key).toData())
            if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
                return ()
            }
        }
        throw WriteFailedException(key)
    }

    public func prefix(pattern: String): ScanResult {
        requireAbsolutePath(pattern)
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

    public func watch<T>(key: String, timeout!: Duration = Duration.Zero): ?T where T <: DataFields<T> {
        requireAbsolutePath(key)
        let cancel = AtomicBool(false)
        watchCancelled[key] = cancel
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.SUBSCRIBE, WatchData(key, timeout: timeout).toData())
            let _ = client.transfer(req.id, req, requestTimeout)
        }
        let startBytes = getBytes(key)
        let deadline = if (timeout > Duration.Zero) { DateTime.now() + timeout } else { None<DateTime> }
        while (true) {
            if (cancel.load()) {
                return None
            }
            if (let Some(d) <- deadline && DateTime.now() >= d) {
                return None
            }
            sleep(Duration.millisecond * 50)
            let current = getBytes(key)
            if (!sameBytes(current, startBytes)) {
                if (let Some(bytes) <- current) {
                    return DefaultCodec().decode<T>(ByteBuffer(bytes))
                }
                return None
            }
        }
        None
    }

    public func unwatch(key: String): Unit {
        requireAbsolutePath(key)
        if (let Some(cancel) <- watchCancelled.get(key)) {
            cancel.store(true)
        }
        if (let Some(owner) <- hashRing.getNode(key)) {
            let client = getOrCreateClient(owner)
            let req = Message(Command.UNSUBSCRIBE, KeyData(key).toData())
            let _ = client.transfer(req.id, req, requestTimeout)
        }
    }

    /** 检查 KEY 是否为绝对路径形式 */
    private static func requireAbsolutePath(key: String): Unit {
        if (!key.startsWith('/')) {
            throw InvalidKeyException(key)
        }
    }

    /** 比较两个 ?Array<Byte> 是否相等 */
    public static func sameBytes(a: ?Array<Byte>, b: ?Array<Byte>): Bool {
        if (let Some(va) <- a) {
            if (let Some(vb) <- b) {
                if (va.size != vb.size) { return false }
                for (i in 0..va.size) {
                    if (va[i] != vb[i]) { return false }
                }
                return true
            }
            return false  // a is Some, b is None
        }
        b.isNone()  // a is None, return whether b is also None
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
