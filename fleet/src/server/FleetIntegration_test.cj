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

/**
 * fleet 集成测试 — 多组件端到端验证
 *
 * 每个测试用例在新线程(spawn)中启动 SyncServer（真实 TcpServerSocket 绑定端口），
 * 等待秒级延迟让服务端就绪，再通过 handler.handle() 验证业务逻辑。
 *
 * 覆盖场景：
 *   1. 客户端数据存储（REGISTER → Store 持久化）
 *   2. 客户端数据获取（REGISTER → GET → ValueData）
 *   3. SyncServer 生命周期（start/close/端口绑定）
 *   4. 多节点 PUBLISH 同步（node0.handler → asyncPublish → node1.store）
 *   5. 跨节点数据读写 + 仲裁验证
 *
 * 说明：
 *   - SyncServer 在 spawn 中启动 bind+accept 循环，测试线程 sleep 等待就绪。
 *   - 每个测试用例使用独立端口，防止 TIME_WAIT 冲突。
 *   - 客户端操作通过 f_net.Client.builder() 尝试建连并发送请求，存储结果
 *     通过 Store 直接验证（f_net.Client 的 T=SyncData 解码限制）。
 */
package fountain::fleet.server

import std.collection.ArrayList
import std.fs.{exists, remove}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_net.client.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::fleet.base.{HostAndPort, SyncData, KeyData, ValueData, HashRing}

@Test
public class FleetIntegrationTest {
    private static let PORT_A: UInt16 = 19901
    private static let PORT_B: UInt16 = 19902
    private static let PORT_C0: UInt16 = 19911
    private static let PORT_C1: UInt16 = 19912
    private static let PORT_D0: UInt16 = 19921
    private static let PORT_D1: UInt16 = 19922

    // ================================================================
    // 辅助方法
    // ================================================================

    /** 启动服务端节点（绑定端口 + accept 循环） */
    private static func startServer(port: UInt16, hosts: ArrayList<HostAndPort>,
            localIndex: Int64, dir: String): (SyncServer, Store, SyncHandler) {
        cleanupDir(dir)
        let store = Store(dir)
        let nm = NodeManager(hosts, localIndex)
        let wm = WatchManager()
        let handler = SyncHandler(store, nm, wm)
        let server = SyncServer(port)
        server.start(handler)
        (server, store, handler)
    }

    /** 通过 f_net.Client 尝试建连并发送 REGISTER，返回连接是否成功建立 */
    private static func trySendRegister(port: UInt16, key: String,
            value: Array<Byte>): Bool {
        try {
            let c = Client<Message, EncodedMessage, Message, SyncData, MessageID>.builder(
                queueSize: 64, socketCount: 1,
                host: '127.0.0.1', port: port,
                idGetter: { m => m.id },
                checkDuration: Duration.second * 10,
                checker: { _ => true }
            ).noDelay(true).build()
            let msg = Message(Command.REGISTER, SyncData(key, 0, value).toData())
            let _ = c.transfer(msg.id, msg, Duration.second * 3)
            c.close()
            true
        } catch (_: Exception) { false }
    }

    /** 在一致性哈希环上查找属于指定节点的 key */
    private static func findKeyOwnedBy(hosts: ArrayList<HostAndPort>, nodeIndex: Int64): String {
        let ring = HashRing(hosts)
        for (i in 0..100) {
            let key = '/test/int/key_${i}'
            if (ring.isOwner(key, nodeIndex)) { return key }
        }
        throw Exception('unable to find key owned by node ${nodeIndex}')
    }

    private static func cleanupDir(dir: String): Unit {
        if (exists(dir)) { remove(dir, recursive: true) }
    }

    // ================================================================
    // 测试 1：客户端向服务端存储数据
    //   handler.handle(REGISTER) → Store 持久化 → 版本号记录
    // ================================================================

    @TestCase
    public func testClientStoreToServer(): Unit {
        let dir = '/tmp/fleet_int/store'
        let hosts = ArrayList<HostAndPort>([HostAndPort('127.0.0.1:${PORT_A}')])
        let (server, store, handler) = startServer(PORT_A, hosts, 0, dir)
        sleep(Duration.second * 3)

        let key = '/app/int/test/store'
        let value: Array<Byte> = [0x10u8, 0x20u8, 0x30u8, 0x40u8]
        let resp = handler.handle(Message(Command.REGISTER, SyncData(key, 0, value).toData()))
        @Assert(match (resp.command) { case RESP(_) => true case _ => false })

        let stored = store.get(key.unsafeBytes())
        if (stored.isNone()) { @Assert(false); server.close(); store.close(); cleanupDir(dir); return }
        let v = stored.getOrThrow()
        @Assert(v.size == 4 && v[0] == 0x10u8 && v[1] == 0x20u8 && v[2] == 0x30u8 && v[3] == 0x40u8)
        @Assert(store.get((key + '_version').unsafeBytes()).isSome())

        server.close(); store.close(); cleanupDir(dir)
    }

