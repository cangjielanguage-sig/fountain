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

/** 等高线网格点。 */
internal class ContourPoint {
    let x: Float64
    let y: Float64
    let value: Float64

    init(x: Float64, y: Float64, value: Float64) {
        this.x = x
        this.y = y
        this.value = value
    }
}

/**
 * M29 等高线图。
 *
 * 把规则网格的值分层着色，并在层边界绘制等值线。
 */
public class ContourChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "contour")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "等高线图仅支持 1 个系列")
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
        let points = ArrayList<ContourPoint>()
        var pointIndex = 0
        for (item in items) {
            let itemPath = "series[0].data[${pointIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y,value} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = jsonNumberValue(json.required("x"), "${itemPath}.x")
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            points.add(ContourPoint(x, y, value))
            pointIndex++
        }

        let xs = uniqueSorted(points, true)
        let ys = uniqueSorted(points, false)
        if (xs.size < 2 || ys.size < 2) {
            throw chartInvalidValue("series[0].data", "网格至少需要 2×2 个点")
        }
        if (points.size != xs.size * ys.size) {
            throw chartInvalidValue("series[0].data", "网格不完整或存在重复坐标")
        }
        let values = ArrayList<Float64>()
        for (_ in 0..(xs.size * ys.size)) {
            values.add(0.0 / 0.0)
        }
        var dataMin = points[0].value
        var dataMax = points[0].value
        for (point in points) {
            let xIndex = indexOf(xs, point.x)
            let yIndex = indexOf(ys, point.y)
            let position = yIndex * xs.size + xIndex
            if (!values[position].isNaN()) {
                throw chartInvalidValue("series[0].data", "网格存在重复坐标")
            }
            values[position] = point.value
            dataMin = minFloat(dataMin, point.value)
            dataMax = maxFloat(dataMax, point.value)
        }
        for (value in values) {
            if (value.isNaN()) {
                throw chartInvalidValue("series[0].data", "网格不完整")
            }
        }

        let levels = resolveLevels(root.value("levels"))
        let interpolate = root.string("interpolate", default: "linear")
        if (interpolate != "linear" && interpolate != "nearest") {
            throw chartInvalidValue("interpolate", "期望 linear / nearest")
        }

        let xRange = resolveRange(config.xAxis, xs[0], xs[xs.size - 1], "xAxis.min")
        let yRange = resolveRange(config.yAxis, ys[0], ys[ys.size - 1], "yAxis.min")
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

        let bands = ArrayList<Int64>()
        for (value in values) {
            bands.add(contourLevel(value, dataMin, dataMax, levels))
        }
        for (yIndex in 0..(ys.size - 1)) {
            for (xIndex in 0..(xs.size - 1)) {
                let band = bands[yIndex * xs.size + xIndex]
                let ratio = if (levels <= 1) {
                    0.5
                } else {
                    Float64(band) / Float64(levels - 1)
                }
                let left = xScale.scale(xs[xIndex])
                let right = xScale.scale(xs[xIndex + 1])
                let top = yScale.scale(ys[yIndex + 1])
                let bottom = yScale.scale(ys[yIndex])
                kit.rect(
                    left, top, right - left, bottom - top,
                    fill: heatColor(ratio), className: "contour-cell"
                )
            }
        }
        for (yIndex in 0..ys.size) {
            for (xIndex in 0..xs.size) {
                let band = bands[yIndex * xs.size + xIndex]
                if (xIndex + 1 < xs.size && yIndex + 1 < ys.size) {
                    let rightBand = bands[yIndex * xs.size + xIndex + 1]
                    if (rightBand != band) {
                        let x = xScale.scale(xs[xIndex + 1])
                        kit.line(
                            x, yScale.scale(ys[yIndex + 1]),
                            x, yScale.scale(ys[yIndex]),
                            stroke: "#444444", strokeWidth: 0.8, className: "contour-line"
                        )
                    }
                }
                if (yIndex + 1 < ys.size && xIndex + 1 < xs.size) {
                    let topBand = bands[(yIndex + 1) * xs.size + xIndex]
                    if (topBand != band) {
                        let y = yScale.scale(ys[yIndex + 1])
                        kit.line(
                            xScale.scale(xs[xIndex]), y,
                            xScale.scale(xs[xIndex + 1]), y,
                            stroke: "#444444", strokeWidth: 0.8, className: "contour-line"
                        )
                    }
                }
            }
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func uniqueSorted(points: ArrayList<ContourPoint>, useX: Bool): Array<Float64> {
        let unique = ArrayList<Float64>()
        for (point in points) {
            let value = if (useX) { point.x } else { point.y }
            var found = false
            for (existing in unique) {
                if (existing == value) {
                    found = true
                    break
                }
            }
            if (!found) {
                unique.add(value)
            }
        }
        for (i in 1..unique.size) {
            var j = i
            while (j > 0 && unique[j] < unique[j - 1]) {
                let temporary = unique[j]
                unique[j] = unique[j - 1]
                unique[j - 1] = temporary
                j--
            }
        }
        unique.toArray()
    }

    private func indexOf(values: Array<Float64>, target: Float64): Int64 {
        for (index in 0..values.size) {
            if (values[index] == target) {
                return index
            }
        }
        0
    }

    private func resolveLevels(value: ?JsonValue): Int64 {
        match (value) {
            case Some(item) =>
                if (item.kind.isArray) {
                    let items = item.asArray().getItems()
                    if (items.isEmpty()) {
                        throw chartInvalidValue("levels", "层级数组不能为空")
                    }
                    return items.size
                }
                if (!(item.kind.isInt || item.kind.isDecimal)) {
                    throw chartInvalidValue("levels", "期望正整数或递增数组")
                }
                let raw = jsonNumberValue(item, "levels")
                if (raw < 1.0 || raw != floor(raw)) {
                    throw chartInvalidValue("levels", "层级必须为正整数")
                }
                Int64(raw)
            case None => 8
        }
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

/** 值 → 层级下标，钳制到 `[0, levels-1]`。 */
internal func contourLevel(value: Float64, minimum: Float64, maximum: Float64, levels: Int64): Int64 {
    if (levels <= 1 || maximum <= minimum) {
        return 0
    }
    var band = Int64(floor((value - minimum) / (maximum - minimum) * Float64(levels)))
    if (band < 0) {
        band = 0
    }
    if (band >= levels) {
        band = levels - 1
    }
    band
}
