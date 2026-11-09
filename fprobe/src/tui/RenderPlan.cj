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

import std.collection.ArrayList
import fountain::f_data.*
import fountain::fprobe.collect.{Aggregation, MetricProjection}
import fountain::fprobe.snapshot.ProbeAgentData
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

/** Sparkline 的一段序列；长度即 `probe_historyPoints` 窗口内的实际点数。 */
public class SparkSeries {
    public let name: String
    public let unit: String
    public let values: Array<Float64>

    public init(name: String, unit: String, values: Array<Float64>) {
        this.name = name
        this.unit = unit
        this.values = values
    }
}

/** 历史窗口的只读来源；TUI 只消费，不负责追加。 */
public interface HistorySource {
    func values(node: String, metricKey: String): Array<Float64>
}

/** 无历史数据时的空实现，保证渲染路径永远有非空对象可用。 */
public class EmptyHistorySource <: HistorySource {
    public init() {}

    public func values(_: String, _: String): Array<Float64> {
        Array<Float64>()
    }
}

/** 指标在界面上的显示名与取值规则。 */
public class MetricSpec {
    public let label: String
    public let projection: MetricProjection

    public init(label: String, projection: MetricProjection) {
        this.label = label
        this.projection = projection
    }
}

/**
 * 指标目录：页面 → 指标路径 → 聚合方式 → 单位。
 *
 * 渲染、历史追加与图表共用同一份定义，避免三处各写一遍路径。
 */
public class ProjectionCatalog {
    public static func specs(page: MetricPage): Array<MetricSpec> {
        match (page) {
            case MetricPage.CPU => [
                MetricSpec("使用率", MetricProjection("cpu", "usagePercent", "$.usagePercent", unit: "%")),
                MetricSpec("iowait", MetricProjection("cpu", "iowaitPercent", "$.iowaitPercent", unit: "%")),
                MetricSpec("load1", MetricProjection("cpu", "load1", "$.load1")),
                MetricSpec("load5", MetricProjection("cpu", "load5", "$.load5")),
                MetricSpec("load15", MetricProjection("cpu", "load15", "$.load15")),
                MetricSpec("核心数", MetricProjection("cpu", "cores", "$.cores"))
            ]
            case MetricPage.MEMORY => [
                MetricSpec("总量", MetricProjection("memory", "totalBytes", "$.totalBytes", unit: "B")),
                MetricSpec("已用", MetricProjection("memory", "usedBytes", "$.usedBytes", unit: "B")),
                MetricSpec("可用", MetricProjection("memory", "availableBytes", "$.availableBytes", unit: "B")),
                MetricSpec("Swap 已用", MetricProjection("memory", "swapUsedBytes", "$.swapUsedBytes", unit: "B"))
            ]
            case MetricPage.DISK => [
                MetricSpec("最大使用率", MetricProjection("disk", "mountMaxUsedPercent",
                    "$.mounts[*].usedPercent", aggregation: Aggregation.Max, unit: "%")),
                MetricSpec("最大 IO 使用率", MetricProjection("disk", "deviceMaxUtilPercent",
                    "$.devices[*].utilPercent", aggregation: Aggregation.Max, unit: "%")),
                MetricSpec("最大 await", MetricProjection("disk", "deviceMaxAwaitMs",
                    "$.devices[*].awaitMs", aggregation: Aggregation.Max, unit: "ms"))
            ]
            case MetricPage.NETWORK => [
                MetricSpec("接收", MetricProjection("network", "rxBytesPerSec",
                    "$.interfaces[*].rxBytesPerSec", aggregation: Aggregation.Sum, unit: "B/s")),
                MetricSpec("发送", MetricProjection("network", "txBytesPerSec",
                    "$.interfaces[*].txBytesPerSec", aggregation: Aggregation.Sum, unit: "B/s")),
                MetricSpec("最大带宽占用", MetricProjection("network", "maxBandwidthPercent",
                    "$.interfaces[*].bandwidthPercent", aggregation: Aggregation.Max, unit: "%")),
                MetricSpec("最大丢包", MetricProjection("network", "maxDropPercent",
                    "$.interfaces[*].dropPercent", aggregation: Aggregation.Max, unit: "%"))
            ]
            case MetricPage.SERVICE => [
                MetricSpec("最大延迟", MetricProjection("service", "maxLatencyMs",
                    "$.targets[*].latencyMs", aggregation: Aggregation.Max, unit: "ms")),
                MetricSpec("最大状态码", MetricProjection("service", "maxStatusCode",
                    "$.targets[*].statusCode", aggregation: Aggregation.Max))
            ]
            case MetricPage.HEALTH => [
                MetricSpec("堆已用", MetricProjection("mvc-health", "usedHeapSize", "$.usedHeapSize", unit: "B")),
                MetricSpec("线程数", MetricProjection("mvc-health", "threadCount", "$.threadCount")),
                MetricSpec("GC 次数", MetricProjection("mvc-health", "gcCount", "$.gcCount"))
            ]
            case MetricPage.TOPOLOGY => Array<MetricSpec>()
            case MetricPage.ALARMS => Array<MetricSpec>()
        }
    }

