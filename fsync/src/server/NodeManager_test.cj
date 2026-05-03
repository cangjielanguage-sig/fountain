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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fsync.base.HostAndPort

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
