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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::f_util.PathPattern
import fountain::fsync.base.{HostAndPort, SyncData, KeyData, ValueData, PatternData, ScanResult, WatchData}

@Test
class ClientOperationsTest {
    private static func setup(dir: String, configHosts!: String = ''): (Store, SyncHandler) {
        cleanup(dir)
        let store = Store(dir)
        let nm = NodeManager(ArrayList<HostAndPort>([HostAndPort('127.0.0.1:1203')]), 0)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm, configHosts: configHosts)
        (store, handler)
    }

    @TestCase
    func testRegisterStoresKeyAndValue(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/register')
        let value = [10u8, 20u8, 30u8]
        let resp = handler.handle(Message(Command.REGISTER, SyncData('/app/key', 0, value).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        if (let Some(stored) <- store.get('/app/key'.unsafeBytes())) {
            @Assert(stored.size == value.size)
        } else { @Assert(false) }
        @Assert(store.get('/app/key_version'.unsafeBytes()).isSome())
        store.close()
        cleanup('/tmp/fsync_op/register')
    }

    @TestCase
    func testGetReturnsValueAfterRegister(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/get')
        let value = [42u8, 43u8, 44u8]
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/key', 0, value).toData()))
        let resp = handler.handle(Message(Command.ACK, KeyData('/app/key').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            if (let Some(v) <- vd.value) {
                @Assert(v.size == value.size)
                @Assert(v[0] == 42u8)
            } else { @Assert(false) }
        } else { @Assert(false) }
        store.close()
        cleanup('/tmp/fsync_op/get')
    }

    @TestCase
    func testGetNonExistentKeyReturnsNone(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/get_none')
        let resp = handler.handle(Message(Command.ACK, KeyData('/app/nonexistent').toData()))
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            @Assert(vd.value.isNone())
        } else { @Assert(false) }
        store.close()
        cleanup('/tmp/fsync_op/get_none')
    }

    @TestCase
    func testDeleteRemovesKey(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/delete')
        let key = '/app/key'
        let _ = handler.handle(Message(Command.REGISTER, SyncData(key, 0, [1u8]).toData()))
        @Assert(store.get(key.unsafeBytes()).isSome())
        let resp = handler.handle(Message(Command.DEREGISTER, KeyData(key).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        @Assert(store.get(key.unsafeBytes()).isNone())
        store.close()
        cleanup('/tmp/fsync_op/delete')
    }

    @TestCase
    func testPrefixScanViaPathPattern(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/prefix')
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/a', 0, [1u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/ab', 0, [2u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/abc', 0, [3u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/other/key', 0, [4u8]).toData()))
        let resp = handler.handle(Message(Command.ACK, PatternData('/app/a').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        let pp = PathPattern()
        pp.compile('/app/a*')
        var matched = 0i64
        for ((k, _) in store.prefix([])) {
            if (pp.matches(String.fromUtf8(k))) { matched++ }
        }
        @Assert(matched >= 3)
        store.close()
        cleanup('/tmp/fsync_op/prefix')
    }

    @TestCase
    func testGlobViaPathPattern(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/glob')
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/db/host.yaml', 0, [1u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/config/cache/size.xml', 0, [2u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/app/a/b/c/host.yaml', 0, [3u8]).toData()))
        let _ = handler.handle(Message(Command.REGISTER, SyncData('/other/app/test.yaml', 0, [4u8]).toData()))
        let resp = handler.handle(Message(Command.ACK, PatternData('/app/**/*.yaml').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        let pp = PathPattern()
        pp.compile('/app/**/*.yaml')
        var matched = 0i64
        var hasConfig = false
        var hasDeep = false
        for ((k, _) in store.prefix([])) {
            let keyStr = String.fromUtf8(k)
            if (pp.matches(keyStr)) {
                matched++
                if (keyStr == '/app/config/db/host.yaml') { hasConfig = true }
                if (keyStr == '/app/a/b/c/host.yaml') { hasDeep = true }
            }
        }
        @Assert(matched == 2)
        @Assert(hasConfig)
        @Assert(hasDeep)
        store.close()
        cleanup('/tmp/fsync_op/glob')
    }

    @TestCase
    func testPingReturnsPong(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/ping')
        let resp = handler.handle(Message(Command.PING(1)))
        @Assert(match (resp.command) { case PING(_) => true case _ => false })
        store.close()
        cleanup('/tmp/fsync_op/ping')
    }

    @TestCase
    func testWatchTimeoutReturnsNone(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/watch')
        let req = Message(Command.SUBSCRIBE, WatchData('/app/key', timeout: Duration.millisecond * 50).toData())
        let resp = handler.handle(req)
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            @Assert(vd.value.isNone())
        } else { @Assert(false) }
        store.close()
        cleanup('/tmp/fsync_op/watch')
    }

    @TestCase
    func testUnwatchRemovesWatch(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/unwatch')
        let _ = handler.handle(Message(Command.SUBSCRIBE, WatchData('/app/key', timeout: Duration.millisecond * 50).toData()))
        let resp = handler.handle(Message(Command.UNSUBSCRIBE, KeyData('/app/key').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        store.close()
        cleanup('/tmp/fsync_op/unwatch')
    }

    @TestCase
    func testConfigQueryReturnsHosts(): Unit {
        let (store, handler) = setup('/tmp/fsync_op/config', configHosts: 'host1:1203,host2:1203')
        let resp = handler.handle(Message(Command.ACK, KeyData('__config__').toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })
        if (let Some(vd) <- convert<ValueData>(resp.data)) {
            if (let Some(v) <- vd.value) {
                let cfg = String.fromUtf8(v)
                @Assert(cfg.contains('host1'))
                @Assert(cfg.contains('host2'))
            } else { @Assert(false) }
        } else { @Assert(false) }
        store.close()
        cleanup('/tmp/fsync_op/config')
    }

    private static func cleanup(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}
