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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fsync.config.HostAndPort
import fountain::fsync.server.HashRing

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
