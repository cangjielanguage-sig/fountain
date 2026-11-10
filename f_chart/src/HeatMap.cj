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
import fountain::f_svg.{SvgBuilder, SvgViewBox, SvgColor}

/** 热力地图上的点。 */
internal class HeatMapPoint {
    let x: Float64
    let y: Float64
    let value: Float64

    init(x: Float64, y: Float64, value: Float64) {
        this.x = x
        this.y = y
        this.value = value
    }
}

/** M59 热力地图。 */
public class HeatMapChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "heat-map")
        let root = ChartJson.of(data)
        let viewBoxValues = root.numberArray("viewBox")
        var viewMinX = 0.0
        var viewMinY = 0.0
        var viewWidth = config.width
        var viewHeight = config.height
        if (!viewBoxValues.isEmpty()) {
            if (viewBoxValues.size != 4 || viewBoxValues[2] <= 0.0 || viewBoxValues[3] <= 0.0) {
                throw chartInvalidValue("viewBox", "期望 [x, y, w, h] 且宽高大于 0")
            }
            viewMinX = viewBoxValues[0]
            viewMinY = viewBoxValues[1]
            viewWidth = viewBoxValues[2]
            viewHeight = viewBoxValues[3]
        }
        let radius = root.number("radius", default: 24.0)
        if (radius <= 0.0) {
            throw chartInvalidValue("radius", "半径必须大于 0")
        }

        let regionPaths = ArrayList<String>()
        match (root.array("regions")) {
            case Some(regionArray) =>
                let regionItems = regionArray.getItems()
                var regionIndex = 0
                for (item in regionItems) {
                    let itemPath = "regions[${regionIndex}]"
                    if (!item.kind.isObject) {
                        throw chartInvalidValue(itemPath, "期望区域对象")
                    }
                    let json = ChartJson.of(item.asObject(), itemPath)
                    regionPaths.add(json.requiredString("path"))
                    regionIndex++
                }
            case None => ()
        }

        let pointArray = root.requiredArray("points")
        let items = pointArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("points", "至少需要一个点")
        }
        let points = ArrayList<HeatMapPoint>()
        var maxValue = 0.0
        var index = 0
        for (item in items) {
            let itemPath = "points[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望点对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let x = jsonNumberValue(json.required("x"), "${itemPath}.x")
            let y = jsonNumberValue(json.required("y"), "${itemPath}.y")
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            if (value < 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值不能为负")
            }
            maxValue = maxFloat(maxValue, value)
            points.add(HeatMapPoint(x, y, value))
            index++
        }

        let colorRange = root.stringArray(
            "colorRange",
            default: ["#ffffcc", "#fd8d3c", "#800026"]
        )
        if (colorRange.size < 2) {
            throw chartInvalidValue("colorRange", "至少需要两个颜色")
        }
        for (colorIndex in 0..colorRange.size) {
            match (SvgColor.tryParse(colorRange[colorIndex])) {
                case Some(_) => ()
                case None =>
                    throw chartInvalidValue(
                        "colorRange[${colorIndex}]",
                        "非法颜色 ${colorRange[colorIndex]}"
                    )
            }
        }

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(viewMinX, viewMinY, viewWidth, viewHeight)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        kit.rect(
            viewMinX, viewMinY, viewWidth, viewHeight,
            fill: config.theme.background, className: "background"
        )
        if (!config.title.isEmpty()) {
            kit.text(
                viewMinX + viewWidth / 2.0,
                viewMinY + config.padding.top + config.titleFontSize,
                config.title,
                size: config.titleFontSize,
                color: config.titleColor,
                anchor: "middle",
                className: "title"
            )
        }
        for (path in regionPaths) {
            kit.path(
                path,
                fill: "#f0f0f0",
                stroke: "#cccccc",
                strokeWidth: 0.8,
                className: "heat-map-region"
            )
        }

        let sorted = sortByValue(points)
        for (point in sorted) {
            let ratio = if (maxValue <= 0.0) { 0.0 } else { point.value / maxValue }
            builder.group()
            builder.circle(cx: point.x, cy: point.y, r: radius)
            builder.className("heat-map-point")
            builder.fill(heatFlameColor(ratio, colorRange))
            builder.fillOpacity(0.5)
            builder.end()
        }
        builder.toSvgString()
    }

    private func sortByValue(points: ArrayList<HeatMapPoint>): Array<HeatMapPoint> {
        let sorted = ArrayList<HeatMapPoint>()
        for (point in points) {
            sorted.add(point)
        }
        for (i in 1..sorted.size) {
            var j = i
            while (j > 0 && sorted[j].value < sorted[j - 1].value) {
                let temporary = sorted[j]
                sorted[j] = sorted[j - 1]
                sorted[j - 1] = temporary
                j--
            }
        }
        sorted.toArray()
    }
}
