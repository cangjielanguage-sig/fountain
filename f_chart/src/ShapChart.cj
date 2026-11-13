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

/** 单个特征的 SHAP 贡献。 */
internal class ShapContribution {
    let feature: String
    let value: Float64

    init(feature: String, value: Float64) {
        this.feature = feature
        this.value = value
    }
}

/** M101 SHAP 图：单样本特征贡献的水平条形图。 */
public class ShapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "shap")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "SHAP 图仅支持 1 个系列")
        }
        if (!seriesItems[0].kind.isObject) {
            throw chartInvalidValue("series[0]", "期望对象")
        }
        let seriesJson = ChartJson.of(seriesItems[0].asObject(), "series[0]")
        let dataArray = seriesJson.requiredArray("data")
        let dataItems = dataArray.getItems()
        if (dataItems.isEmpty()) {
            throw chartInvalidValue("series[0].data", "数据不能为空")
        }
        let contributions = ArrayList<ShapContribution>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 {feature,value} 对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let feature = json.requiredString("feature")
            if (feature.isEmpty()) {
                throw chartInvalidValue("${itemPath}.feature", "特征名不能为空")
            }
            for (existing in contributions) {
                if (existing.feature == feature) {
                    throw chartInvalidValue("${itemPath}.feature", "特征 ${feature} 重复")
                }
            }
            let value = volcanoNumber(json, "value", itemPath)
            contributions.add(ShapContribution(feature, value))
            itemIndex++
        }
        let ordered = shapOrder(contributions)

        var minValue = ordered[0].value
        var maxValue = ordered[0].value
        var maxFeatureWidth = 0.0
        for (entry in ordered) {
            minValue = minFloat(minValue, entry.value)
            maxValue = maxFloat(maxValue, entry.value)
            maxFeatureWidth = maxFloat(
                maxFeatureWidth,
                chartTextWidth(entry.feature, config.theme.fontSize)
            )
        }
        let xMin = if (minValue < 0.0) { minValue * 1.15 } else { 0.0 }
        let xMax = if (maxValue > 0.0) { maxValue * 1.15 } else { 0.0 }
        let resolvedMin = if (xMin == xMax) { -1.0 } else { xMin }
        let resolvedMax = if (xMin == xMax) { 1.0 } else { xMax }
        let ticks = if (!config.xAxis.values.isEmpty()) {
            config.xAxis.values
        } else {
            chartNiceTicks(resolvedMin, resolvedMax, config.xAxis.tickCount)
        }
        let tickLabels = ArrayList<String>()
        for (tick in ticks) {
            tickLabels.add(chartFormatTick(tick, config.xAxis.labelFormat))
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, false, maxFeatureWidth + 16.0, xLabelHeight)
        let band = BandScale(frame.plot.y, frame.plot.bottom(), ordered.size)
        let xScale = LinearScale(resolvedMin, resolvedMax, frame.plot.right(), frame.plot.x)

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let zeroX = xScale.scale(0.0)
        kit.line(
            zeroX, frame.plot.y, zeroX, frame.plot.bottom(),
            stroke: "#9e9e9e", strokeWidth: 1.0,
            className: "shap-zero", dash: "4 4"
        )
        for (index in 0..ordered.size) {
            let entry = ordered[index]
            let centerY = band.center(index)
            let barHeight = band.bandWidth * 0.6
            let valueX = xScale.scale(entry.value)
            let barX = minFloat(zeroX, valueX)
            let barWidth = abs(valueX - zeroX)
            let positive = entry.value >= 0.0
            let color = if (positive) { "#e53935" } else { "#2196f3" }
            let className = if (positive) {
                "shap-bar shap-positive"
            } else {
                "shap-bar shap-negative"
            }
            kit.rect(
                barX, centerY - barHeight / 2.0,
                barWidth, barHeight,
                fill: color,
                className: className
            )
            kit.text(
                frame.plot.x - 8.0, centerY + config.theme.fontSize * 0.35,
                entry.feature,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: "end",
                className: "shap-feature"
            )
            let labelX = if (positive) { valueX + 6.0 } else { valueX - 6.0 }
            kit.text(
                labelX, centerY + config.theme.fontSize * 0.35,
                formatSvgNumber(entry.value),
                size: config.theme.fontSize - 1.0,
                color: color,
                anchor: if (positive) { "start" } else { "end" },
                className: "shap-label"
            )
        }
        frame.drawXAxisNumeric(kit, ticks, xScale, tickLabels.toArray())
        builder.toSvgString()
    }
}

/** 按贡献绝对值降序稳定排序。 */
internal func shapOrder(items: ArrayList<ShapContribution>): Array<ShapContribution> {
    let sorted = ArrayList<ShapContribution>()
    for (item in items) {
        sorted.add(item)
    }
    for (i in 1..sorted.size) {
        var j = i
        while (j > 0 && abs(sorted[j].value) > abs(sorted[j - 1].value)) {
            let temporary = sorted[j]
            sorted[j] = sorted[j - 1]
            sorted[j - 1] = temporary
            j--
        }
    }
    sorted.toArray()
}
