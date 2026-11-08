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
import fountain::f_svg.{SvgBuilder, SvgViewBox, SvgColor, formatSvgNumber}

/** 变形地图区域。 */
internal class CartogramRegion {
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

/** M61 变形地图：按数值缩放区域轮廓。 */
public class CartogramChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "cartogram")
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
        let scaleBy = root.string("scaleBy", default: "sqrt")
        if (scaleBy != "value" && scaleBy != "sqrt") {
            throw chartInvalidValue("scaleBy", "期望 value / sqrt")
        }

        let regionArray = root.requiredArray("regions")
        let regionItems = regionArray.getItems()
        if (regionItems.isEmpty()) {
            throw chartInvalidValue("regions", "至少需要一个区域")
        }
        let regions = ArrayList<CartogramRegion>()
        var maxValue = 0.0
        var regionIndex = 0
        for (item in regionItems) {
            let itemPath = "regions[${regionIndex}]"
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
            if (value < 0.0) {
                throw chartInvalidValue("${itemPath}.value", "值不能为负")
            }
            let path = json.requiredString("path")
            let centroid = pathCentroid(path)
            var centerX = centroid[0]
            var centerY = centroid[1]
            match (json.array("centroid")) {
                case Some(centroidArray) =>
                    let values = centroidArray.getItems()
                    if (values.size != 2) {
                        throw chartInvalidValue("${itemPath}.centroid", "期望两个数字")
                    }
                    centerX = jsonNumberValue(values[0], "${itemPath}.centroid[0]")
                    centerY = jsonNumberValue(values[1], "${itemPath}.centroid[1]")
                case None => ()
            }
            maxValue = maxFloat(maxValue, value)
            regions.add(CartogramRegion(id, name, value, path, centerX, centerY))
            regionIndex++
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
        for (region in regions) {
            let ratio = if (maxValue <= 0.0) { 0.0 } else { region.value / maxValue }
            let factor = cartogramScale(region.value, maxValue, scaleBy)
            let transform =
                "translate(${formatSvgNumber(region.centerX)},${formatSvgNumber(region.centerY)}) " +
                "scale(${formatSvgNumber(factor)}) " +
                "translate(${formatSvgNumber(-region.centerX)},${formatSvgNumber(-region.centerY)})"
            builder.group()
            builder.attr("transform", transform)
            builder.path(d: region.path)
            builder.className("cartogram-region")
            builder.fill(heatFlameColor(ratio, colorRange))
            builder.stroke("#ffffff")
            builder.strokeWidth(0.5)
            builder.end()
        }
        builder.toSvgString()
    }
}

/** 数值 → 缩放比例：按最大值归一化，支持线性与平方根。 */
internal func cartogramScale(value: Float64, maxValue: Float64, scaleBy: String): Float64 {
    if (maxValue <= 0.0) {
        return 1.0
    }
    var ratio = value / maxValue
    if (ratio < 0.0) {
        ratio = 0.0
    }
    if (ratio > 1.0) {
        ratio = 1.0
    }
    if (scaleBy == "value") {
        ratio
    } else {
        sqrt(ratio)
    }
}
