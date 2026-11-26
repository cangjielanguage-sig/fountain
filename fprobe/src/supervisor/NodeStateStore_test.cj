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
package fountain::fprobe.supervisor

import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.snapshot.ProbeSnapshot

private func onlineState(node: String, updatedAt: Int64): NodeState {
    NodeState(node, NodeStatus.ONLINE, 0, None<ProbeSnapshot>, "", updatedAt)
}

/** 9.4：并发更新与读取，最终状态为最后一次写入。 */
@Test
public class NodeStateStore_test {
    @TestCase
    public func updateReplacesPreviousState(): Unit {
        let store = NodeStateStore()
        @Assert(store.get("a").isNone())
        store.update(onlineState("a", 1))
        @Assert(store.get("a").getOrThrow().updatedAt, 1)
        store.update(onlineState("a", 2))
        @Assert(store.get("a").getOrThrow().updatedAt, 2)
    }

    @TestCase
    public func allReturnsEveryNodeInNameOrder(): Unit {
        let store = NodeStateStore()
        store.update(onlineState("b", 1))
        store.update(onlineState("a", 1))
        let states = store.all()
        @Assert(states.size, 2)
        @Assert(states[0].node, "a")
        @Assert(states[1].node, "b")
    }

    @TestCase
    public func concurrentWritersAndReaderSeeLastWrite(): Unit {
        let store = NodeStateStore()
        let rounds = 1000
        let writerA = spawn { =>
            for (i in 0..rounds) {
                store.update(onlineState("a", i))
            }
        }
        let writerB = spawn { =>
            for (i in 0..rounds) {
                store.update(onlineState("b", i))
            }
        }
        let reader = spawn { =>
            for (_ in 0..rounds) {
                let _ = store.get("a")
                let _ = store.get("b")
                let _ = store.all()
            }
        }
        writerA.get()
        writerB.get()
        reader.get()
        @Assert(store.get("a").getOrThrow().updatedAt, rounds - 1)
        @Assert(store.get("b").getOrThrow().updatedAt, rounds - 1)
    }
}
