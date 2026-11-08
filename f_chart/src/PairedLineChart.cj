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

/** 配对连线图的一个受试对象。 */
internal class PairedItem {
    let name: String
    let before: Float64
    let after: Float64

    init(name: String, before: Float64, after: Float64) {
        this.name = name
        this.before = before
        this.after = after
    }
}

/** M80 配对连线图。 */
public class PairedLineChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "paired-line")
        let root = ChartJson.of(data)
        let labels = if (config.xAxis.labels.isEmpty()) {
            ["前", "后"]
        } else {
            config.xAxis.labels
        }
        if (labels.size != 2) {
            throw chartInvalidValue("xAxis.labels", "配对连线图必须恰好 2 个时间点")
        }

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "配对连线图仅支持 1 个系列")
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
        let items = ArrayList<PairedItem>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let name = json.string("name", default: (itemIndex + 1).toString())
            let before = bulletNumber(json, "before", itemPath)
            let after = bulletNumber(json, "after", itemPath)
            items.add(PairedItem(name, before, after))
            itemIndex++
        }

        var dataMin = items[0].before
        var dataMax = items[0].before
        for (item in items) {
            dataMin = minFloat(dataMin, minFloat(item.before, item.after))
            dataMax = maxFloat(dataMax, maxFloat(item.before, item.after))
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

        var maxLabelWidth = 0.0
        for (item in items) {
            maxLabelWidth = maxFloat(
                maxLabelWidth, chartTextWidth(item.name, config.theme.fontSize)
            )
        }
        var maxYTickWidth = 0.0
        for (tick in yTicks) {
            maxYTickWidth = maxFloat(
                maxYTickWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let legendVisible = config.legend.show && !seriesName.isEmpty()
        let frame = ChartFrame(
            config, legendVisible, maxYTickWidth + 12.0, config.theme.fontSize + 12.0,
            rightLabelWidth: maxLabelWidth + 16.0
        )
        let band = BandScale(frame.plot.x, frame.plot.right(), 2)
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

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [config.theme.colorAt(0)]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let leftX = band.center(0)
        let rightX = band.center(1)
        for (index in 0..items.size) {
            let item = items[index]
            let color = config.theme.colorAt(index)
            let startY = yScale.scale(item.before)
            let endY = yScale.scale(item.after)
            kit.line(
                leftX, startY, rightX, endY,
                stroke: color, strokeWidth: 1.5, className: "paired-line"
            )
            kit.circle(leftX, startY, 3.5, fill: color, className: "paired-point")
            kit.circle(rightX, endY, 3.5, fill: color, className: "paired-point")
            kit.text(
                rightX + 8.0,
                endY + config.theme.fontSize / 3.0,
                item.name,
                size: config.theme.fontSize,
                color: color,
                className: "paired-label"
            )
        }
        frame.drawXAxis(kit, labels, band)
        builder.toSvgString()
    }
}
