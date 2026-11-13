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

internal class RadarIndicator {
    let name: String
    let maximum: Float64

    init(name: String, maximum: Float64) {
        this.name = name
        this.maximum = maximum
    }
}

internal class RadarSeries {
    let name: String
    let values: Array<Float64>
    let color: ?String

    init(name: String, values: Array<Float64>, color: ?String) {
        this.name = name
        this.values = values
        this.color = color
    }
}

/** M13 雷达图：多指标综合表现。 */
public class RadarChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "radar")
        let root = ChartJson.of(data)
        let indicatorsArray = root.requiredArray("indicators")
        if (indicatorsArray.getItems().isEmpty()) {
            throw chartMissingField("indicators")
        }
        let indicators = parseIndicators(indicatorsArray)
        let seriesArray = root.requiredArray("series")
        if (seriesArray.getItems().isEmpty()) {
            throw chartMissingField("series")
        }
        let series = parseSeries(seriesArray, indicators.size)

        let legendVisible = series.size > 1
        let frame = ChartFrame(config, legendVisible, 0.0, 0.0)
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

        let centerX = frame.plot.centerX()
        let centerY = frame.plot.centerY()
        let radius = minFloat(frame.plot.width, frame.plot.height) / 2.0 - 36.0
        if (radius <= 0.0) {
            throw chartInvalidValue("width", "画布太小，无法绘制雷达图")
        }

        for (level in 1..5) {
            let factor = Float64(level) / 4.0
            let path = polygonPath(centerX, centerY, radius * factor, indicators.size)
            kit.path(
                path, fill: "none", stroke: config.theme.gridColor,
                strokeWidth: 1.0, className: "grid"
            )
        }
        for (index in 0..indicators.size) {
            let point = radarPoint(centerX, centerY, radius, 1.0, index, indicators.size)
            kit.line(
                centerX, centerY, point.x, point.y,
                stroke: config.theme.axisColor, strokeWidth: 1.0, className: "axis"
            )
            let labelPoint = radarPoint(centerX, centerY, radius, 1.0, index, indicators.size)
            let dx = labelPoint.x - centerX
            let anchor = if (abs(dx) < radius * 0.2) {
                "middle"
            } else if (dx > 0.0) {
                "start"
            } else {
                "end"
            }
            let offsetX = if (abs(dx) < radius * 0.2) {
                0.0
            } else if (dx > 0.0) {
                8.0
            } else {
                -8.0
            }
            let labelOffsetY = if (labelPoint.y < centerY) { 6.0 } else { -6.0 }
            kit.text(
                labelPoint.x + offsetX,
                labelPoint.y - labelOffsetY,
                indicators[index].name,
                size: config.theme.fontSize,
                color: config.theme.textColor,
                anchor: anchor,
                className: "indicator-label"
            )
        }

        for (seriesIndex in 0..series.size) {
            let item = series[seriesIndex]
            let color = match (item.color) {
                case Some(value) => value
                case None => config.theme.colorAt(seriesIndex)
            }
            let points = ArrayList<LinePixel>()
            for (index in 0..indicators.size) {
                let factor = clamp01(item.values[index] / indicators[index].maximum)
                points.add(radarPoint(centerX, centerY, radius, factor, index, indicators.size))
            }
            let builderPath = StringBuilder()
            for (index in 0..points.size) {
                if (index == 0) {
                    builderPath.append("M ${formatSvgNumber(points[index].x)} ${formatSvgNumber(points[index].y)}")
                } else {
                    builderPath.append(" L ${formatSvgNumber(points[index].x)} ${formatSvgNumber(points[index].y)}")
                }
            }
            builderPath.append(" Z")
            kit.path(
                builderPath.toString(),
                fill: color, stroke: color, strokeWidth: 2.0,
                className: "radar-area", fillOpacity: 0.2
            )
            for (point in points) {
                kit.circle(point.x, point.y, 3.0, fill: color, className: "symbol")
            }
        }
        builder.toSvgString()
    }

    private func parseIndicators(items: JsonArray): Array<RadarIndicator> {
        let indicators = ArrayList<RadarIndicator>()
        var index = 0
        for (item in items.getItems()) {
            let path = "indicators[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let name = json.string("name", default: (index + 1).toString())
            let maximum = json.number("max", default: 100.0)
            if (maximum <= 0.0) {
                throw chartInvalidValue("${path}.max", "max 必须大于 0")
            }
            indicators.add(RadarIndicator(name, maximum))
            index++
        }
        indicators.toArray()
    }

    private func parseSeries(items: JsonArray, indicatorCount: Int64): Array<RadarSeries> {
        let series = ArrayList<RadarSeries>()
        var index = 0
        for (item in items.getItems()) {
            let path = "series[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(path, "期望对象")
            }
            let json = ChartJson.of(item.asObject(), path)
            let values = json.numberArray("data")
            if (values.size != indicatorCount) {
                throw chartInvalidValue(
                    "${path}.data",
                    "数据长度 ${values.size} 与 indicators 长度 ${indicatorCount} 不一致"
                )
            }
            series.add(RadarSeries(
                json.string("name", default: ""),
                values,
                json.string("color")
            ))
            index++
        }
        series.toArray()
    }

    private func radarPoint(
        centerX: Float64,
        centerY: Float64,
        radius: Float64,
        factor: Float64,
        index: Int64,
        count: Int64
    ): LinePixel {
        let angle = (-90.0 + 360.0 * Float64(index) / Float64(count)) * 3.141592653589793 / 180.0
        LinePixel(
            centerX + cos(angle) * radius * factor,
            centerY + sin(angle) * radius * factor
        )
    }

    private func polygonPath(
        centerX: Float64,
        centerY: Float64,
        radius: Float64,
        count: Int64
    ): String {
        let builder = StringBuilder()
        for (index in 0..count) {
            let point = radarPoint(centerX, centerY, radius, 1.0, index, count)
            if (index == 0) {
                builder.append("M ${formatSvgNumber(point.x)} ${formatSvgNumber(point.y)}")
            } else {
                builder.append(" L ${formatSvgNumber(point.x)} ${formatSvgNumber(point.y)}")
            }
        }
        builder.append(" Z")
        builder.toString()
    }
}

internal func clamp01(value: Float64): Float64 {
    if (value < 0.0) {
        0.0
    } else if (value > 1.0) {
        1.0
    } else {
        value
    }
}