    /** 所有页面的指标并集，供历史追加使用；同一 key 只出现一次。 */
    public static func all(): Array<MetricSpec> {
        let result = ArrayList<MetricSpec>()
        for (page in ViewModel.PAGES) {
            for (spec in specs(page)) {
                var exists = false
                for (existing in result) {
                    if (existing.projection.key() == spec.projection.key()) {
                        exists = true
                        break
                    }
                }
                if (!exists) {
                    result.add(spec)
                }
            }
        }
        result.toArray()
    }
}

/**
 * 一帧的完整纯数据描述（设计 D9）。
 *
 * 顶部状态、左侧节点、右侧指标表与 Sparkline、底部告警都以普通字符串/数组
 * 表达；终端薄层只做机械映射，视图逻辑可在 CI 中直接断言。
 */
public class RenderPlan {
    public let title: String
    public let nodeRows: Array<String>
    public let selectedNode: String
    public let selectedIndex: Int64
    public let pageTitle: String
    public let metricRows: Array<Array<String>>
    public let series: Array<SparkSeries>
    public let alarmRows: Array<String>
    public let note: String

    public init(title: String, nodeRows: Array<String>, selectedNode: String, selectedIndex: Int64,
        pageTitle: String, metricRows: Array<Array<String>>, series: Array<SparkSeries>,
        alarmRows: Array<String>, note: String) {
        this.title = title
        this.nodeRows = nodeRows
        this.selectedNode = selectedNode
        this.selectedIndex = selectedIndex
        this.pageTitle = pageTitle
        this.metricRows = metricRows
        this.series = series
        this.alarmRows = alarmRows
        this.note = note
    }
}

/** 由 ViewModel、NodeStateStore 快照与历史窗口生成一帧。 */
public class RenderPlanBuilder {
    public static func build(view: ViewModel, states: Array<NodeState>, history: HistorySource,
        nowMs: Int64, alarms: Array<String>): RenderPlan {
        let selectedName = match (view.selectedNode()) {
            case Some(value) => value
            case None => if (states.isEmpty()) {
                ""
            } else {
                states[0].node
            }
        }
        let selectedIndex = indexOfName(view.nodes, selectedName)
        let nodeRows = renderNodeRows(view.nodes, states, selectedIndex)
        let nodeCount = if (view.nodes.isEmpty()) {
            states.size
        } else {
            view.nodes.size
        }

        let page = view.page()
        let metricRows = ArrayList<Array<String>>()
        let series = ArrayList<SparkSeries>()
        var note = ""

        if (page == MetricPage.ALARMS) {
            for (alarm in alarms) {
                metricRows.add([alarm, ""])
            }
        } else if (page == MetricPage.TOPOLOGY) {
            let agent = findAgent(states, selectedName, "topology")
            note = describeMissing(states, selectedName, agent, "topology")
            for (row in topologyRows(agent)) {
                metricRows.add(row)
            }
        } else {
            let specs = ProjectionCatalog.specs(page)
            let kind = page.kind()
            let agent = findAgent(states, selectedName, kind)
            note = describeMissing(states, selectedName, agent, kind)
            for (spec in specs) {
                metricRows.add([spec.label, renderValue(agent, spec.projection)])
                series.add(SparkSeries(spec.label, spec.projection.unit,
                    history.values(selectedName, spec.projection.key())))
            }
        }

        RenderPlan(
            "fprobe  节点 ${nodeCount}  告警 ${view.alarmCount}  刷新 ${nowMs}ms",
            nodeRows,
            selectedName,
            selectedIndex,
            page.title(),
            metricRows.toArray(),
            series.toArray(),
            alarms,
            note
        )
    }

    private static func indexOfName(names: Array<String>, name: String): Int64 {
        for (i in 0..names.size) {
            if (names[i] == name) {
                return i
            }
        }
        0
    }

