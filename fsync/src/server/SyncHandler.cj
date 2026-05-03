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

import std.binary.*
import std.sync.AtomicInt64
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store

private let VERSION_SUFFIX = '_version'.unsafeBytes()

public class SyncHandler {
    private let store: Store
    private let nodeManager: NodeManager
    private let watchManager: WatchManager
    private let sequence: AtomicInt64

    public init(store: Store, nodeManager: NodeManager, watchManager: WatchManager) {
        this.store = store
        this.nodeManager = nodeManager
        this.watchManager = watchManager
        this.sequence = AtomicInt64(0)
    }

    public func handle(request: Message): Message {
        match (request.command) {
            case REGISTER => handleRegister(request)
            case DEREGISTER => handleDeregister(request)
            case PUBLISH(_) => handlePublish(request)
            case SUBSCRIBE => handleSubscribe(request)
            case UNSUBSCRIBE => handleUnsubscribe(request)
            case PING(_) => handlePing(request)
            case _ => errorResp('unknown command')
        }
    }

    private func handleRegister(req: Message): Message {
        if (!nodeManager.canServeWrites()) {
            return errorResp('quorum not met')
        }
        if (let Some(d) <- convert<SyncData>(req.data)) {
            if (!nodeManager.isOwner(d.key)) {
                return errorResp('not the owner node for key: ${d.key}')
            }
            doRegister(d)
        } else {
            errorResp('invalid REGISTER payload')
        }
    }

    private func doRegister(d: SyncData): Message {
        let key = d.key.unsafeBytes()
        let version = sequence.fetchAdd(1) + 1
        store.add(key, d.value)
        store.add(makeVersionKey(key), encodeVersion(version))
        asyncPublish(d.key, version, d.value)
        watchManager.notify(d.key, d.value)
        Message(Command.RESP(0), KeyData(d.key).toData())
    }

    private func handleDeregister(req: Message): Message {
        if (!nodeManager.canServeWrites()) {
            return errorResp('quorum not met')
        }
        if (let Some(d) <- convert<KeyData>(req.data)) {
            if (!nodeManager.isOwner(d.key)) {
                return errorResp('not the owner node')
            }
            doDeregister(d)
        } else {
            errorResp('invalid DEREGISTER payload')
        }
    }

    private func doDeregister(d: KeyData): Message {
        let key = d.key.unsafeBytes()
        let version = sequence.fetchAdd(1) + 1
        store.remove(key)
        store.add(makeVersionKey(key), encodeVersion(version))
        asyncPublish(d.key, version, [])
        watchManager.notify(d.key, [])
        Message(Command.RESP(0), KeyData(d.key).toData())
    }

    private func handlePublish(req: Message): Message {
        if (let Some(d) <- convert<SyncData>(req.data)) {
            let key = d.key.unsafeBytes()
            let localVersion = readLocalVersion(key)
            if (d.version > localVersion) {
                store.add(key, d.value)
                store.add(makeVersionKey(key), encodeVersion(d.version))
                watchManager.notify(d.key, d.value)
            }
            Message(Command.RESP(0), KeyData(d.key).toData())
        } else {
            errorResp('invalid PUBLISH payload')
        }
    }

    private func handleSubscribe(req: Message): Message {
        if (let Some(d) <- convert<WatchData>(req.data)) {
            watchManager.registerExact(d.key, d.timeout, {_ => })
            Message(Command.RESP(0), KeyData(d.key).toData())
        } else {
            errorResp('invalid SUBSCRIBE payload')
        }
    }

    private func handleUnsubscribe(req: Message): Message {
        if (let Some(d) <- convert<KeyData>(req.data)) {
            watchManager.unwatch(d.key)
            Message(Command.RESP(0), KeyData(d.key).toData())
        } else {
            errorResp('invalid UNSUBSCRIBE payload')
        }
    }

    private func handlePing(_: Message): Message {
        Message(Command.PING(1))
    }

    private static func errorResp(msg: String): Message {
        Message(Command.RESP(0), KeyData(msg).toData())
    }

    private func asyncPublish(key: String, version: Int64, value: Array<Byte>): Unit {
        let _ = nodeManager.allOthers()
        // TODO: 在 Step 8 (SyncClient) 中实现向对端 PUBLISH
    }

    private func readLocalVersion(key: Array<Byte>): Int64 {
        if (let Some(bytes) <- store.get(makeVersionKey(key))) {
            decodeVersion(bytes)
        } else {
            0
        }
    }

    public static func encodeVersion(version: Int64): Array<Byte> {
        let buf = Array<Byte>(8, repeat: 0u8)
        version.writeBigEndian(buf)
        buf
    }

    public static func decodeVersion(bytes: Array<Byte>): Int64 {
        Int64.readBigEndian(bytes)
    }

    private static func makeVersionKey(key: Array<Byte>): Array<Byte> {
        let result = Array<Byte>(key.size + VERSION_SUFFIX.size, repeat: 0u8)
        for (i in 0..key.size) { result[i] = key[i] }
        for (i in 0..VERSION_SUFFIX.size) { result[key.size + i] = VERSION_SUFFIX[i] }
        result
    }
}
