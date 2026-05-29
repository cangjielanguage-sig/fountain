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
package fountain::fleet.server

import std.collection.ArrayList
import std.fs.{exists, remove}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.*
import fountain::f_protocol.default.*
import fountain::f_store.Store
import fountain::fleet.base.{HostAndPort, SyncData}

@Test
public class ClusterIntegrationTest {
    private static let dir0 = '/tmp/fleet_cluster/node0'
    private static let dir1 = '/tmp/fleet_cluster/node1'

    @TestCase
    public func simulatePublishReplicatesData(): Unit {
        cleanupAll()
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('127.0.0.1:1203'))
        hosts.add(HostAndPort('127.0.0.1:1204'))

        let store0 = Store(dir0)
        let nm0 = NodeManager(hosts, 0)
        let wm0 = WatchManager()
        let handler0 = SyncHandler(store0, nm0, wm0)

        let store1 = Store(dir1)
        let nm1 = NodeManager(hosts, 1)
        let wm1 = WatchManager()
        let handler1 = SyncHandler(store1, nm1, wm1)

        // 直接写入 Node 0 的 store（绕过 isOwner 检查）
        let key = '/app/cluster/sim'
        let value = [10u8, 20u8, 30u8]
        store0.add(key.unsafeBytes(), value)
        @Assert(store0.get(key.unsafeBytes()).isSome())

        // 模拟 asyncPublish：发送 PUBLISH 到 Node 1
        let pubResp = handler1.handle(Message(Command.PUBLISH(0), SyncData(key, 1, value).toData()))
        @Assert(match (pubResp.command) { case RESP(_) => true case _ => false })

        // 验证 Node 1 收到了数据
        if (let Some(v) <- store1.get(key.unsafeBytes())) {
            @Assert(v.size == value.size)
            @Assert(v[0] == 10u8)
        } else { @Assert(false) }

        store0.close()
        store1.close()
        cleanupAll()
    }

    @TestCase
    public func publishLowerVersionIgnoredByReplica(): Unit {
        cleanupAll()
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('127.0.0.1:1203'))

        let store1 = Store(dir1)
        let nm1 = NodeManager(hosts, 0)
        let wm1 = WatchManager()
        let handler1 = SyncHandler(store1, nm1, wm1)
        let key = '/app/cluster/version'

        // 节点已有版本 100 的数据
        let _ = handler1.handle(Message(Command.REGISTER, SyncData(key, 0, [99u8]).toData()))

        // 低版本 PUBLISH (version=1)
        let pubResp = handler1.handle(Message(Command.PUBLISH(0), SyncData(key, 1, [1u8]).toData()))
        @Assert(match (pubResp.command) { case RESP(_) => true case _ => false })

        // 未被低版本覆盖
        if (let Some(v) <- store1.get(key.unsafeBytes())) {
            @Assert(v[0] == 99u8)
        } else { @Assert(false) }

        store1.close()
        cleanupAll()
    }

    private static func cleanupAll(): Unit {
        for (d in [dir0, dir1]) {
            if (exists(d)) { remove(d, recursive: true) }
        }
    }
}
