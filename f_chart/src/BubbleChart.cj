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
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 气泡图的一个点。 */
internal class BubblePoint {
    let x: Float64
    let y: Float64
    let size: Float64
    let label: String

    init(x: Float64, y: Float64, size: Float64, label: String) {
        this.x = x
        this.y = y
        this.size = size
        this.label = label
    }
}

/** 气泡图的一个系列。 */
internal class BubbleSeries {
    let name: String
    let color: ?String
    let points: Array<BubblePoint>
    let minRadius: Float64
    let maxRadius: Float64

    init(
        name: String,
        color: ?String,
        points: Array<BubblePoint>,
        minRadius: Float64,
        maxRadius: Float64
    ) {
        this.name = name
        this.color = color
        this.points = points
        this.minRadius = minRadius
        this.maxRadius = maxRadius
    }
}

/**
 * M26 气泡图。
 *
 * 在 `{x,y}` 散点上用半径编码 `size`，支持多系列与标签。
 */
public class BubbleChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "bubble")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }

        let series = ArrayList<BubbleSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let color = json.string("color")
            var minRadius = 4.0
            var maxRadius = 30.0
            match (json.value("sizeRange")) {
                case Some(value) =>
                    if (!value.kind.isArray) {
                        throw chartInvalidValue("${path}.sizeRange", "期望 [最小半径, 最大半径]")
                    }
                    let rangeItems = value.asArray().getItems()
                    if (rangeItems.size != 2) {
                        throw chartInvalidValue("${path}.sizeRange", "期望两个半径")
                    }
                    minRadius = jsonNumberValue(rangeItems[0], "${path}.sizeRange[0]")
                    maxRadius = jsonNumberValue(rangeItems[1], "${path}.sizeRange[1]")
                    if (minRadius < 0.0 || maxRadius < minRadius) {
                        throw chartInvalidValue(
                            "${path}.sizeRange",
                            "半径必须非负且上限不小于下限"
                        )
                    }
                case None => ()
            }
            let dataArray = json.requiredArray("data")
            let items = dataArray.getItems()
            if (items.isEmpty()) {
                throw chartInvalidValue("${path}.data", "数据不能为空")
            }
            let points = ArrayList<BubblePoint>()
            var pointIndex = 0
            for (entry in items) {
                let itemPath = "${path}.data[${pointIndex}]"
                if (!entry.kind.isObject) {
                    throw chartInvalidValue(itemPath, "期望 {x,y,size} 对象")
                }
                let pointJson = ChartJson.of(entry.asObject(), itemPath)
                let x = jsonNumberValue(pointJson.required("x"), "${itemPath}.x")
                let y = jsonNumberValue(pointJson.required("y"), "${itemPath}.y")
                let size = jsonNumberValue(pointJson.required("size"), "${itemPath}.size")
                let label = pointJson.string("label", default: "")
                points.add(BubblePoint(x, y, size, label))
                pointIndex++
            }
            series.add(BubbleSeries(name, color, points.toArray(), minRadius, maxRadius))
            seriesIndex++
        }

        var xMin = series[0].points[0].x
        var xMax = series[0].points[0].x
        var yMin = series[0].points[0].y
        var yMax = series[0].points[0].y
        var minSize = series[0].points[0].size
        var maxSize = series[0].points[0].size
        for (item in series) {
            for (point in item.points) {
                xMin = minFloat(xMin, point.x)
                xMax = maxFloat(xMax, point.x)
                yMin = minFloat(yMin, point.y)
                yMax = maxFloat(yMax, point.y)
                minSize = minFloat(minSize, point.size)
                maxSize = maxFloat(maxSize, point.size)
            }
        }
        let xRange = lineRange(xMin, xMax, config.xAxis.min, config.xAxis.max, "xAxis.min")
        let yRange = lineRange(yMin, yMax, config.yAxis.min, config.yAxis.max, "yAxis.min")
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yRange[0], yRange[1], config.yAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show &&
            !(series.size == 1 && series[0].name.isEmpty())
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            let width = chartTextWidth(
                chartFormatTick(tick, config.yAxis.labelFormat),
                config.theme.fontSize
            )
            if (width > maxYLabelWidth) {
                maxYLabelWidth = width
            }
        }
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, config.theme.fontSize + 12.0)
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)
        let yScale = LinearScale(yRange[0], yRange[1], frame.plot.y, frame.plot.bottom())

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
                case Some(value) => value
                case None => config.theme.colorAt(index)
            })
        }
        frame.drawLegend(kit, names.toArray(), colors.toArray())
        frame.drawYAxis(kit, yTicks, yScale)

        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = colors[seriesIndex]
            for (point in item.points) {
                let x = xScale.scale(point.x)
                let y = yScale.scale(point.y)
                let radius = bubbleRadius(
                    point.size, minSize, maxSize, item.minRadius, item.maxRadius
                )
                kit.circle(
                    x, y, radius,
                    fill: color, className: "bubble"
                )
                if (!point.label.isEmpty()) {
                    kit.text(
                        x, y + radius + config.theme.fontSize,
                        point.label,
                        size: config.theme.fontSize,
                        color: config.theme.textColor,
                        anchor: "middle",
                        className: "bubble-label"
                    )
                }
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}

/** 气泡半径线性映射；尺寸退化时取区间中值。 */
internal func bubbleRadius(
    size: Float64,
    minSize: Float64,
    maxSize: Float64,
    minRadius: Float64,
    maxRadius: Float64
): Float64 {
    if (maxSize <= minSize) {
        (minRadius + maxRadius) / 2.0
    } else {
        minRadius + (size - minSize) / (maxSize - minSize) * (maxRadius - minRadius)
    }
}