    /** 左侧列表以配置的节点为准；尚未拉取到的节点显示为「等待」。 */
    private static func renderNodeRows(names: Array<String>, states: Array<NodeState>,
        selectedIndex: Int64): Array<String> {
        let rows = ArrayList<String>()
        for (i in 0..names.size) {
            let marker = if (i == selectedIndex) {
                "▸"
            } else {
                " "
            }
            rows.add("${marker} ${names[i]}  ${statusOf(states, names[i])}")
        }
        rows.toArray()
    }

    /** 拓扑页：把 `topology` 监控项的 devices/links 压成两组文本行。 */
    private static func topologyRows(agent: ?ProbeAgentData): Array<Array<String>> {
        let rows = ArrayList<Array<String>>()
        let data = match (agent) {
            case Some(value) =>
                if (!value.error.isEmpty()) {
                    return rows.toArray()
                }
                value.dataJson
            case None => return rows.toArray()
        }
        let root = try {
            JsonValue.fromStr(data).asObject()
        } catch (_: Exception) {
            return rows.toArray()
        }
        match (root.get("devices")) {
            case Some(value) =>
                let items = try {
                    value.asArray()
                } catch (_: Exception) {
                    JsonArray()
                }
                for (item in items) {
                    let device = try {
                        item.asObject()
                    } catch (_: Exception) {
                        continue
                    }
                    let name = textOf(device, "name")
                    let host = textOf(device, "host")
                    let ports = listOf(device, "ports")
                    rows.add(["设备 ${name}(${host})", ports])
                }
            case None => ()
        }
        match (root.get("links")) {
            case Some(value) =>
                let items = try {
                    value.asArray()
                } catch (_: Exception) {
                    JsonArray()
                }
                for (item in items) {
                    let link = try {
                        item.asObject()
                    } catch (_: Exception) {
                        continue
                    }
                    let from = textOf(link, "from")
                    let to = textOf(link, "to")
                    let local = textOf(link, "localPort")
                    let remote = textOf(link, "remotePort")
                    rows.add(["链路 ${from}:${local}", "${to}:${remote}"])
                }
            case None => ()
        }
        rows.toArray()
    }

    private static func textOf(object: JsonObject, key: String): String {
        match (object.get(key)) {
            case Some(value) =>
                try {
                    value.asString().value
                } catch (_: Exception) {
                    ""
                }
            case None => ""
        }
    }

    private static func listOf(object: JsonObject, key: String): String {
        match (object.get(key)) {
            case Some(value) =>
                let items = try {
                    value.asArray()
                } catch (_: Exception) {
                    return ""
                }
                let names = ArrayList<String>()
                for (item in items) {
                    names.add(try {
                        item.asString().value
                    } catch (_: Exception) {
                        ""
                    })
                }
                String.join(names.toArray(), delimiter: ",")
            case None => ""
        }
    }

    private static func statusOf(states: Array<NodeState>, name: String): String {
        for (state in states) {
            if (state.node != name) {
                continue
            }
            return match (state.status) {
                case NodeStatus.ONLINE => "在线"
                case NodeStatus.OFFLINE => "离线"
            }
        }
        "等待"
    }

    private static func findAgent(states: Array<NodeState>, name: String, kind: String): ?ProbeAgentData {
        for (state in states) {
            if (state.node != name) {
                continue
            }
            match (state.snapshot) {
                case Some(snapshot) =>
                    for (agent in snapshot.agents) {
                        if (agent.kind == kind) {
                            return Some(agent)
                        }
                    }
                    return None<ProbeAgentData>
                case None => return None<ProbeAgentData>
            }
        }
        None<ProbeAgentData>
    }

    private static func describeMissing(states: Array<NodeState>, name: String,
        agent: ?ProbeAgentData, kind: String): String {
        var hasSnapshot = false
        for (state in states) {
            if (state.node == name) {
                hasSnapshot = state.snapshot.isSome()
                break
            }
        }
        if (!hasSnapshot) {
            return "节点暂无数据"
        }
        match (agent) {
            case Some(value) =>
                if (!value.error.isEmpty()) {
                    return value.error
                }
                ""
            case None => '节点未提供 ${kind} 监控项'
        }
    }

    private static func renderValue(agent: ?ProbeAgentData, projection: MetricProjection): String {
        match (agent) {
            case Some(value) =>
                if (!value.error.isEmpty()) {
                    return "--"
                }
                match (projection.evaluate(value.dataJson)) {
                    case Some(number) => "${number}${projection.unit}"
                    case None => "--"
                }
            case None => "--"
        }
    }
}
