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
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

/** 固定长度的历史替身，用来断言 Sparkline 数据长度来自历史窗口。 */
class FixedHistory <: HistorySource {
    private let points: Array<Float64>

    init(size: Int64) {
        this.points = Array<Float64>(size, {i => Float64(i)})
    }

    public func values(_: String, _: String): Array<Float64> {
        points
    }
}

func cpuState(node: String, usagePercent: Float64): NodeState {
    let dataJson = '{"usagePercent":${usagePercent},"iowaitPercent":1.5,' +
        '"load1":0.5,"load5":0.4,"load15":0.3,"cores":8}'
    let snapshot = ProbeSnapshot(node, "${node}-host", 1000,
        [ProbeAgentData("cpu", "${node}-host", dataJson, 1000, "")])
    NodeState(node, NodeStatus.ONLINE, 0, Some(snapshot), "", 1000)
}


func topologyState(node: String): NodeState {
    let dataJson = '{"devices":[{"name":"sw1","host":"10.0.0.1","ports":["Gi0/1","Gi0/2"]}],' +
        '"links":[{"from":"sw1","to":"sw2","localPort":"Gi0/1","remotePort":"Gi0/2"}],"error":""}'
    let snapshot = ProbeSnapshot(node, "${node}-host", 1000,
        [ProbeAgentData("topology", "${node}-host", dataJson, 1000, "")])
    NodeState(node, NodeStatus.ONLINE, 0, Some(snapshot), "", 1000)
}

/** 12.2：RenderPlan 是纯数据，行数、列数与序列长度都可直接断言。 */
@Test
public class RenderPlan_test {
    @TestCase
    public func planCarriesNodeRowsMetricColumnsAndHistorySeries(): Unit {
        let states = [cpuState("a", 12.5), cpuState("b", 3.0)]
        let view = ViewModel(["a", "b"], 0, 0, 1)
        let plan = RenderPlanBuilder.build(view, states, FixedHistory(60), 5000, ["alarm-1"])

        @Assert(plan.nodeRows.size, 2)
        @Assert(plan.selectedIndex, 0)
        @Assert(plan.selectedNode, "a")
        @Assert(plan.pageTitle, "CPU")
        @Assert(plan.metricRows.size, ProjectionCatalog.specs(MetricPage.CPU).size)
        for (row in plan.metricRows) {
            @Assert(row.size, 2)
        }
        @Assert(plan.series.size, ProjectionCatalog.specs(MetricPage.CPU).size)
        @Assert(plan.series[0].values.size, 60)
        @Assert(plan.title.contains("节点 2"))
        @Assert(plan.title.contains("告警 1"))
        @Assert(plan.alarmRows.size, 1)
        @Assert(plan.note.isEmpty())
    }

    @TestCase
    public func selectedRowIsMarked(): Unit {
        let states = [cpuState("a", 1.0), cpuState("b", 2.0)]
        let plan = RenderPlanBuilder.build(ViewModel(["a", "b"], 1, 0, 0), states,
            FixedHistory(10), 1, [])
        @Assert(plan.selectedIndex, 1)
        @Assert(plan.nodeRows[1].contains("b"))
        @Assert(!plan.nodeRows[1].startsWith(" "))
        @Assert(plan.nodeRows[0].startsWith(" "))
    }

    @TestCase
    public func missingKindProducesNoteAndPlaceholderRows(): Unit {
        let snapshot = ProbeSnapshot("a", "a-host", 1, [])
        let state = NodeState("a", NodeStatus.ONLINE, 0, Some(snapshot), "", 1)
        let plan = RenderPlanBuilder.build(ViewModel(["a"], 0, 0, 0), [state],
            FixedHistory(5), 1, [])
        @Assert(plan.note.contains("cpu"))
        @Assert(plan.metricRows.size, ProjectionCatalog.specs(MetricPage.CPU).size)
        @Assert(plan.metricRows[0][1], "--")
    }

    @TestCase
    public func offlineNodeWithoutSnapshotShowsNoData(): Unit {
        let state = NodeState("a", NodeStatus.OFFLINE, 2, None<ProbeSnapshot>, "连接失败", 1)
        let plan = RenderPlanBuilder.build(ViewModel(["a"], 0, 0, 0), [state],
            FixedHistory(5), 1, [])
        @Assert(plan.note.contains("暂无数据"))
        @Assert(plan.nodeRows[0].contains("离线"))
    }

    @TestCase
    public func alarmPageRendersAlarmLinesInTwoColumns(): Unit {
        let view = ViewModel.empty().showAlarms()
        let plan = RenderPlanBuilder.build(view, [], FixedHistory(0), 1, ["alarm-1", "alarm-2"])
        @Assert(plan.pageTitle, "告警")
        @Assert(plan.metricRows.size, 2)
        for (row in plan.metricRows) {
            @Assert(row.size, 2)
        }
        @Assert(plan.series.isEmpty())
    }

    @TestCase
    public func configuredNodeWithoutStateIsShownAsWaiting(): Unit {
        let plan = RenderPlanBuilder.build(ViewModel(["a", "b"], 0, 0, 0),
            [cpuState("a", 1.0)], FixedHistory(5), 1, [])
        @Assert(plan.nodeRows.size, 2)
        @Assert(plan.nodeRows[1].contains("等待"))
        @Assert(plan.title.contains("节点 2"))
    }

    @TestCase
    public func agentErrorBecomesNote(): Unit {
        let snapshot = ProbeSnapshot("a", "a-host", 1,
            [ProbeAgentData("cpu", "a-host", "{}", 1, "读取 /proc/stat 失败")])
        let state = NodeState("a", NodeStatus.ONLINE, 0, Some(snapshot), "", 1)
        let plan = RenderPlanBuilder.build(ViewModel(["a"], 0, 0, 0), [state],
            FixedHistory(5), 1, [])
        @Assert(plan.note.contains("/proc/stat"))
    }

    /** 拓扑页：设备与链路以文本行展示，而不是空表。 */
    @TestCase
    public func topologyPageShowsDevicesAndLinks(): Unit {
        let view = ViewModel(["n1"], 0, 6, 0)
        let plan = RenderPlanBuilder.build(view, [topologyState("n1")], EmptyHistorySource(), 1000, [])
        @Assert(plan.pageTitle, "拓扑")
        @Assert(plan.metricRows.size, 2)
        @Assert(plan.metricRows[0][0], "设备 sw1(10.0.0.1)")
        @Assert(plan.metricRows[0][1], "Gi0/1,Gi0/2")
        @Assert(plan.metricRows[1][0], "链路 sw1:Gi0/1")
        @Assert(plan.metricRows[1][1], "sw2:Gi0/2")
        @Assert(plan.series.isEmpty())
    }
}
