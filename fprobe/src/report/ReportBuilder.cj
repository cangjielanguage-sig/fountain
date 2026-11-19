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
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}
import fountain::fprobe.collect.Clock
import fountain::fprobe.collect.topology.TopologySample
import fountain::fprobe.supervisor.{NodeState, NodeStatus}
import fountain::fprobe.tui.{HistorySource, ProjectionCatalog}

/** 一次报告的完整内容；图表已内联进 `html`。 */
public class ReportDraft {
    public let subject: String
    public let text: String
    public let html: String

    public init(subject: String, text: String, html: String) {
        this.subject = subject
        this.text = text
        this.html = html
    }
}

/**
 * 报告内容生成器（spec「报告内容与内联图表」）。
 *
 * 摘要永远包含每个节点的在线状态与关键指标；从未成功拉取的节点写「无数据」，
 * 拓扑缺失写「拓扑不可用」。图表按指标历史生成并内联到正文，单图失败只记录
 * WARN，退化为纯文本行，不阻断其余图表。
 */
public class ReportBuilder {
    private let selector: ChartSelector
    private let renderer: ChartRenderer
    private let clock: Clock
    private let logInfo: (String) -> Unit
    private let logWarning: (String) -> Unit
    private let topologyRender: (TopologySample) -> ?String

    public init(selector: ChartSelector, renderer: ChartRenderer, clock: Clock,
        logInfo!: (String) -> Unit = {message => println(message)},
        logWarning!: (String) -> Unit = {message => eprintln(message)},
        topologyRender!: (TopologySample) -> ?String = {sample => TopologyRenderer.render(sample)}) {
        this.selector = selector
        this.renderer = renderer
        this.clock = clock
        this.logInfo = logInfo
        this.logWarning = logWarning
        this.topologyRender = topologyRender
    }

    public func build(states: Array<NodeState>, history: HistorySource, alarms: Array<AlarmEvent>,
        topology: ?TopologySample): ReportDraft {
        let now = clock.nowMs()
        let html = ArrayList<String>()
        let text = ArrayList<String>()
        var chartCount = 0

        html.add("<!DOCTYPE html><html><head><meta charset=\"utf-8\"/><title>fprobe 周期报告</title></head><body>")
        html.add("<h1>fprobe 周期报告</h1>")
        html.add("<p>生成时间: ${now}</p>")
        text.add("fprobe 周期报告")
        text.add("生成时间: ${now}")

        html.add("<h2>节点状态</h2>")
        for (state in states) {
            let online = state.status == NodeStatus.ONLINE
            let statusText = if (online) {
                "在线"
            } else {
                "离线"
            }
            html.add("<h3>${escape(state.node)}</h3>")
            html.add("<p>状态: ${statusText}</p>")
            text.add('节点 ${state.node}: ${statusText}')

            if (state.snapshot.isNone()) {
                html.add("<p>无数据</p>")
                text.add("  无数据")
                continue
            }

            var hasMetric = false
            for (spec in ProjectionCatalog.all()) {
                let key = spec.projection.key()
                let values = history.values(state.node, key)
                if (values.isEmpty()) {
                    logInfo('跳过 ${state.node} ${key}: 无历史数据')
                    continue
                }
                hasMetric = true
                let current = values[values.size - 1]
                let unit = spec.projection.unit
                let valueText = if (unit.isEmpty()) {
                    current.toString()
                } else {
                    '${current} ${unit}'
                }
                let label = '${spec.label} (${key})'
                text.add('  ${label}: ${valueText}')

                try {
                    let chartSpec = ChartSpec.fromValues(selector.select(key), '${state.node} ${spec.label}', values)
                    let svg = renderer.render(chartSpec)
                    html.add('<div class="fprobe-chart"><h4>${escape(state.node)} ' +
                        '${escape(label)}：${escape(valueText)}</h4>${inlineSvg(svg)}</div>')
                    chartCount += 1
                } catch (e: Exception) {
                    logWarning('图表生成失败 ${state.node} ${key}: ${e.message}')
                    html.add("<p>${escape(label)}: ${escape(valueText)}</p>")
                } catch (e: Error) {
                    logWarning('图表生成失败 ${state.node} ${key}: ${e.message}')
                    html.add("<p>${escape(label)}: ${escape(valueText)}</p>")
                }
            }
            if (!hasMetric) {
                html.add("<p>无数据</p>")
                text.add("  无数据")
            }
        }

        let stats = countAlarms(alarms)
        html.add("<h2>告警统计</h2>")
        html.add("<p>告警 ${stats[0]} 条，恢复 ${stats[1]} 条，节点不可达 ${stats[2]} 条，其它 ${stats[3]} 条</p>")
        text.add('告警统计: 告警 ${stats[0]} 条，恢复 ${stats[1]} 条，节点不可达 ${stats[2]} 条，其它 ${stats[3]} 条')
        for (event in alarms) {
            html.add("<p>${escape(event.message)}</p>")
            text.add('  ${event.message}')
        }

        html.add("<h2>拓扑</h2>")
        let topologySvg: ?String = match (topology) {
            case Some(sample) =>
                try {
                    topologyRender(sample)
                } catch (e: Exception) {
                    logWarning('拓扑渲染失败: ${e.message}')
                    None<String>
                } catch (e: Error) {
                    logWarning('拓扑渲染失败: ${e.message}')
                    None<String>
                }
            case None => None<String>
        }
        match (topologySvg) {
            case Some(svg) =>
                html.add('<div class="fprobe-topology">${inlineSvg(svg)}</div>')
                match (topology) {
                    case Some(sample) =>
                        text.add('拓扑: 已内联（${sample.devices.size} 个设备 / ${sample.links.size} 条链路）')
                    case None => text.add("拓扑不可用")
                }
            case None =>
                html.add("<p>拓扑不可用</p>")
                text.add("拓扑不可用")
        }

        html.add("</body></html>")
        let htmlText = joinLines(html, "")
        logInfo('报告生成 ${chartCount} 张图表，HTML ${htmlText.toArray().size} 字节')
        ReportDraft("fprobe 周期报告", joinLines(text, "\n"), htmlText)
    }

    /** 去掉 SVG 的 XML 前导声明；只处理开头，不碰正文。 */
    private static func inlineSvg(svg: String): String {
        let text = svg.trimAscii()
        if (!text.startsWith("<?xml")) {
            return text
        }
        match (text.indexOf("?>")) {
            case Some(end) => text[end + 2..].trimAscii()
            case None => text
        }
    }

    private static func countAlarms(alarms: Array<AlarmEvent>): Array<Int64> {
        var firing = 0
        var recovery = 0
        var unreachable = 0
        var other = 0
        for (event in alarms) {
            match (event.eventType) {
                case AlarmEventType.FIRING => firing += 1
                case AlarmEventType.RECOVERY => recovery += 1
                case AlarmEventType.NODE_UNREACHABLE => unreachable += 1
                case _ => other += 1
            }
        }
        [firing, recovery, unreachable, other]
    }

    private static func joinLines(lines: ArrayList<String>, separator: String): String {
        var result = ""
        var first = true
        for (line in lines) {
            if (!first) {
                result += separator
            }
            result += line
            first = false
        }
        result
    }

    private static func escape(value: String): String {
        value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
    }
}
