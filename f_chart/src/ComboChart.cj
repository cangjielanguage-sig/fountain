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

internal enum ComboKind <: Equatable<ComboKind> {
    | Bar
    | Line
    | Scatter

    public operator func ==(that: ComboKind): Bool {
        match ((this, that)) {
            case (Bar, Bar) => true
            case (Line, Line) => true
            case (Scatter, Scatter) => true
            case _ => false
        }
    }
}

internal class ComboSeries {
    let name: String
    let kind: ComboKind
    let values: Array<?Float64>
    let points: Array<ScatterPoint>
    let color: ?String
    let stack: String
    let percent: Bool
    let rightAxis: Bool
    let symbol: String
    let symbolSize: Float64
    let smooth: Bool
    let paletteIndex: Int64

    init(
        name: String,
        kind: ComboKind,
        values: Array<?Float64>,
        points: Array<ScatterPoint>,
        color: ?String,
        stack: String,
        percent: Bool,
        rightAxis: Bool,
        symbol: String,
        symbolSize: Float64,
        smooth: Bool,
        paletteIndex: Int64
    ) {
        this.name = name
        this.kind = kind
        this.values = values
        this.points = points
        this.color = color
        this.stack = stack
        this.percent = percent
        this.rightAxis = rightAxis
        this.symbol = symbol
        this.symbolSize = symbolSize
        this.smooth = smooth
        this.paletteIndex = paletteIndex
    }
}

internal class ComboBarGroup {
    let key: String
    let percent: Bool
    let rightAxis: Bool
    let series: ArrayList<ComboSeries>

    init(key: String, percent: Bool, rightAxis: Bool) {
        this.key = key
        this.percent = percent
        this.rightAxis = rightAxis
        this.series = ArrayList<ComboSeries>()
    }
}

/**
 * M7 组合图：柱状、分组柱、堆叠柱、百分比堆叠柱、折线、散点任意叠加。
 *
 * JSON 字段见 `doc/chart-json-spec.md` 的 `combo` 小节。
 */
