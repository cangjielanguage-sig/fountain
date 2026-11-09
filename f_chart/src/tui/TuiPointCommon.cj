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
package fountain::f_chart.tui

import std.collection.ArrayList
import fountain::f_chart.*
import fountain::f_data.json.*

internal class TuiPoint {
    let x: Float64
    let y: ?Float64

    init(x: Float64, y: ?Float64) {
        this.x = x
        this.y = y
    }
}

internal class TuiPointSeries {
    let name: String
    let points: Array<TuiPoint>
    let color: String

    init(name: String, points: Array<TuiPoint>, color: String) {
        this.name = name
        this.points = points
        this.color = color
    }
}

/** 解析折线/散点系列：类目轴用数值数组，数值/时间轴用 `{x,y}` 对象。 */
internal func tuiParsePointSeries(
    config: ChartConfig,
    seriesArray: JsonArray
): Array<TuiPointSeries> {
    let items = seriesArray.getItems()
    if (items.isEmpty()) {
        throw chartMissingField("series")
    }
    let category = config.xAxis.axisType == "category"
    let series = ArrayList<TuiPointSeries>()
    var seriesIndex = 0
    for (item in items) {
        let seriesPath = "series[${seriesIndex}]"
        if (!item.kind.isObject) {
            throw chartInvalidValue(seriesPath, "期望系列对象")
        }
        let json = ChartJson.of(item.asObject(), seriesPath)
        let name = json.string("name", default: "")
        let color = tuiSeriesColor(config, seriesIndex, json.string("color", default: ""))
        let dataArray = json.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
        }
        let points = ArrayList<TuiPoint>()
        if (category) {
            var index = 0
            for (value in dataItems) {
                let pointPath = "${seriesPath}.data[${index}]"
                if (value.kind.isNull) {
                    points.add(TuiPoint(Float64(index), None<Float64>))
                } else {
                    points.add(TuiPoint(
                        Float64(index),
                        Some(jsonNumberValue(value, pointPath))
                    ))
                }
                index++
            }
        } else {
            var index = 0
            for (value in dataItems) {
                let pointPath = "${seriesPath}.data[${index}]"
                if (!value.kind.isObject) {
                    throw chartInvalidValue(pointPath, "期望 {x,y} 对象")
                }
                let pointJson = ChartJson.of(value.asObject(), pointPath)
                let xValue = pointJson.required("x")
                var x = 0.0
                if (xValue.kind.isInt || xValue.kind.isDecimal) {
                    x = jsonNumberValue(xValue, "${pointPath}.x")
                } else if (xValue.kind.isString) {
                    if (config.xAxis.axisType != "time") {
                        throw chartInvalidValue("${pointPath}.x", "数值轴需要数字 x")
                    }
                    x = ChartTime.parseDays(xValue.asString().value, "${pointPath}.x")
                } else {
                    throw chartInvalidValue("${pointPath}.x", "x 必须是数字或日期字符串")
                }
                var y: ?Float64 = None
                match (pointJson.value("y")) {
                    case Some(yValue) =>
                        if (!yValue.kind.isNull) {
                            y = Some(jsonNumberValue(yValue, "${pointPath}.y"))
                        }
                    case None => ()
                }
                points.add(TuiPoint(x, y))
                index++
            }
        }
        series.add(TuiPointSeries(name, points.toArray(), color))
        seriesIndex++
    }
    series.toArray()
}

/** 收集所有非空 y。 */
internal func tuiPointYValues(series: Array<TuiPointSeries>): Array<Float64> {
    let values = ArrayList<Float64>()
    for (item in series) {
        for (point in item.points) {
            match (point.y) {
                case Some(value) => values.add(value)
                case None => ()
            }
        }
    }
    values.toArray()
}

/** 收集所有 x。 */
internal func tuiPointXValues(series: Array<TuiPointSeries>): Array<Float64> {
    let values = ArrayList<Float64>()
    for (item in series) {
        for (point in item.points) {
            values.add(point.x)
        }
    }
    values.toArray()
}
