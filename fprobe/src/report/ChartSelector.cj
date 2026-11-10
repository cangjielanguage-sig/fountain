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

import fountain::f_config.Config

/**
 * 指标 → `f_chart` 图表类型（spec「图表类型选择」）。
 *
 * 配置键是 `probe_chart_<metric>`，点替换为下划线；未配置时按指标给默认类型。
 * 配置了不支持的类型只记录 WARN 并回退 `line`，不中断报告。
 */
public class ChartSelector {
    public static let SUPPORTED_TYPES = ["line", "area", "bar"]

    private let lookup: (String) -> ?String
    private let warn: (String) -> Unit

    public init(lookup!: (String) -> ?String = {key => Config.getString(key)},
        warn!: (String) -> Unit = {message => eprintln(message)}) {
        this.lookup = lookup
        this.warn = warn
    }

    /** 选择指标图表类型；未知配置值回退 `line`。 */
    public func select(metric: String): String {
        let key = configKey(metric)
        let configured = match (lookup(key)) {
            case Some(value) => value.trimAscii().toAsciiLower()
            case None => ""
        }
        if (configured.isEmpty()) {
            return defaultType(metric)
        }
        if (supports(configured)) {
            return configured
        }
        warn('未知图表类型 "${configured}"（${key}），回退为 line')
        "line"
    }

    /** 指标 id 对应的配置键。 */
    public static func configKey(metric: String): String {
        "probe_chart_" + metric.replace(".", "_")
    }

    /** spec 规定的默认类型；未列出的指标使用折线。 */
    public static func defaultType(metric: String): String {
        match (metric) {
            case "cpu.usagePercent" => "line"
            case "memory.usedPercent" => "area"
            case "disk.usedPercent" => "bar"
            case "network.rxBps" => "line"
            case "service.latencyMs" => "line"
            case _ => "line"
        }
    }

    /** `f_chart` 当前接入的类型。 */
    public static func supports(chartType: String): Bool {
        for (value in SUPPORTED_TYPES) {
            if (value == chartType) {
                return true
            }
        }
        false
    }
}
