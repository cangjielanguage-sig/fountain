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
package fountain::fprobe.collect

import std.collection.ArrayList
import fountain::f_data.*

/** 一个 `kind` 下某个指标的展示与聚合方式。 */
public enum Aggregation <: Equatable<Aggregation> {
    | First
    | Max
    | Sum
    | Avg

    public operator func ==(other: Aggregation): Bool {
        match ((this, other)) {
            case (First, First) | (Max, Max) | (Sum, Sum) | (Avg, Avg) => true
            case _ => false
        }
    }

    public static func parse(value: String): ?Aggregation {
        match (value.trimAscii().toAsciiLower()) {
            case "first" => First
            case "max" => Max
            case "sum" => Sum
            case "avg" => Avg
            case _ => None<Aggregation>
        }
    }

    /** 对非空数组做聚合；空数组返回 None。 */
    public static func aggregate(mode: Aggregation, values: Array<Float64>): ?Float64 {
        if (values.isEmpty()) {
            return None<Float64>
        }
        match (mode) {
            case First => values[0]
            case Max =>
                var result = values[0]
                for (value in values) {
                    if (value > result) {
                        result = value
                    }
                }
                result
            case Sum =>
                var total = 0.0
                for (value in values) {
                    total += value
                }
                total
            case Avg =>
                var total = 0.0
                for (value in values) {
                    total += value
                }
                total / Float64(values.size)
        }
    }
}

/**
 * 指标投影：把 `kind + 指标名` 映射到 `DataPath`、聚合方式与单位。
 *
 * 报告、TUI 与告警规则共用同一份投影描述，避免各处重复写路径。
 */
public class MetricProjection {
    public let kind: String
    public let metric: String
    public let path: String
    public let aggregation: Aggregation
    public let unit: String

    public init(kind: String, metric: String, path: String,
        aggregation!: Aggregation = Aggregation.First, unit!: String = "") {
        this.kind = kind
        this.metric = metric
        this.path = path
        this.aggregation = aggregation
        this.unit = unit
    }

    public func key(): String {
        "${kind}.${metric}"
    }

    /** 在 `dataJson` 上取值并聚合；JSON 非法、路径缺失或数组为空都返回 None。 */
    public func evaluate(dataJson: String): ?Float64 {
        Aggregation.aggregate(aggregation, collectValues(path, dataJson))
    }
}

private func collectValues(path: String, dataJson: String): Array<Float64> {
    let collected = ArrayList<Float64>()
    match (jsonToData(dataJson)) {
        case Some(root) =>
            try {
                for (item in DataPath.solid(path).get(root)) {
                    match (item) {
                        case real: DataReal => collected.add(real.toFloat64())
                        case _ => ()
                    }
                }
            } catch (_: Exception) {
                return Array<Float64>()
            }
        case None => ()
    }
    collected.toArray()
}
