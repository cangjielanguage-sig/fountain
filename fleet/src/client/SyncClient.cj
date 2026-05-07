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
package fountain::fleet.client

import std.io.ByteBuffer
import std.sync.Mutex
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.*
import fountain::f_log.*
import fountain::f_net.client.*
import fountain::f_protocol.default.*
import fountain::fleet.base.{SyncData, KeyData, ValueData, PatternData, ScanResult, WatchData}
import fountain::fleet.config.SyncConfig
import fountain::fleet.exception.{WriteFailedException, InvalidKeyException}

public class SyncClient {
    private static let log = LoggerFactory.getLogger('fountain::fleet.SyncClient')
    private static var instance: ?SyncClient = None
    private static let instanceLock = Mutex()

    private let requestTimeout: Duration
    private let client: Client<Message, EncodedMessage, Message, SyncData, MessageID>

    private init(client: Client<Message, EncodedMessage, Message, SyncData, MessageID>, requestTimeout: Duration) {
        this.client = client
        this.requestTimeout = requestTimeout
    }

    /** 获取全局唯一的 SyncClient 实例（连接 fleet_hosts 的第一个节点） */
    public static func getInstance(requestTimeout!: Duration = Duration.second * 10): SyncClient {
        synchronized(instanceLock) {
            if (let Some(inst) <- instance) {
                return inst
            }
            let hostsArr = SyncConfig.getHosts()
            if (hostsArr.size == 0) {
                throw InvalidKeyException('${SyncConfig.hosts} is required')
            }
            let host = hostsArr[0]
            let client = Client<Message, EncodedMessage, Message, SyncData, MessageID>.builder(
                queueSize: 1024,
                socketCount: 1,
                host: host.host,
                port: host.port,
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 30,
                checker: { buffer => true }
            ).noDelay(true).build()
            let inst = SyncClient(client, requestTimeout)
            instance = inst
            inst
        }
    }

    public func get<T>(key: String): ?T where T <: DataFields<T> {
        requireAbsolutePath(key)
        if (let Some(bytes) <- getBytes(key)) {
            DefaultCodec().decode<T>(ByteBuffer(bytes))
        } else {
            None
        }
    }

    public func getBytes(key: String): ?Array<Byte> {
        requireAbsolutePath(key)
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
        let encoded = SyncData.encodeValue<T>(key, value)
        let req = Message(Command.REGISTER, encoded.toData())
        if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
            return
        }
        throw WriteFailedException(key)
    }

    public func delete(key: String): Unit {
        requireAbsolutePath(key)
        let req = Message(Command.DEREGISTER, KeyData(key).toData())
        if (let Some(resp) <- client.transfer(req.id, req, requestTimeout)) {
            return
        }
        throw WriteFailedException(key)
    }

    public func prefix(pattern: String): ScanResult {
        scan(pattern)
    }

    public func glob(pattern: String): ScanResult {
        scan(pattern)
    }

    /** prefix 和 glob 的底层实现：发送 PatternData，解码 ValueData blob */
    private func scan(pattern: String): ScanResult {
        requireAbsolutePath(pattern)
        let req = Message(Command.ACK, PatternData(pattern).toData())
        if (let Some(resp) <- client.transfer(req.id, req, requestTimeout) &&
            let Some(vd) <- convert<ValueData>(resp.data) &&
            let Some(blob) <- vd.value) {
            return ScanResult.decodeFromBytes(blob)
        }
        ScanResult()
    }

    public func watch<T>(key: String, timeout!: Duration = Duration.Zero): ?T where T <: DataFields<T> {
        requireAbsolutePath(key)
        let req = Message(Command.SUBSCRIBE, WatchData(key, timeout: timeout).toData())
        let t = if (timeout > Duration.Zero) { timeout } else { requestTimeout }
        if (let Some(resp) <- client.transfer(req.id, req, t)) {
            if (let Some(vd) <- convert<ValueData>(resp.data)) {
                if (let Some(bytes) <- vd.value) {
                    return DefaultCodec().decode<T>(ByteBuffer(bytes))
                }
            }
        }
        None
    }

    public func unwatch(key: String): Unit {
        requireAbsolutePath(key)
        let req = Message(Command.UNSUBSCRIBE, KeyData(key).toData())
        let _ = client.transfer(req.id, req, requestTimeout)
    }

    /** 检查 KEY 是否为绝对路径形式 */
    internal static func requireAbsolutePath(key: String): Unit {
        if (!key.startsWith('/')) {
            throw InvalidKeyException(key)
        }
    }
}
