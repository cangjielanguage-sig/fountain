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
package fountain::fprobe.snapshot

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SnapshotStore_test {
    @TestCase
    public func emptyStoreReturnsEmptySnapshot(): Unit {
        let store = SnapshotStore()
        let snapshot = store.collect()
        @Assert(snapshot.node, "")
        @Assert(snapshot.host, "")
        @Assert(snapshot.timestamp, 0)
        @Assert(snapshot.agents.size, 0)
    }

    /** 整体替换：新值覆盖旧值，且一次 collect 读到同一批字段。 */
    @TestCase
    public func replaceSwapsWholeSnapshot(): Unit {
        let store = SnapshotStore()
        store.replace(ProbeSnapshot("node-a", "host-a", 10,
            [ProbeAgentData("cpu", "host-a", '{"v":1}', 10, "")]))
        let first = store.collect()
        @Assert(first.node, "node-a")
        @Assert(first.host, "host-a")
        @Assert(first.timestamp, 10)
        @Assert(first.agents.size, 1)
        @Assert(first.agents[0].kind, "cpu")

        store.replace(ProbeSnapshot("node-b", "host-b", 20,
            [ProbeAgentData("memory", "host-b", '{"v":2}', 20, "")]))
        let second = store.collect()
        @Assert(second.node, "node-b")
        @Assert(second.host, "host-b")
        @Assert(second.timestamp, 20)
        @Assert(second.agents[0].kind, "memory")
    }

    /** 并发写读 100 轮：读到的 node/host/timestamp/agents 必须来自同一批。 */
    @TestCase
    public func concurrentReadersAlwaysSeeConsistentBatch(): Unit {
        let store = SnapshotStore()
        let rounds = 100
        let inconsistent = AtomicInt64(0)
        let writer = spawn { =>
            for (i in 0..rounds) {
                let index = "${i}"
                store.replace(ProbeSnapshot('node-${index}', 'host-${index}', i,
                    [ProbeAgentData("cpu", 'host-${index}', '{"i":${i}}', i, "")]))
            }
        }
        let reader = spawn { =>
            for (_ in 0..rounds) {
                let snapshot = store.collect()
                if (snapshot.node.isEmpty()) {
                    continue
                }
                let expected = 'node-${snapshot.timestamp}'
                let host = 'host-${snapshot.timestamp}'
                let consistent = snapshot.node == expected && snapshot.host == host &&
                    snapshot.agents.size == 1 && snapshot.agents[0].host == host &&
                    snapshot.agents[0].collectedAt == snapshot.timestamp
                if (!consistent) {
                    inconsistent.fetchAdd(1)
                }
            }
        }
        writer.get()
        reader.get()
        @Assert(inconsistent.load(), 0)
    }
}
