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

/** 曼哈顿图的一个位点。 */
internal class ManhattanPoint {
    let x: Float64
    let y: Float64
    let chromosome: String

    init(x: Float64, y: Float64, chromosome: String) {
        this.x = x
        this.y = y
        this.chromosome = chromosome
    }
}

/** M93 曼哈顿图。 */
public class ManhattanChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "manhattan")
        let root = ChartJson.of(data)
        let gap = root.number("chromosomeGap", default: 0.0)
        if (gap < 0.0) {
            throw chartInvalidValue("chromosomeGap", "染色体间距不能为负")
        }
        let threshold = root.number("threshold")

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "曼哈顿图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let seriesName = seriesJson.string("name", default: "")
        let dataArray = seriesJson.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let points = ArrayList<ManhattanPoint>()
        let xs = ArrayList<Float64>()
        let chromosomes = ArrayList<String>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {x,y,chromosome} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = volcanoNumber(json, "x", itemPath)
            let y = volcanoNumber(json, "y", itemPath)
            let chromosome = json.requiredString("chromosome")
            if (chromosome.isEmpty()) {
                throw chartInvalidValue("${itemPath}.chromosome", "染色体不能为空")
            }
            points.add(ManhattanPoint(x, y, chromosome))
            xs.add(x)
            chromosomes.add(chromosome)
            itemIndex++
        }
        let pointArray = points.toArray()
        let positions = manhattanPositions(xs.toArray(), chromosomes.toArray(), gap)

        var xMin = positions[0]
        var xMax = positions[0]
        var yMin = pointArray[0].y
        var yMax = match (threshold) {
            case Some(value) => value
            case None => pointArray[0].y
        }
        for (index in 0..positions.size) {
            xMin = minFloat(xMin, positions[index])
            xMax = maxFloat(xMax, positions[index])
            yMin = minFloat(yMin, pointArray[index].y)
            yMax = maxFloat(yMax, pointArray[index].y)
        }
        var xSpan = xMax - xMin
        if (xSpan <= 0.0) {
            xSpan = 1.0
        }
        var ySpan = yMax - yMin
        if (ySpan <= 0.0) {
            ySpan = 1.0
        }
        let axisMinX = match (config.xAxis.min) {
            case Some(value) => value
            case None => xMin - xSpan * 0.02
        }
        let axisMaxX = match (config.xAxis.max) {
            case Some(value) => value
            case None => xMax + xSpan * 0.02
        }
        let axisMinY = match (config.yAxis.min) {
            case Some(value) => value
            case None => maxFloat(0.0, yMin - ySpan * 0.05)
        }
        let axisMaxY = match (config.yAxis.max) {
            case Some(value) => value
            case None => yMax + ySpan * 0.08
        }
        if (axisMaxX <= axisMinX) {
            throw chartInvalidValue("xAxis.min", "xAxis.min 必须小于 xAxis.max")
        }
        if (axisMaxY <= axisMinY) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let xTicks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(axisMinX, axisMaxX, config.xAxis.tickCount)
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(axisMinY, axisMaxY, config.yAxis.tickCount)
        }
        let xTickLabels = ArrayList<String>()
        for (tick in xTicks) {
            xTickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            maxYLabelWidth = maxFloat(
                maxYLabelWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let legendVisible = config.legend.show && !seriesName.isEmpty()
        let frame = ChartFrame(
            config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight,
            rightLabelWidth: 52.0
        )
        let xScale = LinearScale(axisMinX, axisMaxX, frame.plot.x, frame.plot.right())
        let yScale = LinearScale(axisMinY, axisMaxY, frame.plot.bottom(), frame.plot.y)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [config.theme.colorAt(0)]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        match (threshold) {
            case Some(value) =>
                let y = yScale.scale(value)
                kit.line(
                    frame.plot.x, y, frame.plot.right(), y,
                    stroke: "#e53935", strokeWidth: 1.0,
                    className: "manhattan-threshold", dash: "6 4"
                )
                kit.text(
                    frame.plot.right() + 6.0, y,
                    chartFormatTick(value, config.yAxis.labelFormat),
                    size: config.theme.fontSize - 1.0,
                    color: "#e53935",
                    className: "manhattan-threshold-label"
                )
            case None => ()
        }

        let chromosomeOrder = ArrayList<String>()
        for (point in pointArray) {
            if (!chromosomeOrder.contains(point.chromosome)) {
                chromosomeOrder.add(point.chromosome)
            }
        }
        for (index in 0..pointArray.size) {
            let chromosomeIndex = chromosomeIndexOf(chromosomeOrder, pointArray[index].chromosome)
            let color = config.theme.colorAt(chromosomeIndex)
            kit.circle(
                xScale.scale(positions[index]),
                yScale.scale(pointArray[index].y),
                3.0,
                fill: color,
                className: "manhattan-point"
            )
        }
        frame.drawXAxisNumeric(kit, xTicks, xScale, xTickLabels.toArray())
        builder.toSvgString()
    }
}

/** 在染色体顺序表中查找下标，未找到返回 0。 */
internal func chromosomeIndexOf(order: ArrayList<String>, chromosome: String): Int64 {
    for (index in 0..order.size) {
        if (order[index] == chromosome) {
            return index
        }
    }
    0
}

/** 按染色体首次出现顺序插入间隔，返回显示横坐标。 */
internal func manhattanPositions(
    xs: Array<Float64>,
    chromosomes: Array<String>,
    gap: Float64
): Array<Float64> {
    let order = ArrayList<String>()
    for (chromosome in chromosomes) {
        if (!order.contains(chromosome)) {
            order.add(chromosome)
        }
    }
    let positions = ArrayList<Float64>()
    for (value in xs) {
        positions.add(value)
    }
    var offset = 0.0
    var previousMax = 0.0
    var firstGroup = true
    for (chromosome in order) {
        var groupMin = 0.0
        var groupMax = 0.0
        var groupHasValue = false
        for (index in 0..xs.size) {
            if (chromosomes[index] != chromosome) {
                continue
            }
            if (!groupHasValue) {
                groupMin = xs[index]
                groupMax = xs[index]
                groupHasValue = true
            } else {
                groupMin = minFloat(groupMin, xs[index])
                groupMax = maxFloat(groupMax, xs[index])
            }
        }
        if (!groupHasValue) {
            continue
        }
        if (!firstGroup) {
            offset = previousMax + gap - groupMin + offset
        }
        for (index in 0..xs.size) {
            if (chromosomes[index] == chromosome) {
                positions[index] = xs[index] + offset
            }
        }
        previousMax = groupMax
        firstGroup = false
    }
    positions.toArray()
}
