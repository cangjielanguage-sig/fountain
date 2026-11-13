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
package fountain::f_chart

import std.collection.ArrayList
import std.math.*
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, formatSvgNumber}

/** 主题河流图的一个系列。 */
internal class StreamSeries {
    let name: String
    let values: Array<Float64>
    let color: Option<String>

    init(name: String, values: Array<Float64>, color: Option<String>) {
        this.name = name
        this.values = values
        this.color = color
    }
}

/** M82 主题河流图。 */
public class StreamgraphChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "streamgraph")
        let root = ChartJson.of(data)
        let mode = root.string("baseline", default: "wiggle")
        if (mode != "wiggle" && mode != "zero" && mode != "symmetry") {
            throw chartInvalidValue("baseline", "仅支持 wiggle / zero / symmetry")
        }
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        let seriesList = ArrayList<StreamSeries>()
        var seriesIndex = 0
        var columnCount: Int64 = -1
        for (item in seriesItems) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let dataArray = json.requiredArray("data")
            let dataItems = dataArray.getItems()
            if (dataItems.isEmpty()) {
                throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
            }
            if (columnCount < 0) {
                columnCount = dataItems.size
            } else if (columnCount != dataItems.size) {
                throw chartInvalidValue("series", "各系列数据长度必须一致")
            }
            let values = ArrayList<Float64>()
            var dataIndex = 0
            for (value in dataItems) {
                if (!(value.kind.isInt || value.kind.isDecimal)) {
                    throw chartInvalidValue(
                        "${seriesPath}.data[${dataIndex}]", "期望数字"
                    )
                }
                values.add(jsonNumberValue(value, "${seriesPath}.data[${dataIndex}]"))
                dataIndex++
            }
            seriesList.add(StreamSeries(
                json.string("name", default: (seriesIndex + 1).toString()),
                values.toArray(),
                json.string("color")
            ))
            seriesIndex++
        }
        let series = seriesList.toArray()
        let columns = columnCount

        let labels = ArrayList<String>()
        if (!config.xAxis.labels.isEmpty()) {
            if (config.xAxis.labels.size != columns) {
                throw chartInvalidValue("xAxis.labels", "标签数量与数据长度不一致")
            }
            for (label in config.xAxis.labels) {
                labels.add(label)
            }
        } else {
            for (index in 0..columns) {
                labels.add((index + 1).toString())
            }
        }

        let totals = ArrayList<Float64>()
        for (column in 0..columns) {
            var total = 0.0
            for (item in series) {
                total += item.values[column]
            }
            totals.add(total)
        }
        let baseline = streamBaseline(totals.toArray(), mode)

        var dataMin = 0.0
        var dataMax = 0.0
        for (column in 0..columns) {
            var accumulated = baseline[column]
            dataMin = minFloat(dataMin, accumulated)
            dataMax = maxFloat(dataMax, accumulated)
            for (item in series) {
                accumulated += item.values[column]
                dataMin = minFloat(dataMin, accumulated)
                dataMax = maxFloat(dataMax, accumulated)
            }
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.05
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.05
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }
        let yTickLabels = ArrayList<String>()
        for (tick in yTicks) {
            yTickLabels.add(chartFormatTick(tick, config.yAxis.labelFormat))
        }

        var maxYTickWidth = 0.0
        for (label in yTickLabels) {
            maxYTickWidth = maxFloat(maxYTickWidth, chartTextWidth(label, config.theme.fontSize))
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, true, maxYTickWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), columns)
        let yScale = LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let names = ArrayList<String>()
        let colors = ArrayList<String>()
        for (index in 0..series.size) {
            names.add(series[index].name)
            colors.add(match (series[index].color) {
                case Some(color) => color
                case None => config.theme.colorAt(index)
            })
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        for (layer in 0..series.size) {
            let path = StringBuilder()
            for (column in 0..columns) {
                var lower = baseline[column]
                for (index in 0..layer) {
                    lower += series[index].values[column]
                }
                let upper = lower + series[layer].values[column]
                let x = band.center(column)
                let y = yScale.scale(upper)
                if (column == 0) {
                    path.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                } else {
                    path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                }
            }
            var column = columns - 1
            while (column >= 0) {
                var lower = baseline[column]
                for (index in 0..layer) {
                    lower += series[index].values[column]
                }
                let x = band.center(column)
                let y = yScale.scale(lower)
                path.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
                column--
            }
            path.append(" Z")
            kit.path(
                path.toString(),
                fill: colors[layer],
                fillOpacity: 0.85,
                className: "stream-band"
            )
        }
        frame.drawXAxis(kit, labels.toArray(), band)
        builder.toSvgString()
    }
}

/** 按模式计算每列基线。 */
internal func streamBaseline(totals: Array<Float64>, mode: String): Array<Float64> {
    let baseline = ArrayList<Float64>()
    if (mode == "zero") {
        for (total in totals) {
            baseline.add(0.0)
        }
        return baseline.toArray()
    }
    for (total in totals) {
        baseline.add(-total / 2.0)
    }
    if (mode == "wiggle" && totals.size > 2) {
        let smoothed = ArrayList<Float64>()
        for (index in 0..baseline.size) {
            if (index == 0 || index + 1 == baseline.size) {
                smoothed.add(baseline[index])
            } else {
                smoothed.add(
                    (baseline[index - 1] + 2.0 * baseline[index] + baseline[index + 1]) / 4.0
                )
            }
        }
        return smoothed.toArray()
    }
    baseline.toArray()
}
