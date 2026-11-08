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
import std.convert.*
import std.math.*
import fountain::f_data.json.*
import fountain::f_svg.{SvgBuilder, SvgViewBox, SvgColor}

/** 地图区域。 */
internal class ChoroplethRegion {
    let id: String
    let name: String
    let value: Float64
    let path: String
    let centerX: Float64
    let centerY: Float64

    init(id: String, name: String, value: Float64, path: String, centerX: Float64, centerY: Float64) {
        this.id = id
        this.name = name
        this.value = value
        this.path = path
        this.centerX = centerX
        this.centerY = centerY
    }
}

/** M57 分级统计地图。 */
public class ChoroplethChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "choropleth")
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

        let regionArray = root.requiredArray("regions")
        let items = regionArray.getItems()
        if (items.isEmpty()) {
            throw chartInvalidValue("regions", "至少需要一个区域")
        }
        let regions = ArrayList<ChoroplethRegion>()
        var minValue = 0.0
        var maxValue = 0.0
        var hasValue = false
        var index = 0
        for (item in items) {
            let itemPath = "regions[${index}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望区域对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let id = json.requiredString("id")
            for (existing in regions) {
                if (existing.id == id) {
                    throw chartInvalidValue("${itemPath}.id", "区域 id 重复")
                }
            }
            let name = json.string("name", default: id)
            let value = jsonNumberValue(json.required("value"), "${itemPath}.value")
            let path = json.requiredString("path")
            let center = pathCentroid(path)
            if (!hasValue) {
                minValue = value
                maxValue = value
                hasValue = true
            } else {
                minValue = minFloat(minValue, value)
                maxValue = maxFloat(maxValue, value)
            }
            regions.add(ChoroplethRegion(id, name, value, path, center[0], center[1]))
            index++
        }

        let colorRange = root.stringArray(
            "colorRange",
            default: ["#e8f1fb", "#7fb3d5", "#1f4e79"]
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
        let showLabels = root.bool("showLabels", default: false)

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

        let span = maxValue - minValue
        for (region in regions) {
            let ratio = if (span <= 0.0) {
                0.5
            } else {
                (region.value - minValue) / span
            }
            kit.path(
                region.path,
                fill: heatFlameColor(ratio, colorRange),
                stroke: "#ffffff",
                strokeWidth: 0.5,
                className: "choropleth-region"
            )
        }
        if (showLabels) {
            for (region in regions) {
                kit.text(
                    region.centerX, region.centerY, region.name,
                    size: config.theme.fontSize,
                    color: config.theme.textColor,
                    anchor: "middle",
                    className: "choropleth-label"
                )
            }
        }
        builder.toSvgString()
    }
}

/** SVG path 坐标均值，用作标签位置。 */
internal func pathCentroid(path: String): Array<Float64> {
    let bytes = path.toArray()
    let numbers = ArrayList<Float64>()
    var index = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        let isStart = (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b'-'
        if (isStart) {
            var end = index + 1
            while (end < bytes.size) {
                let next = bytes[end]
                if ((next >= b'0' && next <= b'9') || next == b'.') {
                    end++
                } else {
                    break
                }
            }
            let text = String.fromUtf8(bytes[index..end])
            try {
                numbers.add(Float64.parse(text))
            } catch (_: Exception) {
                ()
            }
            index = end
        } else {
            index++
        }
    }
    if (numbers.size < 4) {
        throw chartInvalidValue("path", "路径至少需要两个坐标点")
    }
    var sumX = 0.0
    var sumY = 0.0
    var count = 0
    var position = 0
    while (position + 1 < numbers.size) {
        sumX += numbers[position]
        sumY += numbers[position + 1]
        count++
        position += 2
    }
    [sumX / Float64(count), sumY / Float64(count)]
}