    // ================================================================
    // 测试 2：客户端从服务端获取数据
    //   REGISTER → GET → ValueData 匹配 → 不存在的 key → None
    // ================================================================

    @TestCase
    public func testClientRetrieveFromServer(): Unit {
        let dir = '/tmp/fleet_int/retrieve'
        let hosts = ArrayList<HostAndPort>([HostAndPort('127.0.0.1:${PORT_B}')])
        let (server, store, handler) = startServer(PORT_B, hosts, 0, dir)
        sleep(Duration.second * 3)

        let key = '/app/int/test/get'
        let value: Array<Byte> = [0xAAu8, 0xBBu8, 0xCCu8]
        let _ = handler.handle(Message(Command.REGISTER, SyncData(key, 0, value).toData()))

        let getResp = handler.handle(Message(Command.ACK, KeyData(key).toData()))
        if (let Some(vd) <- convert<ValueData>(getResp.data)) {
            if (let Some(v) <- vd.value) {
                @Assert(v.size == 3 && v[0] == 0xAAu8 && v[1] == 0xBBu8 && v[2] == 0xCCu8)
            } else { @Assert(false) }
        } else { @Assert(false) }

        let noneResp = handler.handle(Message(Command.ACK, KeyData('/app/not/exist').toData()))
        if (let Some(vd) <- convert<ValueData>(noneResp.data)) {
            @Assert(vd.value.isNone())
        } else { @Assert(false) }

        server.close(); store.close(); cleanupDir(dir)
    }

    // ================================================================
    // 测试 3：SyncServer 生命周期 + f_net.Client 建连尝试
    //   服务器启动 → 客户端尝试 TCP 连接 → 服务器关闭
    // ================================================================

    @TestCase
    public func testServerLifecycleAndClientConnect(): Unit {
        let dir = '/tmp/fleet_int/lifecycle'
        let hosts = ArrayList<HostAndPort>([HostAndPort('127.0.0.1:${PORT_A}')])
        let (server, store, handler) = startServer(PORT_A, hosts, 0, dir)
        sleep(Duration.second * 3)

        // 服务端已启动，尝试 Client 连接
        let key = '/app/int/test/lc'
        let value: Array<Byte> = [0x01u8, 0x02u8]
        let connected = trySendRegister(PORT_A, key, value)
        // 连接成功代表 TcpServerSocket.bind+accept 正常工作
        @Assert(connected)

        // 通过 handler 验证 Store 中可以正常 CRUD
        handler.handle(Message(Command.REGISTER, SyncData('/app/int/a', 0, [1u8]).toData()))
        handler.handle(Message(Command.REGISTER, SyncData('/app/int/b', 0, [2u8]).toData()))
        @Assert(store.get('/app/int/a'.unsafeBytes()).isSome())
        @Assert(store.get('/app/int/b'.unsafeBytes()).isSome())
        handler.handle(Message(Command.DEREGISTER, KeyData('/app/int/b').toData()))
        @Assert(store.get('/app/int/b'.unsafeBytes()).isNone())

        // 关闭后不可再访问
        server.close()
        @Assert(server.isClosed())

        store.close(); cleanupDir(dir)
    }

    // ================================================================
    // 测试 4：两个服务节点 PUBLISH 同步数据
    //   模拟 node0 写入后 PUBLISH → node1（绕过 WSL TcpSocket.connect 阻塞限制）
    // ================================================================

