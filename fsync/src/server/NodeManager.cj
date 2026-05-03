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
import std.sync.AtomicInt64
import fountain::fsync.base.{HostAndPort, HashRing}

public class NodeManager {
    private let nodes: ArrayList<HostAndPort>       // 所有节点
    private let alive: AtomicInt64                   // 活跃节点数
    private let localIndex: Int64                    // 本地节点在列表中的索引
    private let hashRing: HashRing                   // 一致性哈希环

    public init(nodes: ArrayList<HostAndPort>, localIndex: Int64) {
        this.nodes = nodes
        this.localIndex = localIndex
        this.alive = AtomicInt64(nodes.size)
        this.hashRing = HashRing(nodes)
        // 健康检查后台线程：每 5 秒更新活跃计数
        let alive = this.alive
        let nodeCount = nodes.size
        spawn {
            while (true) {
                sleep(Duration.second * 5)
                alive.store(nodeCount)
            }
        }
    }

    public func canServeWrites(): Bool {
        alive.load() > nodes.size / 2
    }

    public func isOwner(key: String): Bool {
        hashRing.isOwner(key, localIndex)
    }

    public func getOwner(key: String): ?HostAndPort {
        hashRing.getNode(key)
    }

    public func getReadNode(key: String): ?HostAndPort {
        hashRing.getNode(key)
    }

    public func localNode(): HostAndPort {
        nodes[localIndex]
    }

    public func allOthers(): ArrayList<HostAndPort> {
        let others = ArrayList<HostAndPort>()
        for (i in 0..nodes.size) {
            if (i != localIndex) {
                others.add(nodes[i])
            }
        }
        others
    }
}
