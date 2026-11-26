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

internal class GaugeThreshold {
    let value: Float64
    let color: String

    init(value: Float64, color: String) {
        this.value = value
        this.color = color
    }
}

/** M105 仪表盘。 */
public class GaugeChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "gauge")
        let root = ChartJson.of(data)
        let min = root.number("min", default: 0.0)
        let max = root.number("max", default: 100.0)
        if (max <= min) {
            throw chartInvalidValue("max", "max 必须大于 min")
        }
        let startAngle = root.number("startAngle", default: -120.0)
        let endAngle = root.number("endAngle", default: 120.0)
        if (startAngle >= endAngle) {
            throw chartInvalidValue("startAngle", "startAngle 必须小于 endAngle")
        }

        let thresholds = ArrayList<GaugeThreshold>()
        let thresholdArray = root.array("thresholds")
        match (thresholdArray) {
            case Some(array) =>
                var previous = min
                var index = 0
                for (item in array.getItems()) {
                    let itemPath = "thresholds[${index}]"
                    if (!item.kind.isObject) {
                        throw chartInvalidValue(itemPath, "期望阈值对象")
                    }
                    let json = ChartJson.of(item.asObject(), itemPath)
                    let value = json.number("value", default: 0.0)
                    if (value <= previous) {
                        throw chartInvalidValue("${itemPath}.value", "阈值必须严格递增")
                    }
                    if (value > max) {
                        throw chartInvalidValue("${itemPath}.value", "阈值不能超过 max")
                    }
                    let color = json.string("color", default: "")
                    let resolvedColor = if (color.isEmpty()) {
                        config.theme.colorAt(index % config.theme.palette.size)
                    } else {
                        color
                    }
                    thresholds.add(GaugeThreshold(value, resolvedColor))
                    previous = value
                    index++
                }
            case None => ()
        }

        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
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
        if (!dataItems[0].kind.isObject) {
            throw chartInvalidValue("series[0].data[0]", "期望对象")
        }
        let pointJson = ChartJson.of(dataItems[0].asObject(), "series[0].data[0]")
        let meterName = pointJson.string("name", default: seriesName)
        let value = pointJson.required("value")
        if (!(value.kind.isInt || value.kind.isDecimal)) {
            throw chartInvalidValue("series[0].data[0].value", "数值必须是数字")
        }
        let meterValue = jsonNumberValue(value, "series[0].data[0].value")
        if (meterValue < min || meterValue > max) {
            throw chartInvalidValue("series[0].data[0].value", "数值必须落在量程内")
        }

        let frame = ChartFrame(config, false, 0.0, 0.0)
        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let outerRadius = minFloat(frame.plot.width, frame.plot.height) * 0.42
        let innerRadius = outerRadius * 0.62

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        if (thresholds.isEmpty()) {
            kit.path(
                gaugeArcPath(
                    centerX, centerY, outerRadius, innerRadius, startAngle, endAngle
                ),
                fill: "#e0e0e0",
                className: "gauge-band"
            )
        } else {
            var bandStart = startAngle
            for (threshold in thresholds) {
                let bandEnd = gaugeAngleForValue(threshold.value, min, max, startAngle, endAngle)
                kit.path(
                    gaugeArcPath(
                        centerX, centerY, outerRadius, innerRadius, bandStart, bandEnd
                    ),
                    fill: threshold.color,
                    className: "gauge-band"
                )
                bandStart = bandEnd
            }
        }

        let needleAngle = gaugeAngleForValue(meterValue, min, max, startAngle, endAngle)
        let needleRadians = needleAngle * 3.141592653589793 / 180.0
        let tipX = centerX + outerRadius * 0.92 * cos(needleRadians)
        let tipY = centerY + outerRadius * 0.92 * sin(needleRadians)
        kit.line(
            centerX, centerY, tipX, tipY,
            stroke: "#424242", strokeWidth: 3.0,
            className: "gauge-needle"
        )
        kit.circle(centerX, centerY, 5.0, fill: "#424242", className: "gauge-hub")

        let valueSize = config.theme.fontSize + 12.0
        kit.text(
            centerX, centerY + outerRadius * 0.42, formatSvgNumber(meterValue),
            size: valueSize,
            color: config.theme.textColor,
            anchor: "middle",
            className: "gauge-value"
        )
        if (!meterName.isEmpty()) {
            kit.text(
                centerX, centerY + outerRadius * 0.42 + valueSize + 6.0, meterName,
                size: config.theme.fontSize,
                color: config.theme.axisColor,
                anchor: "middle",
                className: "gauge-label"
            )
        }
        builder.toSvgString()
    }
}

/** 数值 → 角度：线性映射到 [startAngle, endAngle]。 */
internal func gaugeAngleForValue(
    value: Float64,
    min: Float64,
    max: Float64,
    startAngle: Float64,
    endAngle: Float64
): Float64 {
    if (max <= min) {
        return startAngle
    }
    startAngle + (value - min) / (max - min) * (endAngle - startAngle)
}

/** 环形扇段的 SVG path，角度单位为度，0 度指向右侧、顺时针增长。 */
internal func gaugeArcPath(
    centerX: Float64,
    centerY: Float64,
    outerRadius: Float64,
    innerRadius: Float64,
    startAngle: Float64,
    endAngle: Float64
): String {
    let startRadians = startAngle * 3.141592653589793 / 180.0
    let endRadians = endAngle * 3.141592653589793 / 180.0
    let largeArc = if (abs(endAngle - startAngle) > 180.0) { 1 } else { 0 }
    let outerStartX = centerX + outerRadius * cos(startRadians)
    let outerStartY = centerY + outerRadius * sin(startRadians)
    let outerEndX = centerX + outerRadius * cos(endRadians)
    let outerEndY = centerY + outerRadius * sin(endRadians)
    let innerEndX = centerX + innerRadius * cos(endRadians)
    let innerEndY = centerY + innerRadius * sin(endRadians)
    let innerStartX = centerX + innerRadius * cos(startRadians)
    let innerStartY = centerY + innerRadius * sin(startRadians)
    let path = StringBuilder()
    path.append("M ${formatSvgNumber(outerStartX)} ${formatSvgNumber(outerStartY)}")
    path.append(" A ${formatSvgNumber(outerRadius)} ${formatSvgNumber(outerRadius)} 0 ")
    path.append("${largeArc} 1 ${formatSvgNumber(outerEndX)} ${formatSvgNumber(outerEndY)}")
    path.append(" L ${formatSvgNumber(innerEndX)} ${formatSvgNumber(innerEndY)}")
    path.append(" A ${formatSvgNumber(innerRadius)} ${formatSvgNumber(innerRadius)} 0 ")
    path.append("${largeArc} 0 ${formatSvgNumber(innerStartX)} ${formatSvgNumber(innerStartY)}")
    path.append(" Z")
    path.toString()
}
