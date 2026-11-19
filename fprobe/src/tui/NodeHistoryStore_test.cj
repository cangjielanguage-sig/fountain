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
package fountain::fprobe.tui

import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.snapshot.ProbeAgentData

/** 历史仓库：为 TUI 的 Sparkline 提供每个节点、每个指标的定长窗口。 */
@Test
public class NodeHistoryStore_test {
    @TestCase
    public func recordCapsAtCapacityAndDropsOldest(): Unit {
        let store = NodeHistoryStore(60)
        for (i in 0..61) {
            store.record("a", "cpu.usagePercent", Float64(i))
        }
        let values = store.values("a", "cpu.usagePercent")
        @Assert(values.size, 60)
        @Assert(values[0], 1.0)
        @Assert(values[59], 60.0)
    }

    @TestCase
    public func observeRecordsEveryCatalogueProjection(): Unit {
        let store = NodeHistoryStore(10)
        let agent = ProbeAgentData("cpu", "h",
            '{"usagePercent":42.0,"iowaitPercent":1.0,"load1":0.1,"load5":0.2,"load15":0.3,"cores":4}',
            1, "")
        store.observe("a", [agent])
        let usage = store.values("a", "cpu.usagePercent")
        @Assert(usage.size, 1)
        @Assert(usage[0], 42.0)
        @Assert(store.values("a", "cpu.cores").size, 1)
    }

    @TestCase
    public func unknownNodeOrMetricReturnsEmpty(): Unit {
        let store = NodeHistoryStore(10)
        @Assert(store.values("missing", "cpu.usagePercent").isEmpty())
    }
}
