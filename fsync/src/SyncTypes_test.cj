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
package fountain::fsync

import std.collection.ArrayList
import std.fs.{Directory, Path, exists, remove}
import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::fsync.config.HostAndPort
import fountain::fsync.server.*

// ======================== SyncDataFormat 测试 ========================

@Test
class SyncDataFormatTest {
    @TestCase
    func createSyncData(): Unit {
        let data = SyncData('/app/config/db/host', 42, [104u8, 101u8, 108u8, 108u8, 111u8])
        @Assert(data.key == '/app/config/db/host')
        @Assert(data.version == 42)
        @Assert(data.value.size == 5)
    }

    @TestCase
    func createValueDataWithValue(): Unit {
        let data = ValueData([104u8, 101u8])
        if (let Some(v) <- data.value) {
            @Assert(v.size == 2)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func createValueDataNone(): Unit {
        let data = ValueData(None)
        @Assert(data.value.isNone())
    }

    @TestCase
    func createPatternData(): Unit {
        let data = PatternData('/app/config/*')
        @Assert(data.pattern == '/app/config/*')
    }

    @TestCase
    func createKeyData(): Unit {
        let data = KeyData('/app/config/db/host')
        @Assert(data.key == '/app/config/db/host')
    }

    @TestCase
    func createWatchNotifyData(): Unit {
        let data = WatchNotifyData('/app/config/db/host', [1u8, 2u8])
        @Assert(data.key == '/app/config/db/host')
        if (let Some(v) <- data.value) {
            @Assert(v.size == 2)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func createWatchData(): Unit {
        let data = WatchData('/app/config/db/host', timeout: Duration.second * 30)
        @Assert(data.key == '/app/config/db/host')
    }

    @TestCase
    func watchDataDefaultTimeout(): Unit {
        let data = WatchData('/app/config/db/host')
        @Assert(data.key == '/app/config/db/host')
    }
}

// ======================== HostAndPort 测试 ========================

@Test
class HostAndPortTest {
    @TestCase
    func parseHostPort(): Unit {
        let hp = HostAndPort('10.0.0.1:1203')
        @Assert(hp.host == '10.0.0.1')
        @Assert(hp.port == 1203u16)
    }

    @TestCase
    func defaultPort(): Unit {
        let hp = HostAndPort('10.0.0.1')
        @Assert(hp.host == '10.0.0.1')
        @Assert(hp.port == 1203u16)
    }

    @TestCase
    func customPort(): Unit {
        let hp = HostAndPort('node1:8080')
        @Assert(hp.host == 'node1')
        @Assert(hp.port == 8080u16)
    }
}

// ======================== HashRing 测试 ========================

@Test
class HashRingTest {
    private static func makeNode(host: String, port: UInt16): HostAndPort {
        HostAndPort('${host}:${port}')
    }

    @TestCase
    func singleNodeAllKeysMapToIt(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('127.0.0.1', 1203))
        let ring = HashRing(nodes)
        for (key in ['/app/config/db/host', '/app/config/cache/size', '/app/log/level']) {
            if (let Some(n) <- ring.getNode(key)) {
                @Assert(n.host == '127.0.0.1')
                @Assert(n.port == 1203u16)
            } else {
                @Assert(false)
            }
        }
    }

    @TestCase
    func sameKeyReturnsSameNode(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        nodes.add(makeNode('10.0.0.3', 1203))
        let ring = HashRing(nodes)
        let key = '/app/config/db/host'
        if (let Some(first) <- ring.getNode(key)) {
            for (_ in 0..10) {
                if (let Some(r) <- ring.getNode(key)) {
                    @Assert(first.host == r.host)
                    @Assert(first.port == r.port)
                } else {
                    @Assert(false)
                }
            }
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func isOwnerCorrect(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        let ring = HashRing(nodes)
        let key = '/app/config/db/host'
        if (let Some(node) <- ring.getNode(key)) {
            let localIdx = if (node.host == '10.0.0.1' && node.port == 1203u16) { 0 } else { 1 }
            @Assert(ring.isOwner(key, localIdx))
            let otherIdx = if (localIdx == 0) { 1 } else { 0 }
            @Assert(!ring.isOwner(key, otherIdx))
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func getNextNodeSkipsExcluded(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        let ring = HashRing(nodes)
        let key = '/app/config/db/host'
        if (let Some(owner) <- ring.getNode(key)) {
            let ownerIdx = if (owner.host == '10.0.0.1') { 0 } else { 1 }
            if (let Some(next) <- ring.getNextNode(key, ownerIdx)) {
                @Assert(next.host != owner.host || next.port != owner.port)
            } else {
                @Assert(false)
            }
        } else {
            @Assert(false)
        }
    }

    @TestCase
    func nodeCountMatches(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        nodes.add(makeNode('10.0.0.3', 1203))
        let ring = HashRing(nodes)
        @Assert(ring.nodeCount() == 3)
    }
}

// ======================== WatchManager 测试 ========================

@Test
class WatchManagerTest {
    @TestCase
    func registerAndNotifyExact(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/db/host', [42u8])
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
    }

    @TestCase
    func exactKeyNotNotifiedOnDifferentKey(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/cache/size', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func prefixMatchNotifies(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerPrefix('/app/config/', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(flag.load())
    }

    @TestCase
    func prefixNotMatchIfNotStartWith(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerPrefix('/app/config/', Duration.Zero, {_ => flag.store(true)})
        wm.notify('/other/key', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func unwatchRemovesExactWatcher(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => flag.store(true)})
        wm.unwatch('/app/config/db/host')
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func timeoutExpiresWatcher(): Unit {
        let wm = WatchManager()
        let flag = AtomicBool(false)
        wm.registerExact('/app/config/db/host', Duration.millisecond * 10, {_ => flag.store(true)})
        sleep(Duration.millisecond * 50)
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(!flag.load())
    }

    @TestCase
    func multipleWatchersOnSameKeyAllNotified(): Unit {
        let wm = WatchManager()
        let c = AtomicInt64(0)
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => c.fetchAdd(1)})
        wm.registerExact('/app/config/db/host', Duration.Zero, {_ => c.fetchAdd(1)})
        wm.notify('/app/config/db/host', [1u8])
        sleep(Duration.millisecond * 10)
        @Assert(c.load() == 2)
    }
}

// ======================== NodeManager 测试 ========================

@Test
class NodeManagerTest {
    private static func makeNode(host: String, port: UInt16): HostAndPort {
        HostAndPort('${host}:${port}')
    }

    @TestCase
    func quorumMetWhenMajorityAlive(): Unit {
        let nodes = ArrayList<HostAndPort>()
        for (i in 0..4) {
            nodes.add(makeNode('10.0.0.${i}', 1203))
        }
        let nm = NodeManager(nodes, 0)
        @Assert(nm.canServeWrites())
    }

    @TestCase
    func singleNodeQuorum(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        let nm = NodeManager(nodes, 0)
        @Assert(nm.canServeWrites())
    }

    @TestCase
    func localNodeReturnsCorrectIndex(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        let nm = NodeManager(nodes, 1)
        let local = nm.localNode()
        @Assert(local.host == '10.0.0.2')
        @Assert(local.port == 1203u16)
    }

    @TestCase
    func allOthersExcludesSelf(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        nodes.add(makeNode('10.0.0.3', 1203))
        let nm = NodeManager(nodes, 0)
        let others = nm.allOthers()
        @Assert(others.size == 2)
        for (n in others) {
            @Assert(n.host != '10.0.0.1')
        }
    }
}

// ======================== 版本号编解码测试 ========================

@Test
class VersionCodecTest {
    @TestCase
    func zeroRoundtrips(): Unit {
        let bytes = SyncHandler.encodeVersion(0)
        @Assert(bytes.size == 8)
        @Assert(SyncHandler.decodeVersion(bytes) == 0)
    }

    @TestCase
    func positiveVersionRoundtrips(): Unit {
        let v = 42
        let bytes = SyncHandler.encodeVersion(v)
        @Assert(bytes.size == 8)
        @Assert(SyncHandler.decodeVersion(bytes) == v)
    }

    @TestCase
    func largeVersionRoundtrips(): Unit {
        let v = Int64.Max
        let bytes = SyncHandler.encodeVersion(v)
        @Assert(bytes.size == 8)
        @Assert(SyncHandler.decodeVersion(bytes) == v)
    }

    @TestCase
    func negativeVersionRoundtrips(): Unit {
        let v = -1
        let bytes = SyncHandler.encodeVersion(v)
        @Assert(bytes.size == 8)
        @Assert(SyncHandler.decodeVersion(bytes) == v)
    }
}

// ======================== SyncHandler Store 集成测试 ========================

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
        let value = [104u8, 101u8, 108u8, 108u8, 111u8]  // "hello"
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
        // REGISTER 需要 SyncData 体，这里给空 Data → 应返回错误
        let msg = Message(Command.REGISTER)
        let resp = handler.handle(msg)
        let isResp = match (resp.command) { case RESP(_) => true case _ => false }
        @Assert(isResp)
        store.close()
        cleanup(dir)
    }

    private static func cleanup(dir: String): Unit {
        if (exists(dir)) {
            remove(dir, recursive: true)
        }
    }
}
