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
import fountain::f_chart.Chart
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}
import fountain::fprobe.collect.FakeClock
import fountain::fprobe.collect.topology.{TopologyDevice, TopologyLink, TopologySample}
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

/** 统计固定子串出现次数（按字节推进，避免重复匹配）。 */
private func countOf(text: String, needle: String): Int64 {
    let step = needle.toArray().size
    var count = 0
    var rest = text
    while (true) {
        match (rest.indexOf(needle)) {
            case Some(index) =>
                count += 1
                rest = rest[index + step..]
            case None => break
        }
    }
    count
}

private func fixedRenderer(svg: String, calls: ArrayList<String>): ChartRenderer {
    ChartRenderer(factory: {_ => FixedChart(svg, calls)})
}

private func plainSelector(): ChartSelector {
    ChartSelector(lookup: {_ => None<String>}, warn: {_ => ()})
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
        let renderer = fixedRenderer(FIXED_SVG, calls)
        let builder = ReportBuilder(plainSelector(), renderer, store, FakeClock(1000))

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
        @Assert(draft.html.contains("<svg"))
        @Assert(draft.html.contains("<div class=\"fprobe-chart\">"))
        @Assert(draft.html.contains("<h4>web1 使用率 (cpu.usagePercent)：30.000000 %</h4>"))
        @Assert(!draft.html.contains("<?xml"))
        @Assert(!draft.html.contains("web1-cpu_usagePercent.svg"))
        @Assert(draft.text.contains("web1"))
        @Assert(draft.text.contains("无数据"))
        @Assert(draft.attachments.size, 1)
        @Assert(calls.size, 1)

        draft.cleanup()
    }

    /** 1.2：内联前剥掉 XML 声明，未带声明的 SVG 逐字节保留。 */
    @TestCase
    public func inlineChartStripsXmlDeclaration(): Unit {
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [10.0, 20.0])
        let calls = ArrayList<String>()
        let builder = ReportBuilder(plainSelector(), fixedRenderer(XML_SVG, calls),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":20.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(draft.html.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(!draft.html.contains("<?xml"))
        @Assert(!draft.html.contains("?>"))
        @Assert(draft.html.contains("<rect width=\"10\" height=\"10\"/>"))

        draft.cleanup()
    }

    @TestCase
    public func chartWithoutXmlDeclarationIsEmbeddedVerbatim(): Unit {
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [10.0, 20.0])
        let calls = ArrayList<String>()
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, calls),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":20.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(draft.html.contains(FIXED_SVG))
        @Assert(draft.html.contains("</h4>${FIXED_SVG}</div>"))
        @Assert(!draft.html.contains("<?xml"))

        draft.cleanup()
    }

    @TestCase
    public func malformedXmlDeclarationIsKeptVerbatim(): Unit {
        let broken = "<?xml version=\"1.0\""
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [10.0, 20.0])
        let calls = ArrayList<String>()
        let builder = ReportBuilder(plainSelector(), fixedRenderer(broken, calls),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":20.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(draft.html.contains(broken))
        @Assert(countOf(draft.html, "<div class=\"fprobe-chart\">"), 1)

        draft.cleanup()
    }

    /** 1.3：每个成功图表一个 `div.fprobe-chart`，标题含节点、指标与当前值。 */
    @TestCase
    public func chartBlockCarriesHeadingWithValue(): Unit {
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [10.0, 95.0])
        let calls = ArrayList<String>()
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, calls),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(countOf(draft.html, "<div class=\"fprobe-chart\">"), 1)
        @Assert(draft.html.contains(
            "<h4>web1 使用率 (cpu.usagePercent)：95.000000 %</h4>"))
        @Assert(!draft.html.contains("<p>使用率 (cpu.usagePercent): 95.000000 %</p>"))
        @Assert(!draft.html.contains("web1-cpu_usagePercent.svg"))

        draft.cleanup()
    }

    /** 1.4：单图失败退化为纯文本行，其余图表照常内联。 */
    @TestCase
    public func failedChartFallsBackToTextLine(): Unit {
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [95.0])
        history.set("web1", "cpu.iowaitPercent", [5.0])
        let calls = ArrayList<String>()
        let renderer = ChartRenderer(factory: {chartType =>
            let chart: Chart = if (chartType == "bar") {
                ThrowingChart()
            } else {
                FixedChart(FIXED_SVG, calls)
            }
            chart
        })
        let selector = ChartSelector(lookup: {key =>
            if (key == "probe_chart_cpu_iowaitPercent") {
                Some("bar")
            } else {
                None<String>
            }
        }, warn: {_ => ()})
        let warnings = ArrayList<String>()
        let builder = ReportBuilder(selector, renderer, AttachmentStore(reportTempDir()),
            FakeClock(1000), logWarning: {message => warnings.add(message)})

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(draft.html.contains("<p>iowait (cpu.iowaitPercent): 5.000000 %</p>"))
        @Assert(countOf(draft.html, "<div class=\"fprobe-chart\">"), 1)
        @Assert(draft.html.contains("<h4>web1 使用率 (cpu.usagePercent)：95.000000 %</h4>"))
        @Assert(warnings.size, 1)
        @Assert(warnings[0].contains("图表生成失败 web1 cpu.iowaitPercent"))
        @Assert(calls.size, 1)

        draft.cleanup()
    }

    /** 1.5：拓扑进入独立小节并内联，纯文本给出设备与链路数。 */
    @TestCase
    public func topologyIsInlinedInOwnSection(): Unit {
        let sample = TopologySample([
            TopologyDevice("sw-a", "10.0.0.1", ["eth0"]),
            TopologyDevice("sw-b", "10.0.0.2", ["eth1"])
        ], [TopologyLink("sw-a", "sw-b", "eth0", "eth1")], "")
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, ArrayList<String>()),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], FakeHistory(), [], Some(sample))

        @Assert(draft.html.contains("<h2>拓扑</h2>"))
        @Assert(countOf(draft.html, "<div class=\"fprobe-topology\">"), 1)
        @Assert(draft.html.contains("<svg"))
        @Assert(draft.text.contains("拓扑: 已内联（2 个设备 / 1 条链路）"))
        @Assert(!draft.html.contains("topology.svg"))
        @Assert(!draft.text.contains("topology.svg"))

        draft.cleanup()
    }

    @TestCase
    public func missingTopologyStaysUnavailable(): Unit {
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, ArrayList<String>()),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], FakeHistory(), [], None<TopologySample>)

        @Assert(draft.html.contains("<p>拓扑不可用</p>"))
        @Assert(draft.text.contains("拓扑不可用"))
        @Assert(countOf(draft.html, "<div class=\"fprobe-topology\">"), 0)

        draft.cleanup()
    }

    /** 1.6：节点名只进入转义后的标题，不构成 HTML 标记。 */
    @TestCase
    public func nodeNameIsEscapedInHeading(): Unit {
        let node = "web1<img src=x onerror=alert(1)>"
        let history = FakeHistory()
        history.set(node, "cpu.usagePercent", [95.0])
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, ArrayList<String>()),
            AttachmentStore(reportTempDir()), FakeClock(1000))

        let draft = builder.build([
            stateOf(node, true, Some(ProbeSnapshot(node, "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(draft.html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        @Assert(!draft.html.contains("<img src=x"))
        @Assert(countOf(draft.html, "<div class=\"fprobe-chart\">"), 1)

        draft.cleanup()
    }

    /** 1.7：结尾日志给出图表数与 HTML 字节数，不再出现批次目录。 */
    @TestCase
    public func buildLogsChartCountAndHtmlBytes(): Unit {
        let dir = reportTempDir()
        let history = FakeHistory()
        history.set("web1", "cpu.usagePercent", [1.0])
        history.set("web1", "cpu.iowaitPercent", [2.0])
        let logs = ArrayList<String>()
        let builder = ReportBuilder(plainSelector(), fixedRenderer(FIXED_SVG, ArrayList<String>()),
            AttachmentStore(dir), FakeClock(1000), logInfo: {message => logs.add(message)})

        let draft = builder.build([
            stateOf("web1", true, Some(ProbeSnapshot("web1", "host1", 900,
                [ProbeAgentData("cpu", "", "{\"usagePercent\":95.0}", 900, "")])))
        ], history, [], None<TopologySample>)

        @Assert(logs.size, 1)
        @Assert(logs[0].startsWith("报告生成 2 张图表，HTML "))
        @Assert(logs[0].contains(" 字节"))
        @Assert(!logs[0].contains(dir))
        @Assert(!logs[0].contains("报告批次"))

        draft.cleanup()
    }
}
