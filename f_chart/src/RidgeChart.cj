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

/** 山脊图的一个分布。 */
internal class RidgeSeries {
    let name: String
    let values: Array<Float64>
    let color: ?String
    let bandwidth: ?Float64
    let overlap: Float64

    init(
        name: String,
        values: Array<Float64>,
        color: ?String,
        bandwidth: ?Float64,
        overlap: Float64
    ) {
        this.name = name
        this.values = values
        this.color = color
        this.bandwidth = bandwidth
        this.overlap = overlap
    }
}

/**
 * M24 山脊图。
 *
 * 多组核密度曲线逐行错位排列，用重叠展示分布变化。
 */
public class RidgeChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "ridge")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<RidgeSeries>()
        var seriesIndex = 0
        for (item in seriesArray.getItems()) {
            let path = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: "")
            let dataArray = json.requiredArray("data")
            let items = dataArray.getItems()
            if (items.isEmpty()) {
                throw chartInvalidValue("${path}.data", "数据不能为空")
            }
            let values = ArrayList<Float64>()
            var valueIndex = 0
            for (entry in items) {
                let itemPath = "${path}.data[${valueIndex}]"
                if (!(entry.kind.isInt || entry.kind.isDecimal)) {
                    throw chartInvalidValue(itemPath, "期望数字")
                }
                values.add(jsonNumberValue(entry, itemPath))
                valueIndex++
            }
            let bandwidth = match (json.number("bandwidth")) {
                case Some(value) =>
                    if (value <= 0.0 || value.isNaN() || value.isInf()) {
                        throw chartInvalidValue("${path}.bandwidth", "带宽必须大于 0")
                    }
                    Some(value)
                case None => None<Float64>
            }
            let overlap = json.number("overlap", default: 0.5)
            if (overlap < 0.0 || overlap > 1.0 || overlap.isNaN() || overlap.isInf()) {
                throw chartInvalidValue("${path}.overlap", "重叠系数必须在 0 到 1 之间")
            }
            let color = json.string("color")
            series.add(RidgeSeries(name, values.toArray(), color, bandwidth, overlap))
            seriesIndex++
        }
        let labels = config.yAxis.labels
        if (!labels.isEmpty() && labels.size != series.size) {
            throw chartInvalidValue(
                "yAxis.labels",
                "标签长度 ${labels.size} 与系列数 ${series.size} 不一致"
            )
        }

        var dataMin = series[0].values[0]
        var dataMax = series[0].values[0]
        for (item in series) {
            for (value in item.values) {
                dataMin = minFloat(dataMin, value)
                dataMax = maxFloat(dataMax, value)
            }
        }
        let xRange = resolveXRange(config.xAxis, dataMin, dataMax)
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(xRange[0], xRange[1], config.xAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let frame = ChartFrame(config, false, 56.0, config.theme.fontSize + 12.0)
        let xScale = LinearScale(xRange[0], xRange[1], frame.plot.right(), frame.plot.x)
        let bandHeight = frame.plot.height / Float64(series.size)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        var row = series.size - 1
        while (row >= 0) {
            let item = series[row]
            let baseline = frame.plot.bottom() - Float64(row) * bandHeight
            let bandwidth = match (item.bandwidth) {
                case Some(value) => value
                case None => defaultBandwidth(item.values)
            }
            let amplitude = ridgeAmplitude(bandHeight, item.overlap)
            let points = ArrayList<Float64>()
            let densities = ArrayList<Float64>()
            var peak = 0.0
            for (step in 0..=80) {
                let x = xRange[0] + (xRange[1] - xRange[0]) * Float64(step) / 80.0
                let density = gaussianKde(item.values, bandwidth, x)
                if (density > peak) {
                    peak = density
                }
                points.add(x)
                densities.add(density)
            }
            if (peak > 0.0) {
                let color = match (item.color) {
                    case Some(value) => value
                    case None => config.theme.colorAt(row)
                }
                let path = StringBuilder()
                path.append(
                    "M ${formatSvgNumber(xScale.scale(points[0]))} ${formatSvgNumber(baseline)}"
                )
                for (step in 0..points.size) {
                    let y = baseline - densities[step] / peak * amplitude
                    path.append(
                        " L ${formatSvgNumber(xScale.scale(points[step]))} ${formatSvgNumber(y)}"
                    )
                }
                path.append(
                    " L ${formatSvgNumber(xScale.scale(points[points.size - 1]))} " +
                    "${formatSvgNumber(baseline)} Z"
                )
                kit.path(
                    path.toString(), fill: color, stroke: color, strokeWidth: 1.5,
                    className: "ridge-area", fillOpacity: 0.55
                )
                let line = StringBuilder()
                var started = false
                for (step in 0..points.size) {
                    let y = baseline - densities[step] / peak * amplitude
                    if (!started) {
                        line.append(
                            "M ${formatSvgNumber(xScale.scale(points[step]))} ${formatSvgNumber(y)}"
                        )
                        started = true
                    } else {
                        line.append(
                            " L ${formatSvgNumber(xScale.scale(points[step]))} ${formatSvgNumber(y)}"
                        )
                    }
                }
                kit.path(
                    line.toString(), fill: "none", stroke: color, strokeWidth: 1.5,
                    className: "ridge-line"
                )
            }
            let label = if (row < labels.size) { labels[row] } else { item.name }
            kit.text(
                frame.plot.x - 8.0, baseline,
                label,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "ridge-label"
            )
            row--
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }

    private func resolveXRange(axis: ChartAxis, dataMin: Float64, dataMax: Float64): Array<Float64> {
        let span = dataMax - dataMin
        let padding = if (abs(span) < 1e-12) { 1.0 } else { abs(span) * 0.05 }
        let minimum = match (axis.min) {
            case Some(value) => value
            case None => dataMin - padding
        }
        let maximum = match (axis.max) {
            case Some(value) => value
            case None => dataMax + padding
        }
        if (maximum <= minimum) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        [minimum, maximum]
    }
}

/** 山脊曲线振幅。 */
internal func ridgeAmplitude(bandHeight: Float64, overlap: Float64): Float64 {
    bandHeight * (0.8 + 0.4 * overlap)
}
