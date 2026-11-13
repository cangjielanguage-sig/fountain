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
package fountain::fprobe.llm

import std.collection.ArrayList
import fountain::fprobe.alarm.AlarmEvent
import fountain::fprobe.supervisor.{NodeState, NodeStatus}
import fountain::fprobe.tui.{HistorySource, ProjectionCatalog}

/**
 * 组织分析提示词（spec「分析输入」）。
 *
 * 提示词包含节点摘要、相关告警与最近 N 个历史点，并明确要求模型只输出固定
 * JSON 结构，避免自由文本进入后续解析链路。
 */
public class PromptBuilder {
    public static func build(states: Array<NodeState>, events: Array<AlarmEvent>,
        history: HistorySource, historyPoints!: Int64 = 20): String {
        let lines = ArrayList<String>()
        lines.add("你是 fprobe 的运维分析助手。请只输出一个 JSON 对象，不要输出 Markdown 或额外解释。")
        lines.add("JSON 结构：{\"summary\":\"...\",\"problems\":[\"...\"]," +
            "\"solutions\":[{\"title\":\"...\",\"action\":\"ack|mute|report|none\",\"risk\":\"...\"}]}")
        lines.add("")
        lines.add("节点摘要：")

        for (state in states) {
            let status = if (state.status == NodeStatus.ONLINE) {
                "在线"
            } else {
                "离线"
            }
            lines.add('- ${state.node} (${status})')
            match (state.snapshot) {
                case Some(snapshot) =>
                    var found = false
                    for (spec in ProjectionCatalog.all()) {
                        let key = spec.projection.key()
                        for (agent in snapshot.agents) {
                            if (agent.kind != spec.projection.kind || !agent.error.isEmpty()) {
                                continue
                            }
                            match (spec.projection.evaluate(agent.dataJson)) {
                                case Some(value) =>
                                    let unit = if (spec.projection.unit.isEmpty()) {
                                        ""
                                    } else {
                                        ' ${spec.projection.unit}'
                                    }
                                    lines.add('  ${key} = ${value}${unit}')
                                    found = true
                                case None => ()
                            }
                        }
                    }
                    if (!found) {
                        lines.add("  指标: 无数据")
                    }
                case None =>
                    lines.add("  指标: 无数据")
            }
        }

        lines.add("")
        lines.add("告警事件：")
        if (events.isEmpty()) {
            lines.add("- 无")
        } else {
            for (event in events) {
                let current = match (event.value) {
                    case Some(value) => value.toString()
                    case None => "-"
                }
                lines.add('- 节点 ${event.node} 规则 ${event.rule} 级别 ${event.level} ' +
                    '当前值 ${current} 阈值 ${event.threshold}')
            }
        }

        lines.add("")
        lines.add('历史点(最近 ${historyPoints})：')
        for (state in states) {
            for (spec in ProjectionCatalog.all()) {
                let key = spec.projection.key()
                let values = history.values(state.node, key)
                if (values.isEmpty()) {
                    continue
                }
                let selected = tail(values, historyPoints)
                lines.add('- ${state.node} ${key}: [${joinNumbers(selected)}] (共 ${selected.size} 点)')
            }
        }

        joinLines(lines, "\n")
    }

    private static func tail(values: Array<Float64>, limit: Int64): Array<Float64> {
        if (limit <= 0) {
            return Array<Float64>()
        }
        if (values.size <= limit) {
            return values
        }
        let start = values.size - limit
        Array<Float64>(values.size - start) {i => values[start + i]}
    }

    private static func joinNumbers(values: Array<Float64>): String {
        var result = ""
        var first = true
        for (value in values) {
            if (!first) {
                result += ", "
            }
            result += value.toString()
            first = false
        }
        result
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
}
