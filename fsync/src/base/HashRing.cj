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
package fountain::fsync.base

import std.collection.{ArrayList, TreeMap, HashSet}
import fountain::f_util.{UInt128, murmurHash}

public class HashRing {
    private let ring: TreeMap<UInt128, Int64>
    private let nodes: ArrayList<HostAndPort>
    private let virtualNodes: Int64 = 32

    public init(nodes: ArrayList<HostAndPort>) {
        this.nodes = nodes
        let ring = TreeMap<UInt128, Int64>()
        for (i in 0..nodes.size) {
            for (j in 0..virtualNodes) {
                let token = "${nodes[i].host}:${nodes[i].port}:${j}"
                ring[murmurHash(token)] = i
            }
        }
        this.ring = ring
    }

    public func getNode(key: String): ?HostAndPort {
        let hash = murmurHash(key)
        let entry = ring.forward(hash, inclusive: true).next()
        if (let Some((_, idx)) <- entry) {
            nodes[idx]
        } else if (let Some((_, idx)) <- ring.first) {
            nodes[idx]
        } else {
            None
        }
    }

    public func getNextNode(key: String, exclude: Int64): ?HostAndPort {
        let hash = murmurHash(key)
        let visited = HashSet<Int64>()
        let it = ring.forward(hash, inclusive: true)
        for ((_, idx) in it) {
            if (idx != exclude && visited.add(idx)) {
                return nodes[idx]
            }
        }
        let it2 = ring.forward(ring.first.getOrThrow()[0], inclusive: true)
        for ((_, idx) in it2) {
            if (idx != exclude && visited.add(idx)) {
                return nodes[idx]
            }
            if (visited.size >= nodes.size) {
                break
            }
        }
        None
    }

    public func nodeCount(): Int64 {
        nodes.size
    }

    public func isOwner(key: String, localIndex: Int64): Bool {
        if (let Some(node) <- getNode(key)) {
            node.host == nodes[localIndex].host && node.port == nodes[localIndex].port
        } else {
            false
        }
    }
}
