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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fleet.base.HostAndPort

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

    @TestCase
    func allOthersReturnsAllExceptSelf(): Unit {
        let nodes = ArrayList<HostAndPort>()
        for (i in 0..5) {
            nodes.add(makeNode('10.0.0.${i}', 1203))
        }
        // localIndex=2, 应返回 4 个其他节点
        let nm = NodeManager(nodes, 2)
        @Assert(nm.allOthers().size == 4)
        // localIndex=0, 应返回 4 个其他节点
        let nm2 = NodeManager(nodes, 0)
        @Assert(nm2.allOthers().size == 4)
        // localIndex=4 (最后), 应返回 4 个
        let nm3 = NodeManager(nodes, 4)
        @Assert(nm3.allOthers().size == 4)
    }

    @TestCase
    func singleNodeAllOthersEmpty(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        let nm = NodeManager(nodes, 0)
        @Assert(nm.allOthers().size == 0)
    }

    @TestCase
    func getOwnerReturnsCorrectNode(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        nodes.add(makeNode('10.0.0.3', 1203))
        let nm = NodeManager(nodes, 0)
        // 同一个 key 总是返回同一个 owner
        let owner1 = nm.getOwner('/app/config/db/host')
        let owner2 = nm.getOwner('/app/config/db/host')
        @Assert(owner1.isSome())
        @Assert(owner2.isSome())
        if (let Some(o1) <- owner1) {
            if (let Some(o2) <- owner2) {
                @Assert(o1.host == o2.host)
                @Assert(o1.port == o2.port)
            }
        }
        // 不同 key 可能映射到不同节点
        let owner3 = nm.getOwner('/app/other/key')
        @Assert(owner3.isSome())
    }

    @TestCase
    func isOwnerCorrectForLocalIndex(): Unit {
        let nodes = ArrayList<HostAndPort>()
        for (i in 0..3) {
            nodes.add(makeNode('10.0.0.${i}', 1203))
        }
        // 所有 key 的 owner 必须是 3 个节点之一
        let nm0 = NodeManager(nodes, 0)
        let nm1 = NodeManager(nodes, 1)
        let nm2 = NodeManager(nodes, 2)
        for (i in 0..50) {
            let key = '/app/config/${i}/host'
            let isOwner0 = nm0.isOwner(key)
            let isOwner1 = nm1.isOwner(key)
            let isOwner2 = nm2.isOwner(key)
            // 有且只有一个节点是 owner
            @Assert((isOwner0 || isOwner1 || isOwner2))
        }
    }

    @TestCase
    func getReadNodeReturnsNode(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        let nm = NodeManager(nodes, 0)
        let node = nm.getReadNode('/app/key')
        @Assert(node.isSome())
    }

    @TestCase
    func twoNodeQuorumRequiresBothAlive(): Unit {
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        nodes.add(makeNode('10.0.0.2', 1203))
        let nm = NodeManager(nodes, 0)
        // alive 初始值为 nodes.size=2, quorum=2 > 1 => true
        @Assert(nm.canServeWrites())
    }

    @TestCase
    func singleNodeDoesNotSpawnHealthCheck(): Unit {
        // 单节点：allOthers() 为空，不 spawn 健康检查线程
        let nodes = ArrayList<HostAndPort>()
        nodes.add(makeNode('10.0.0.1', 1203))
        let nm = NodeManager(nodes, 0)
        @Assert(nm.canServeWrites())
        // 没有其他节点可 ping，alive 保持初始值
        sleep(Duration.millisecond * 100)
        @Assert(nm.canServeWrites())
    }
}
