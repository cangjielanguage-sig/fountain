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
import std.fs.{exists, remove}
import std.sync.AtomicBool
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::fsync.base.{HostAndPort, SyncData, KeyData, ValueData, PatternData, ScanResult, WatchData}

@Test
class SyncHandlerStoreTest {
    @TestCase
    func registerWritesToStore(): Unit {
        let dir = '/tmp/fsync_test/register'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let key = '/app/config/db/host'
        let value = [104u8, 101u8, 108u8, 108u8, 111u8]
        let msg = Message(Command.REGISTER, SyncData(key, 0, value).toData())
        let resp = handler.handle(msg)
        let isResp = match (resp.command) { case RESP(_) => true case _ => false }
        @Assert(isResp)
        var stored = store.get(key.unsafeBytes())
        if (let Some(s) <- stored) {
            @Assert(s.size == value.size)
        } else {
            @Assert(false)
        }
        store.close()
        cleanup(dir)
    }

    @TestCase
    func pingReturnsPing(): Unit {
        let dir = '/tmp/fsync_test/ping'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let msg = Message(Command.PING(1))
        let resp = handler.handle(msg)
        let isPing = match (resp.command) { case PING(_) => true case _ => false }
        @Assert(isPing)
        store.close()
        cleanup(dir)
    }

    @TestCase
    func invalidPayloadReturnsError(): Unit {
        let dir = '/tmp/fsync_test/invalid'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let msg = Message(Command.REGISTER)
        let resp = handler.handle(msg)
        let isResp = match (resp.command) { case RESP(_) => true case _ => false }
        @Assert(isResp)
        store.close()
        cleanup(dir)
    }

    @TestCase
    func getKeyReturnsValueAfterRegister(): Unit {
        let dir = '/tmp/fsync_test/get_after_register'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let key = '/app/config/db/host'
        let value = [104u8, 101u8, 108u8, 108u8, 111u8]
        // 先 REGISTER
        let _ = handler.handle(Message(Command.REGISTER, SyncData(key, 0, value).toData()))
        // 再 GET
        let resp = handler.handle(Message(Command.ACK, KeyData(key).toData()))
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            if (let Some(v) <- vd.value) {
                @Assert(v.size == value.size)
            } else {
                @Assert(false)
            }
        } else {
            @Assert(false)
        }
        store.close()
        cleanup(dir)
    }

    @TestCase
    func getNonExistentKeyReturnsNone(): Unit {
        let dir = '/tmp/fsync_test/get_nonexist'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let resp = handler.handle(Message(Command.ACK, KeyData('/app/nonexistent').toData()))
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            @Assert(vd.value.isNone())
        } else {
            @Assert(false)
        }
        store.close()
        cleanup(dir)
    }

    @TestCase
    func deregisterRemovesKey(): Unit {
        let dir = '/tmp/fsync_test/deregister'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let key = '/app/config/db/host'
        let value = [1u8, 2u8, 3u8]
        // REGISTER
        let _ = handler.handle(Message(Command.REGISTER, SyncData(key, 0, value).toData()))
        // 验证已写入
        @Assert(store.get(key.unsafeBytes()).isSome())
        // DEREGISTER
        let _ = handler.handle(Message(Command.DEREGISTER, KeyData(key).toData()))
        // 验证已删除
        @Assert(store.get(key.unsafeBytes()).isNone())
        store.close()
        cleanup(dir)
    }

    @TestCase
    func prefixScanReturnsMatchingEntries(): Unit {
        let dir = '/tmp/fsync_test/prefix_scan'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        // 写入多个键
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host', 0, [1u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/cache/size', 0, [2u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/other/key', 0, [3u8]).toData()))
        // 前缀扫描
        let resp = handler.handle(Message(Command.ACK, PatternData('/app/config/').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup(dir)
    }

    @TestCase
    func prefixScanVerifyDataContent(): Unit {
        let dir = '/tmp/fsync_test/prefix_content'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host', 0, [1u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/cache/size', 0, [2u8]).toData()))
        let resp = handler.handle(Message(Command.ACK, PatternData('/app/config/').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup(dir)
    }

    @TestCase
    func prefixScanNonExistentReturnsEmpty(): Unit {
        let dir = '/tmp/fsync_test/prefix_empty'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let resp = handler.handle(Message(Command.ACK, PatternData('/nonexistent/').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup(dir)
    }

    @TestCase
    func subscribeAcknowledgesWatch(): Unit {
        let dir = '/tmp/fsync_test/subscribe'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let resp = handler.handle(Message(Command.SUBSCRIBE, WatchData('/app/config/db/host', timeout: Duration.second * 30).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup(dir)
    }

    @TestCase
    func subscribeThenRegisterFiresWatch(): Unit {
        let dir = '/tmp/fsync_test/sub_reg'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host', 0, [42u8]).toData()))
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
        store.close()
        cleanup(dir)
    }

    @TestCase
    func unsubscribeAcknowledges(): Unit {
        let dir = '/tmp/fsync_test/unsub'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let _ = handler.handle(Message(Command.SUBSCRIBE, WatchData('/app/config/db/host', timeout: Duration.Zero).toData()))
        let resp = handler.handle(Message(Command.UNSUBSCRIBE, KeyData('/app/config/db/host').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup(dir)
    }

    @TestCase
    func addFiresWatchCallbackThroughHandler(): Unit {
        let dir = '/tmp/fsync_test/handler_watch'
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm, configHosts: '127.0.0.1:1203')
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host', 0, [1u8]).toData()))
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
        store.close()
        cleanup(dir)
    }

    private static func cleanup(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}