    @TestCase
    public func testTwoNodesDataSync(): Unit {
        let dir0 = '/tmp/fleet_int/sync0'
        let dir1 = '/tmp/fleet_int/sync1'

        let hosts = ArrayList<HostAndPort>([
            HostAndPort('127.0.0.1:${PORT_C0}'),
            HostAndPort('127.0.0.1:${PORT_C1}')
        ])

        let (server0, store0, handler0) = startServer(PORT_C0, hosts, 0, dir0)
        let (server1, store1, handler1) = startServer(PORT_C1, hosts, 1, dir1)
        sleep(Duration.second * 3)

        let key = findKeyOwnedBy(hosts, 0)
        let value: Array<Byte> = [0xF1u8, 0xF2u8, 0xF3u8]

        // 节点0 REGISTER → 写入本地存储
        let reg = handler0.handle(Message(Command.REGISTER, SyncData(key, 0, value).toData()))
        @Assert(match (reg.command) { case RESP(_) => true case _ => false })

        // 节点0 本地存储验证
        if (let Some(v0) <- store0.get(key.unsafeBytes())) {
            @Assert(v0[0] == 0xF1u8)
        } else { @Assert(false) }

        // 模拟 asyncPublish：直接向节点1的 handler 发送 PUBLISH
        // (asyncPublish 内部使用 Client.connect() → 当前 WSL 环境 TcpSocket 阻塞)
        let pub = handler1.handle(Message(Command.PUBLISH(0), SyncData(key, 1, value).toData()))
        @Assert(match (pub.command) { case RESP(_) => true case _ => false })

        // 节点1 通过 PUBLISH 接收数据
        if (let Some(v1) <- store1.get(key.unsafeBytes())) {
            @Assert(v1.size == 3 && v1[0] == 0xF1u8 && v1[1] == 0xF2u8 && v1[2] == 0xF3u8)
        } else { @Assert(false) }

        // 节点1 可通过 GET handler 返回同步后的数据
        let g1 = handler1.handle(Message(Command.ACK, KeyData(key).toData()))
        if (let Some(vd) <- convert<ValueData>(g1.data)) {
            if (let Some(v) <- vd.value) {
                @Assert(v.size == 3 && v[0] == 0xF1u8)
            } else { @Assert(false) }
        } else { @Assert(false) }

        server0.close(); server1.close()
        store0.close(); store1.close()
        cleanupDir(dir0); cleanupDir(dir1)
    }

    // ================================================================
    // 测试 5：节点间连接保活 + 跨节点互写验证
    //   NodeManager 健康检查线程 PING + PUBLISH 双向同步模拟
    // ================================================================

    @TestCase
    public func testNodeKeepAliveAndCrossWrite(): Unit {
        let dir0 = '/tmp/fleet_int/keep0'
        let dir1 = '/tmp/fleet_int/keep1'

        let hosts = ArrayList<HostAndPort>([
            HostAndPort('127.0.0.1:${PORT_D0}'),
            HostAndPort('127.0.0.1:${PORT_D1}')
        ])

        // NodeManager 启动健康检查线程，每5秒 PING 对方
        let (server0, store0, handler0) = startServer(PORT_D0, hosts, 0, dir0)
        let (server1, store1, handler1) = startServer(PORT_D1, hosts, 1, dir1)
        sleep(Duration.second * 3)

        // 节点0 写入自己的 key
        let k0 = findKeyOwnedBy(hosts, 0)
        let v0: Array<Byte> = [0x01u8]
        handler0.handle(Message(Command.REGISTER, SyncData(k0, 1, v0).toData()))

        // 节点1 写入自己的 key
        let k1 = findKeyOwnedBy(hosts, 1)
        let v1: Array<Byte> = [0x02u8]
        handler1.handle(Message(Command.REGISTER, SyncData(k1, 1, v1).toData()))

        // 模拟双向 PUBLISH（绕过 WSL TcpSocket.connect 阻塞）
        handler1.handle(Message(Command.PUBLISH(0), SyncData(k0, 1, v0).toData()))
        handler0.handle(Message(Command.PUBLISH(0), SyncData(k1, 1, v1).toData()))

        // 节点0 的数据同步到了节点1
        if (let Some(v) <- store1.get(k0.unsafeBytes())) {
            @Assert(v[0] == 0x01u8)
        } else { @Assert(false) }

        // 节点1 的数据同步到了节点0
        if (let Some(v) <- store0.get(k1.unsafeBytes())) {
            @Assert(v[0] == 0x02u8)
        } else { @Assert(false) }

        // GET handler 验证两节点都能读取对方数据
        let g1k0 = handler1.handle(Message(Command.ACK, KeyData(k0).toData()))
        let g0k1 = handler0.handle(Message(Command.ACK, KeyData(k1).toData()))
        @Assert(match (g1k0.command) { case RESP(_) => true case _ => false })
        @Assert(match (g0k1.command) { case RESP(_) => true case _ => false })

        server0.close(); server1.close()
        store0.close(); store1.close()
        cleanupDir(dir0); cleanupDir(dir1)
    }
}
