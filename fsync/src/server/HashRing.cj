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

import std.collection.{ArrayList, TreeMap, HashSet}
import fountain::f_util.{UInt128, murmurHash}
import fountain::fsync.config.HostAndPort

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

    /** 获取 KEY 的 Owner 节点 */
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

    /** 顺时针查找下一可用节点，跳过 exclude 索引 */
    public func getNextNode(key: String, exclude: Int64): ?HostAndPort {
        let hash = murmurHash(key)
        let visited = HashSet<Int64>()
        // 从 hash 开始顺时针迭代
        let it = ring.forward(hash, inclusive: true)
        for ((_, idx) in it) {
            if (idx != exclude && visited.add(idx)) {
                return nodes[idx]
            }
        }
        // 回到环起点继续
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

    /** 节点总数 */
    public func nodeCount(): Int64 {
        nodes.size
    }

    /** 检查本地节点是否为 KEY 的 Owner */
    public func isOwner(key: String, localIndex: Int64): Bool {
        if (let Some(node) <- getNode(key)) {
            node.host == nodes[localIndex].host && node.port == nodes[localIndex].port
        } else {
            false
        }
    }
}
