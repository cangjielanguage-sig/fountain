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
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 残差数据点：拟合值与残差。 */
internal class ResidualPoint {
    let x: Float64
    let y: Float64

    init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

/** M40 残差图：拟合值对残差散点，附 y=0 参考线。 */
public class ResidualChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "residual")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "残差图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let points = ArrayList<ResidualPoint>()
        let xs = ArrayList<Float64>()
        let ys = ArrayList<Float64>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x, y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = jsonNumberValue(json.required("x"), "${itemPath}.x")
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            points.add(ResidualPoint(x, y))
            xs.add(x)
            ys.add(y)
            index++
        }

        let xRange = residualXRange(config.xAxis, xs.toArray())
        let yRange = residualYRange(config.yAxis, ys.toArray())
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
        let xLabels = ArrayList<String>()
        for (tick in xTicks) {
            xLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show && !(seriesName.isEmpty())
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
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight
        )
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.x, frame.plot.right())
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

        let pointColor = config.theme.colorAt(0)
        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [pointColor]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        kit.line(
            frame.plot.x, yScale.scale(0.0), frame.plot.right(), yScale.scale(0.0),
            stroke: "#607d8b", strokeWidth: 1.0, className: "residual-zero", dash: "6 4"
        )
        for (point in points) {
            kit.circle(
                xScale.scale(point.x), yScale.scale(point.y), 4.0,
                fill: pointColor, className: "residual-point"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xLabels.toArray())
        builder.toSvgString()
    }
}

/** x 轴范围：覆盖全部拟合值，未显式指定时两侧留 5% 余量。 */
internal func residualXRange(axis: ChartAxis, values: Array<Float64>): Array<Float64> {
    residualRange(axis, values, 0.05, false, "xAxis")
}

/** y 轴范围：覆盖全部残差且必须包含 0。 */
internal func residualYRange(axis: ChartAxis, values: Array<Float64>): Array<Float64> {
    residualRange(axis, values, 0.08, true, "yAxis")
}

private func residualRange(
    axis: ChartAxis,
    values: Array<Float64>,
    padding: Float64,
    includeZero: Bool,
    axisName: String
): Array<Float64> {
    if (values.isEmpty()) {
        throw chartInvalidValue("series[0].data", "数据不能为空")
    }
    var dataMin = values[0]
    var dataMax = values[0]
    for (value in values) {
        dataMin = minFloat(dataMin, value)
        dataMax = maxFloat(dataMax, value)
    }
    if (includeZero) {
        dataMin = minFloat(dataMin, 0.0)
        dataMax = maxFloat(dataMax, 0.0)
    }
    var span = dataMax - dataMin
    if (span <= 0.0) {
        span = 1.0
    }
    var minimum = match (axis.min) {
        case Some(value) => value
        case None => dataMin - span * padding
    }
    var maximum = match (axis.max) {
        case Some(value) => value
        case None => dataMax + span * padding
    }
    if (includeZero) {
        minimum = minFloat(minimum, 0.0)
        maximum = maxFloat(maximum, 0.0)
    }
    if (maximum <= minimum) {
        throw chartInvalidValue("${axisName}.min", "${axisName}.min 必须小于 ${axisName}.max")
    }
    [minimum, maximum]
}
