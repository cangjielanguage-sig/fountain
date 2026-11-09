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
import fountain::f_chart.{AreaChart, BarChart, Chart, LineChart}
import fountain::f_data.*
import fountain::f_data.macros.*

/** 类目轴；报告目前只使用标签，不生成时间轴。 */
@DataAssist[props fields]
public class ChartAxisSpec {
    @FieldAlias['type']
    private var axisType: String = ""
    private var labels: Array<String> = []

    public init() {}

    public init(labels: Array<String>, axisType!: String = "") {
        this.labels = labels
        this.axisType = axisType
    }
}

/** 一个数据系列。 */
@DataAssist[props fields]
public class ChartSeriesSpec {
    private var name: String = ""
    private var data: Array<Float64> = []

    public init() {}

    public init(name: String, data: Array<Float64>) {
        this.name = name
        this.data = data
    }
}

/**
 * `f_chart` 的 JSON 描述 DTO。
 *
 * `chartType` 通过 `@FieldAlias['type']` 映射到 JSON 的 `type`，避免在代码里
 * 反复写反引号字段名；序列化后可直接交给 `Chart.draw`。
 */
@DataAssist[props fields]
public class ChartSpec {
    @FieldAlias['type']
    private var chartType: String = "line"
    private var title: String = ""
    private var width: Float64 = 800.0
    private var height: Float64 = 320.0
    private var xAxis: ChartAxisSpec = ChartAxisSpec()
    private var series: Array<ChartSeriesSpec> = []

    public init() {}

    public init(chartType: String, title: String, labels: Array<String>, data: Array<Float64>) {
        this.chartType = chartType
        this.title = title
        this.xAxis = ChartAxisSpec(labels)
        this.series = [ChartSeriesSpec(title, data)]
    }

    /** 由历史点构造一条类目序列；标签使用 1..N。 */
    public static func fromValues(chartType: String, title: String, values: Array<Float64>): ChartSpec {
        let labels = ArrayList<String>()
        for (i in 0..values.size) {
            labels.add((i + 1).toString())
        }
        ChartSpec(chartType, title, labels.toArray(), values)
    }

    /**
     * 转成 `f_chart` 需要的 JSON object。
     *
     * `@FieldAlias` 只作用于反序列化；序列化时字段名仍是 `chartType`，这里把它
     * 改名为 f_chart 约定的 `type` 后再交给图表实现。
     */
    public func jsonObject(): JsonObject {
        let root = JsonValue.from(toData()).asObject()
        match (root.get("chartType")) {
            case Some(value) =>
                if (root.get("type").isNone()) {
                    root.add("type", value)
                }
                root.remove("chartType")
            case None => ()
        }
        match (root.get("xAxis")) {
            case Some(value) =>
                let axis = value.asObject()
                match (axis.get("axisType")) {
                    case Some(kind) =>
                        let name = kind.asString().value
                        if (!name.isEmpty() && axis.get("type").isNone()) {
                            axis.add("type", kind)
                        }
                        axis.remove("axisType")
                    case None => ()
                }
            case None => ()
        }
        root
    }
}

/** 按类型创建 `f_chart` 实现；未知类型由调用方保证不会走到这里。 */
public func defaultChartFactory(chartType: String): Chart {
    match (chartType) {
        case "bar" => BarChart()
        case "area" => AreaChart()
        case _ => LineChart()
    }
}

/** 把 ChartSpec 序列化为 JSON 并渲染为 SVG。 */
public class ChartRenderer {
    private let factory: (String) -> Chart

    public init(factory!: (String) -> Chart = {chartType => defaultChartFactory(chartType)}) {
        this.factory = factory
    }

    public func render(spec: ChartSpec): String {
        let chart = factory(spec.chartType)
        chart.draw(spec.jsonObject())
    }
}