public class ComboChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "combo")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = parseSeries(seriesArray, config.xAxis.labels)
        let labels = config.xAxis.labels
        if (labels.isEmpty()) {
            throw chartMissingField("xAxis.labels")
        }
        validateLengths(series, labels)

        let leftRange = resolveAxisRange(config.yAxis, series, false, labels)
        let leftTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(leftRange[0], leftRange[1], config.yAxis.tickCount)
        }
        let hasRight = seriesHasRight(series)
        let rightAxis = match (config.yAxis2) {
            case Some(value) => value
            case None => ChartAxis.parse(None<ChartJson>, "linear", true)
        }
        let rightRange = if (hasRight) {
            resolveAxisRange(rightAxis, series, true, labels)
        } else {
            [0.0, 1.0]
        }
        let rightTicks = if (hasRight) {
            if (!rightAxis.values.isEmpty()) {
                rightAxis.values
            } else {
                chartNiceTicks(rightRange[0], rightRange[1], rightAxis.tickCount)
            }
        } else {
            Array<Float64>()
        }

        var maxYLabelWidth = 0.0
        for (tick in leftTicks) {
            let width = chartTextWidth(
                chartFormatTick(tick, config.yAxis.labelFormat),
                config.theme.fontSize
            )
            if (width > maxYLabelWidth) {
                maxYLabelWidth = width
            }
        }
        var rightLabelWidth = 0.0
        if (hasRight) {
            for (tick in rightTicks) {
                let width = chartTextWidth(
                    chartFormatTick(tick, rightAxis.labelFormat),
                    config.theme.fontSize
                )
                if (width > rightLabelWidth) {
                    rightLabelWidth = width
                }
            }
            rightLabelWidth += 12.0
        }

        let legendVisible = series.size > 1
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight,
            rightLabelWidth: rightLabelWidth
        )
        let band = BandScale(frame.plot.x, frame.plot.right(), labels.size)
        let leftScale = LinearScale(leftRange[0], leftRange[1], frame.plot.y, frame.plot.bottom())
        let rightScale = if (hasRight) {
            LinearScale(rightRange[0], rightRange[1], frame.plot.y, frame.plot.bottom())
        } else {
            leftScale
        }

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
        frame.drawYAxis(kit, leftTicks, leftScale)
        if (hasRight) {
            frame.drawYAxisRight(kit, rightTicks, rightScale, rightAxis)
        }

        drawBars(kit, series, config, band, labelCount(labels), leftScale, rightScale)
        drawLines(kit, series, band, leftScale, rightScale)
        drawScatters(kit, series, band, leftScale, rightScale)
        frame.drawXAxis(kit, labels, band)
        builder.toSvgString()
    }

    private func labelCount(labels: Array<String>): Int64 {
        labels.size
    }

    private func parseSeries(
        items: JsonArray,
        labels: Array<String>
    ): ArrayList<ComboSeries> {
        let series = ArrayList<ComboSeries>()
        var index = 0
        for (item in items.getItems()) {
            let path = "series[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let seriesType = json.requiredString("type")
            let name = json.string("name", default: "")
            let color = json.string("color")
            let rightAxis = json.string("axis", default: "left") == "right"
            match (seriesType) {
                case "bar" | "grouped-bar" =>
                    series.add(ComboSeries(
                        name, ComboKind.Bar, parseValues(json.requiredArray("data"), "${path}.data"),
                        Array<ScatterPoint>(), color, "",
                        false, rightAxis, "none", 6.0, false, index
                    ))
                case "stacked-bar" | "percent-stacked-bar" =>
                    let stack = json.string("stack", default: "stack")
                    series.add(ComboSeries(
                        name, ComboKind.Bar, parseValues(json.requiredArray("data"), "${path}.data"),
                        Array<ScatterPoint>(), color, stack,
                        seriesType == "percent-stacked-bar",
                        rightAxis, "none", 6.0, false, index
                    ))
                case "line" =>
                    series.add(ComboSeries(
                        name, ComboKind.Line, parseValues(json.requiredArray("data"), "${path}.data"),
                        Array<ScatterPoint>(), color, "",
                        false, rightAxis,
                        json.string("symbol", default: "none"),
                        json.number("symbolSize", default: 6.0),
                        json.bool("smooth", default: false), index
                    ))
                case "scatter" =>
                    series.add(ComboSeries(
                        name, ComboKind.Scatter, Array<?Float64>(),
                        parseScatterPoints(json.requiredArray("data"), "${path}.data", labels),
                        color, "", false, rightAxis,
                        json.string("symbol", default: "circle"),
                        json.number("symbolSize", default: 6.0),
                        false, index
                    ))
                case _ =>
                    throw ChartException(
                        "组合图不支持系列类型 ${seriesType}",
                        kind: ChartErrorKind.UnsupportedChart,
                        path: "${path}.type"
                    )
            }
            index++
        }
        series
    }

    private func parseValues(items: JsonArray, path: String): Array<?Float64> {
        let values = ArrayList<?Float64>()
        var index = 0
        for (item in items.getItems()) {
            let itemPath = "${path}[${index}]"
            if (item.kind.isNull) {
                values.add(None<Float64>)
            } else {
                values.add(Some(jsonNumberValue(item, itemPath)))
            }
            index++
        }
        values.toArray()
    }

    private func parseScatterPoints(
        items: JsonArray,
        path: String,
        labels: Array<String>
    ): Array<ScatterPoint> {
        let points = ArrayList<ScatterPoint>()
        var index = 0
        for (item in items.getItems()) {
            let itemPath = "${path}[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let xValue = json.required("x")
            let categoryIndex = if (xValue.kind.isString) {
                let name = xValue.asString().value
                var found = -1
                for (labelIndex in 0..labels.size) {
                    if (labels[labelIndex] == name) {
                        found = labelIndex
                        break
                    }
                }
                if (found < 0) {
                    throw chartInvalidValue("${itemPath}.x", "x 不是 xAxis.labels 中的类目")
                }
                found
            } else {
                Int64(jsonNumberValue(xValue, "${itemPath}.x"))
            }
            if (categoryIndex < 0 || categoryIndex >= labels.size) {
                throw chartInvalidValue("${itemPath}.x", "x 超出类目范围")
            }
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            points.add(ScatterPoint(Float64(categoryIndex), y))
            index++
        }
        points.toArray()
    }

    private func validateLengths(series: ArrayList<ComboSeries>, labels: Array<String>): Unit {
        for (index in 0..series.size) {
            let item = series[index]
            if (item.kind != ComboKind.Scatter && item.values.size != labels.size) {
                throw chartInvalidValue(
                    "series[${index}].data",
                    "数据长度 ${item.values.size} 与 xAxis.labels 长度 ${labels.size} 不一致"
                )
            }
        }
    }

    private func seriesHasRight(series: ArrayList<ComboSeries>): Bool {
        for (item in series) {
            if (item.rightAxis) {
                return true
            }
        }
        false
    }

    private func resolveAxisRange(
        axis: ChartAxis,
        series: ArrayList<ComboSeries>,
        right: Bool,
        labels: Array<String>
    ): Array<Float64> {
        var dataMin = 0.0
        var dataMax = 0.0
        var hasData = false
        var hasBar = false
        for (item in series) {
            if (item.rightAxis != right) {
                continue
            }
            if (item.kind == ComboKind.Bar) {
                hasBar = true
            }
        }
        let groups = buildBarGroups(series, right)
        for (group in groups) {
            if (group.percent) {
                dataMax = maxFloat(dataMax, 100.0)
                hasData = true
                continue
            }
            for (index in 0..labels.size) {
                var positive = 0.0
                var negative = 0.0
                var single = 0.0
                var hasSingle = false
                for (item in group.series) {
                    match (item.values[index]) {
                        case Some(value) =>
                            if (group.series.size > 1) {
                                if (value >= 0.0) {
                                    positive += value
                                } else {
                                    negative += value
                                }
                            } else {
                                single = value
                                hasSingle = true
                            }
                        case None => ()
                    }
                }
                if (hasSingle) {
                    dataMin = minFloat(dataMin, single)
                    dataMax = maxFloat(dataMax, single)
                    hasData = true
                } else if (group.series.size > 1) {
                    dataMin = minFloat(dataMin, negative)
                    dataMax = maxFloat(dataMax, positive)
                    hasData = true
                }
            }
        }
        for (item in series) {
            if (item.rightAxis != right) {
                continue
            }
            if (item.kind == ComboKind.Line) {
                for (value in item.values) {
                    match (value) {
                        case Some(number) =>
                            dataMin = minFloat(dataMin, number)
                            dataMax = maxFloat(dataMax, number)
                            hasData = true
                        case None => ()
                    }
                }
            } else if (item.kind == ComboKind.Scatter) {
                for (point in item.points) {
                    dataMin = minFloat(dataMin, point.y)
                    dataMax = maxFloat(dataMax, point.y)
                    hasData = true
                }
            }
        }
        if (!hasData) {
            return [0.0, 1.0]
        }
        if (hasBar) {
            dataMin = minFloat(0.0, dataMin)
            dataMax = maxFloat(0.0, dataMax)
        }
        lineRange(dataMin, dataMax, axis.min, axis.max, "yAxis.min")
    }

    private func buildBarGroups(
        series: ArrayList<ComboSeries>,
        right: Bool
    ): ArrayList<ComboBarGroup> {
        let groups = ArrayList<ComboBarGroup>()
        var index = 0
        for (item in series) {
            if (item.kind != ComboKind.Bar || item.rightAxis != right) {
                index++
                continue
            }
            var found: ?ComboBarGroup = None
            if (!item.stack.isEmpty()) {
                for (group in groups) {
                    if (group.key == item.stack) {
                        found = Some(group)
                        break
                    }
                }
            }
            match (found) {
                case Some(group) =>
                    group.series.add(item)
                case None =>
                    let key = if (item.stack.isEmpty()) { "__single_${index}" } else { item.stack }
                    let group = ComboBarGroup(key, item.percent, item.rightAxis)
                    group.series.add(item)
                    groups.add(group)
            }
            index++
        }
        groups
    }

    private func bodyScale(rightAxis: Bool, left: LinearScale, right: LinearScale): LinearScale {
        if (rightAxis) {
            right
        } else {
            left
        }
    }

    private func drawBars(
        kit: ChartSvgKit,
        series: ArrayList<ComboSeries>,
        config: ChartConfig,
        band: BandScale,
        labelCount: Int64,
        leftScale: LinearScale,
        rightScale: LinearScale
    ): Unit {
        let leftGroups = buildBarGroups(series, false)
        let rightGroups = buildBarGroups(series, true)
        drawBarGroups(kit, leftGroups, config, band, labelCount, leftScale, false)
        drawBarGroups(kit, rightGroups, config, band, labelCount, rightScale, true)
    }

    private func drawBarGroups(
        kit: ChartSvgKit,
        groups: ArrayList<ComboBarGroup>,
        config: ChartConfig,
        band: BandScale,
        labelCount: Int64,
        scale: LinearScale,
        right: Bool
    ): Unit {
        if (groups.isEmpty()) {
            return
        }
        let groupCount = groups.size
        let slot = band.bandWidth / Float64(groupCount)
        let barWidth = slot * 0.6
        for (groupIndex in 0..groups.size) {
            let group = groups[groupIndex]
            for (index in 0..labelCount) {
                let x = band.bandStart(index) + Float64(groupIndex) * slot + (slot - barWidth) / 2.0
                if (group.series.size == 1 && !group.percent) {
                    let item = group.series[0]
                    match (item.values[index]) {
                        case Some(value) =>
                            let baseline = scale.scale(0.0)
                            let valueY = scale.scale(value)
                            let className = if (value < 0.0) { "bar bar-negative" } else { "bar" }
                            let color = match (item.color) {
                                case Some(value) => value
                                case None => config.theme.colorAt(group.series[0].paletteIndex)
                            }
                            kit.rect(
                                x, minFloat(valueY, baseline), barWidth, abs(valueY - baseline),
                                fill: color, className: className
                            )
                        case None => ()
                    }
                } else {
                    var total = 0.0
                    for (item in group.series) {
                        match (item.values[index]) {
                            case Some(value) => total += abs(value)
                            case None => ()
                        }
                    }
                    if (group.percent && total <= 0.0) {
                        continue
                    }
                    var cumulative = 0.0
                    for (item in group.series) {
                        match (item.values[index]) {
                            case Some(value) =>
                                let portion = if (group.percent) {
                                    percentStackedValue(value, total)
                                } else {
                                    value
                                }
                                let from = scale.scale(cumulative)
                                let to = scale.scale(cumulative + portion)
                                let color = match (item.color) {
                                    case Some(itemColor) => itemColor
                                    case None => config.theme.colorAt(group.series[0].paletteIndex)
                                }
                                let className = if (portion < 0.0 && !group.percent) {
                                    "bar bar-negative"
                                } else {
                                    "bar"
                                }
                                kit.rect(
                                    x, minFloat(from, to), barWidth, abs(to - from),
                                    fill: color, className: className
                                )
                                cumulative += portion
                            case None => ()
                        }
                    }
                }
            }
        }
    }

    private func drawLines(
        kit: ChartSvgKit,
        series: ArrayList<ComboSeries>,
        band: BandScale,
        leftScale: LinearScale,
        rightScale: LinearScale
    ): Unit {
        for (item in series) {
            if (item.kind != ComboKind.Line) {
                continue
            }
            let scale = bodyScale(item.rightAxis, leftScale, rightScale)
            let segment = ArrayList<LinePixel>()
            for (index in 0..item.values.size) {
                match (item.values[index]) {
                    case Some(value) =>
                        segment.add(LinePixel(band.center(index), scale.scale(value)))
                    case None =>
                        flushLine(kit, item, segment)
                }
            }
            flushLine(kit, item, segment)
        }
    }

    private func flushLine(kit: ChartSvgKit, item: ComboSeries, segment: ArrayList<LinePixel>): Unit {
        if (segment.size >= 2) {
            let builder = StringBuilder()
            builder.append("M ${formatSvgNumber(segment[0].x)} ${formatSvgNumber(segment[0].y)}")
            var index = 1
            while (index < segment.size) {
                if (item.smooth) {
                    let control = segment[index - 1]
                    let current = segment[index]
                    builder.append(
                        " Q ${formatSvgNumber(control.x)} ${formatSvgNumber(control.y)} " +
                        "${formatSvgNumber(current.x)} ${formatSvgNumber(current.y)}"
                    )
                } else {
                    let current = segment[index]
                    builder.append(
                        " L ${formatSvgNumber(current.x)} ${formatSvgNumber(current.y)}"
                    )
                }
                index++
            }
            let color = match (item.color) {
                case Some(value) => value
                case None => "#4e79a7"
            }
            kit.path(builder.toString(), fill: "none", stroke: color, strokeWidth: 2.0, className: "line")
        }
        segment.clear()
    }

    private func drawScatters(
        kit: ChartSvgKit,
        series: ArrayList<ComboSeries>,
        band: BandScale,
        leftScale: LinearScale,
        rightScale: LinearScale
    ): Unit {
        for (item in series) {
            if (item.kind != ComboKind.Scatter) {
                continue
            }
            let scale = bodyScale(item.rightAxis, leftScale, rightScale)
            let color = match (item.color) {
                case Some(value) => value
                case None => "#4e79a7"
            }
            for (point in item.points) {
                let cx = band.center(Int64(point.x))
                let cy = scale.scale(point.y)
                match (item.symbol) {
                    case "square" => kit.square(cx, cy, item.symbolSize, fill: color, className: "symbol")
                    case "diamond" => kit.diamond(cx, cy, item.symbolSize, fill: color, className: "symbol")
                    case "none" => ()
                    case _ => kit.circle(cx, cy, item.symbolSize / 2.0, fill: color, className: "symbol")
                }
            }
        }
    }
}
