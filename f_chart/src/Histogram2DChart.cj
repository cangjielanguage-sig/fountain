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

/** 二维点。 */
internal class Point2D {
    let x: Float64
    let y: Float64

    init(x: Float64, y: Float64) {
        this.x = x
        this.y = y
    }
}

/** 二维分箱结果。 */
internal class Histogram2DResult {
    let xMin: Float64
    let xMax: Float64
    let yMin: Float64
    let yMax: Float64
    let binsX: Int64
    let binsY: Int64
    let counts: Array<Int64>

    init(
        xMin: Float64,
        xMax: Float64,
        yMin: Float64,
        yMax: Float64,
        binsX: Int64,
        binsY: Int64,
        counts: Array<Int64>
    ) {
        this.xMin = xMin
        this.xMax = xMax
        this.yMin = yMin
        this.yMax = yMax
        this.binsX = binsX
        this.binsY = binsY
        this.counts = counts
    }

    func countAt(xIndex: Int64, yIndex: Int64): Int64 {
        this.counts[yIndex * this.binsX + xIndex]
    }
}

/**
 * M25 二维直方图 / 六边形分箱图。
 *
 * 统计 `{x,y}` 点的二维频数，并按频数映射颜色。
 */
public class Histogram2DChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "2d-histogram")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "二维直方图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let items = dataArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let points = ArrayList<Point2D>()
        var index = 0
        for (item in items) {
            let itemPath = "series[0].data[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let xValue = json.required("x")
            let yValue = json.required("y")
            let x = jsonNumberValue(xValue, "${itemPath}.x")
            let y = jsonNumberValue(yValue, "${itemPath}.y")
            points.add(Point2D(x, y))
            index++
        }

        var binsX = 20
        var binsY = 20
        match (seriesJson.value("bins")) {
            case Some(value) =>
                if (!value.kind.isArray) {
                    throw chartInvalidValue("series[0].bins", "期望 [x分箱, y分箱]")
                }
                let binItems = value.asArray().getItems()
                if (binItems.size != 2) {
                    throw chartInvalidValue("series[0].bins", "期望两个分箱数")
                }
                binsX = parseBinCount(binItems[0], "series[0].bins[0]")
                binsY = parseBinCount(binItems[1], "series[0].bins[1]")
            case None => ()
        }
        let shape = seriesJson.string("shape", default: "hexagon")
        if (shape != "hexagon" && shape != "square") {
            throw chartInvalidValue("series[0].shape", "期望 hexagon / square")
        }

        let result = histogram2DCounts(points.toArray(), binsX, binsY)
        var maxCount = 0
        for (value in result.counts) {
            if (value > maxCount) {
                maxCount = value
            }
        }
        let xRange = resolveRange(config.xAxis, result.xMin, result.xMax, "xAxis.min")
        let yRange = resolveRange(config.yAxis, result.yMin, result.yMax, "yAxis.min")
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
        let frame = ChartFrame(config, false, maxYLabelWidth + 12.0, config.theme.fontSize + 12.0)
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
        frame.drawYAxis(kit, yTicks, yScale)

        let cellWidth = (result.xMax - result.xMin) / Float64(result.binsX)
        let cellHeight = (result.yMax - result.yMin) / Float64(result.binsY)
        for (yIndex in 0..result.binsY) {
            for (xIndex in 0..result.binsX) {
                let frequency = result.countAt(xIndex, yIndex)
                if (frequency <= 0) {
                    continue
                }
                let ratio = if (maxCount > 0) {
                    Float64(frequency) / Float64(maxCount)
                } else {
                    0.0
                }
                let color = heatColor(ratio)
                let startX = result.xMin + Float64(xIndex) * cellWidth
                let startY = result.yMin + Float64(yIndex) * cellHeight
                if (shape == "square") {
                    let left = xScale.scale(startX)
                    let right = xScale.scale(startX + cellWidth)
                    let top = yScale.scale(startY + cellHeight)
                    let bottom = yScale.scale(startY)
                    kit.rect(
                        left, top, right - left, bottom - top,
                        fill: color, className: "cell"
                    )
                } else {
                    let centerX = xScale.scale(startX + cellWidth / 2.0)
                    let centerY = yScale.scale(startY + cellHeight / 2.0)
                    let radius = minFloat(
                        abs(xScale.scale(startX + cellWidth) - xScale.scale(startX)),
                        abs(yScale.scale(startY + cellHeight) - yScale.scale(startY))
                    ) * 0.55
                    kit.path(
                        hexagonPath(centerX, centerY, radius),
                        fill: color,
                        className: "hexagon"
                    )
                }
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func parseBinCount(value: JsonValue, path: String): Int64 {
        if (!(value.kind.isInt || value.kind.isDecimal)) {
            throw chartInvalidValue(path, "期望正整数")
        }
        let raw = jsonNumberValue(value, path)
        if (raw < 1.0 || raw != floor(raw)) {
            throw chartInvalidValue(path, "分箱数必须为正整数")
        }
        Int64(raw)
    }

    private func resolveRange(
        axis: ChartAxis,
        dataMin: Float64,
        dataMax: Float64,
        path: String
    ): Array<Float64> {
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => dataMax
        }
        if (maximum <= minimum) {
            throw chartInvalidValue(path, "轴范围必须递增")
        }
        [minimum, maximum]
    }
}

