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

/** 哑铃图的一个数据项。 */
internal class DumbbellItem {
    let name: String
    let low: Float64
    let high: Float64

    init(name: String, low: Float64, high: Float64) {
        this.name = name
        this.low = low
        this.high = high
    }
}

/** M77 哑铃图。 */
public class DumbbellChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "dumbbell")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "哑铃图仅支持 1 个系列")
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
        let items = ArrayList<DumbbellItem>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let name = json.string("name", default: (itemIndex + 1).toString())
            let low = bulletNumber(json, "low", itemPath)
            let high = bulletNumber(json, "high", itemPath)
            items.add(DumbbellItem(name, low, high))
            itemIndex++
        }

        let labels = ArrayList<String>()
        if (!config.yAxis.labels.isEmpty()) {
            if (config.yAxis.labels.size != items.size) {
                throw chartInvalidValue("yAxis.labels", "类目数量与数据不一致")
            }
            for (label in config.yAxis.labels) {
                labels.add(label)
            }
        } else {
            for (item in items) {
                labels.add(item.name)
            }
        }

        var dataMin = items[0].low
        var dataMax = items[0].low
        for (item in items) {
            dataMin = minFloat(dataMin, minFloat(item.low, item.high))
            dataMax = maxFloat(dataMax, maxFloat(item.low, item.high))
        }
        var min = match (config.xAxis.min) {
            case Some(value) => value
            case None => dataMin
        }
        var max = match (config.xAxis.max) {
            case Some(value) => value
            case None => dataMax
        }
        if (max < min) {
            throw chartInvalidValue("xAxis.max", "最大值必须不小于最小值")
        }
        if (max == min) {
            min -= 1.0
            max += 1.0
        }
        let ticks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(min, max, config.xAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in ticks) {
            tickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }

        let legendVisible = config.legend.show && !seriesName.isEmpty()
        var maxLabelWidth = 0.0
        for (label in labels) {
            maxLabelWidth = maxFloat(maxLabelWidth, chartTextWidth(label, config.theme.fontSize))
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.y, frame.plot.bottom(), items.size)
        let xScale = LinearScale(min, max, frame.plot.right(), frame.plot.x)

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
        frame.drawYAxis(kit, ticks, xScale)

        let accent = config.theme.colorAt(0)
        for (index in 0..items.size) {
            let item = items[index]
            let centerY = band.center(index)
            let lowX = xScale.scale(item.low)
            let highX = xScale.scale(item.high)
            kit.line(
                minFloat(lowX, highX), centerY, maxFloat(lowX, highX), centerY,
                stroke: "#bdbdbd", strokeWidth: 2.0, className: "dumbbell-line"
            )
            kit.circle(lowX, centerY, 5.0, fill: "#9e9e9e", className: "dumbbell-low")
            kit.circle(highX, centerY, 6.0, fill: accent, className: "dumbbell-high")
        }

        for (index in 0..labels.size) {
            kit.text(
                frame.plot.x - 8.0,
                band.center(index),
                labels[index],
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "end",
                className: "category-label"
            )
        }
        frame.drawXAxisNumeric(kit, ticks, xScale, tickLabels.toArray())
        builder.toSvgString()
    }
}
