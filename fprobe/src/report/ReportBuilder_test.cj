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
package fountain::fprobe.report

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}
import fountain::fprobe.collect.FakeClock
import fountain::fprobe.collect.topology.TopologySample
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

private func stateOf(node: String, online: Bool, snapshot: ?ProbeSnapshot): NodeState {
    NodeState(node, if (online) {
        NodeStatus.ONLINE
    } else {
        NodeStatus.OFFLINE
    }, if (online) {
        0
    } else {
        3
    }, snapshot, if (online) {
        ""
    } else {
        "timeout"
    }, 10)
}

/** 15.3：HTML 摘要、在线状态、告警统计、关键指标与缺少数据提示。 */
@Test
public class ReportBuilder_test {
    @TestCase
    public func summaryContainsNodesAndMissingDataNote(): Unit {
        let dir = reportTempDir()
        let store = AttachmentStore(dir)
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [10.0, 20.0, 30.0])
        let calls = ArrayList<String>()
        let renderer = ChartRenderer(factory: {_ => FixedChart(FIXED_SVG, calls)})
        let selector = ChartSelector(lookup: {_ => None<String>}, warn: {_ => ()})
        let builder = ReportBuilder(selector, renderer, store, FakeClock(1000))

        let alarm = AlarmEvent(AlarmEventType.FIRING, "web1", "cpu-high", "cpu", "critical",
            Some(95.0), 90.0, 900, "CPU 使用率过高")
        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")]))),
            stateOf("db1", false, None<ProbeSnapshot>)
        ], history, [alarm], None<TopologySample>)

        @Assert(draft.html.contains("web1"))
        @Assert(draft.html.contains("db1"))
        @Assert(draft.html.contains("无数据"))
        @Assert(draft.html.contains("拓扑不可用"))
        @Assert(draft.html.contains("CPU 使用率过高"))
        @Assert(draft.text.contains("web1"))
        @Assert(draft.text.contains("无数据"))
        @Assert(draft.attachments.size, 1)
        @Assert(draft.attachments[0].name, "web1-cpu_usagePercent.svg")
        @Assert(calls.size, 1)

        draft.cleanup()
    }
}