/** 二维等宽分箱；退化为单点时在两侧各扩 0.5。 */
internal func histogram2DCounts(
    points: Array<Point2D>,
    binsX: Int64,
    binsY: Int64
): Histogram2DResult {
    if (points.isEmpty()) {
        throw chartInvalidValue("series[0].data", "数据不能为空")
    }
    if (binsX <= 0 || binsY <= 0) {
        throw chartInvalidValue("series[0].bins", "分箱数必须为正整数")
    }
    var xMin = points[0].x
    var xMax = points[0].x
    var yMin = points[0].y
    var yMax = points[0].y
    for (point in points) {
        xMin = minFloat(xMin, point.x)
        xMax = maxFloat(xMax, point.x)
        yMin = minFloat(yMin, point.y)
        yMax = maxFloat(yMax, point.y)
    }
    if (xMax == xMin) {
        xMin -= 0.5
        xMax += 0.5
    }
    if (yMax == yMin) {
        yMin -= 0.5
        yMax += 0.5
    }
    let width = (xMax - xMin) / Float64(binsX)
    let height = (yMax - yMin) / Float64(binsY)
    let counts = ArrayList<Int64>()
    for (_ in 0..(binsX * binsY)) {
        counts.add(0)
    }
    for (point in points) {
        var xIndex = Int64(floor((point.x - xMin) / width))
        var yIndex = Int64(floor((point.y - yMin) / height))
        if (xIndex < 0) {
            xIndex = 0
        }
        if (xIndex >= binsX) {
            xIndex = binsX - 1
        }
        if (yIndex < 0) {
            yIndex = 0
        }
        if (yIndex >= binsY) {
            yIndex = binsY - 1
        }
        let position = yIndex * binsX + xIndex
        counts[position] = counts[position] + 1
    }
    Histogram2DResult(xMin, xMax, yMin, yMax, binsX, binsY, counts.toArray())
}

/** 频数比例 → 蓝色梯度。 */
internal func heatColor(ratio: Float64): String {
    if (ratio >= 0.75) {
        "#08306b"
    } else if (ratio >= 0.5) {
        "#2171b5"
    } else if (ratio >= 0.25) {
        "#6baed6"
    } else {
        "#c6dbef"
    }
}

/** 正六边形路径。 */
internal func hexagonPath(cx: Float64, cy: Float64, radius: Float64): String {
    let builder = StringBuilder()
    for (index in 0..6) {
        let angle = 3.141592653589793 / 3.0 * Float64(index) - 3.141592653589793 / 6.0
        let x = cx + radius * cos(angle)
        let y = cy + radius * sin(angle)
        if (index == 0) {
            builder.append("M ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
        } else {
            builder.append(" L ${formatSvgNumber(x)} ${formatSvgNumber(y)}")
        }
    }
    builder.append(" Z")
    builder.toString()
}
