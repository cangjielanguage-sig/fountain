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
package fountain::fprobe.runtime

import fountain::f_data.*
import fountain::fprobe.tui.{Painter, RenderPlan, SupervisorApp}

/** 延迟绑定，解决 `SupervisorApp` 与渲染线程之间的构造环。 */
public class AppHolder {
    public var app: ?SupervisorApp = None
}

/** resident 模式占位：不初始化终端，所有绘制调用都是空操作。 */
public class NullPainter <: Painter {
    public init() {}

    public func start(): Unit {}

    public func draw(plan: RenderPlan): Unit {}

    public func restore(): Unit {}
}

/**
 * 从监控项 JSON 中取一个用于 Sparkline 的主数值。
 *
 * 只做展示用途，取不到就跳过该点；不影响告警与上报。
 */
public class MetricExtractor {
    public static func primary(kind: String, json: String): ?Float64 {
        let root = try {
            JsonValue.fromStr(json).asObject()
        } catch (_: Exception) {
            return None<Float64>
        }
        match (kind) {
            case "cpu" => number(root, "usagePercent")
            case "memory" => number(root, "availableBytes")
            case "system" => number(root, "processCount")
            case "disk" => firstOfArray(root, "mounts", "usedPercent")
            case "network" => firstOfArray(root, "interfaces", "rxBytesPerSec")
            case "service" => countOfArray(root, "targets")
            case _ => None<Float64>
        }
    }

    private static func number(object: JsonObject, key: String): ?Float64 {
        match (object.get(key)) {
            case Some(value) =>
                match (Float64.tryParse(value.toJsonString())) {
                    case Some(number) => Some(number)
                    case None => None<Float64>
                }
            case None => None<Float64>
        }
    }

    private static func firstOfArray(object: JsonObject, arrayKey: String, field: String): ?Float64 {
        match (object.get(arrayKey)) {
            case Some(value) =>
                let items = try {
                    value.asArray()
                } catch (_: Exception) {
                    return None<Float64>
                }
                if (items.isEmpty()) {
                    return None<Float64>
                }
                let first = try {
                    items[0].asObject()
                } catch (_: Exception) {
                    return None<Float64>
                }
                number(first, field)
            case None => None<Float64>
        }
    }

    private static func countOfArray(object: JsonObject, arrayKey: String): ?Float64 {
        match (object.get(arrayKey)) {
            case Some(value) =>
                try {
                    Some(Float64(value.asArray().size))
                } catch (_: Exception) {
                    None<Float64>
                }
            case None => None<Float64>
        }
    }
}
