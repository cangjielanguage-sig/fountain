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

import fountain::f_data.json.{JsonObject, JsonValue}

/** 画布内边距。 */
internal class ChartPadding {
    var top: Float64 = 24.0
    var right: Float64 = 24.0
    var bottom: Float64 = 24.0
    var left: Float64 = 24.0

    static func parse(value: ?JsonValue): ChartPadding {
        let padding = ChartPadding()
        match (value) {
            case Some(json) =>
                if (json.kind.isInt || json.kind.isDecimal) {
                    let number = jsonNumberValue(json, "padding")
                    padding.top = number
                    padding.right = number
                    padding.bottom = number
                    padding.left = number
                } else if (json.kind.isObject) {
                    let obj = ChartJson.of(json.asObject(), "padding")
                    padding.top = obj.number("top", default: padding.top)
                    padding.right = obj.number("right", default: padding.right)
                    padding.bottom = obj.number("bottom", default: padding.bottom)
                    padding.left = obj.number("left", default: padding.left)
                } else {
                    throw chartInvalidValue("padding", "期望数字或对象")
                }
            case None => ()
        }
        padding
    }
}

/** 轴配置。 */
internal class ChartAxis {
    var axisType: String = "linear"
    var title: String = ""
    var labels: Array<String> = Array<String>()
    var min: ?Float64 = None
    var max: ?Float64 = None
    var tickCount: Int64 = 5
    var grid: Bool = true
    var labelRotate: Float64 = 0.0
    var labelFormat: String = "{value}"
    var logBase: Float64 = 10.0
    var values: Array<Float64> = Array<Float64>()

    static func parse(json: ?ChartJson, defaultType: String, defaultGrid: Bool): ChartAxis {
        let axis = ChartAxis()
        axis.axisType = defaultType
        axis.grid = defaultGrid
        match (json) {
            case Some(value) =>
                axis.axisType = value.string("type", default: defaultType)
                axis.title = value.string("title", default: "")
                axis.labels = value.stringArray("labels", default: Array<String>())
                axis.min = value.number("min")
                axis.max = value.number("max")
                axis.tickCount = value.int("tickCount", default: 5)
                axis.grid = value.bool("grid", default: defaultGrid)
                axis.labelRotate = value.number("labelRotate", default: 0.0)
                axis.labelFormat = value.string("labelFormat", default: "{value}")
                axis.logBase = value.number("logBase", default: 10.0)
                axis.values = value.numberArray("values")
            case None => ()
        }
        if (axis.tickCount < 2) {
            axis.tickCount = 2
        }
        axis
    }
}

/** 图例配置。 */
internal class ChartLegend {
    var show: Bool = true
    var position: String = "top"
    var orient: String = "horizontal"
    var itemGap: Float64 = 16.0
    var markerSize: Float64 = 10.0

    static func parse(json: ?ChartJson): ChartLegend {
        let legend = ChartLegend()
        match (json) {
            case Some(value) =>
                legend.show = value.bool("show", default: true)
                legend.position = value.string("position", default: "top")
                legend.orient = value.string("orient", default: "horizontal")
                legend.itemGap = value.number("itemGap", default: 16.0)
                legend.markerSize = value.number("markerSize", default: 10.0)
            case None => ()
        }
        legend
    }
}

/** 通用信封：类型、标题、尺寸、内边距、主题、图例与轴。 */
internal class ChartConfig {
    let chartType: String
    let title: String
    let subtitle: String
    let titleAlign: String
    let titleFontSize: Float64
    let titleColor: String
    let width: Float64
    let height: Float64
    let padding: ChartPadding
    let theme: ChartTheme
    let legend: ChartLegend
    let xAxis: ChartAxis
    let yAxis: ChartAxis

    private init(
        chartType: String,
        title: String,
        subtitle: String,
        titleAlign: String,
        titleFontSize: Float64,
        titleColor: String,
        width: Float64,
        height: Float64,
        padding: ChartPadding,
        theme: ChartTheme,
        legend: ChartLegend,
        xAxis: ChartAxis,
        yAxis: ChartAxis
    ) {
        this.chartType = chartType
        this.title = title
        this.subtitle = subtitle
        this.titleAlign = titleAlign
        this.titleFontSize = titleFontSize
        this.titleColor = titleColor
        this.width = width
        this.height = height
        this.padding = padding
        this.theme = theme
        this.legend = legend
        this.xAxis = xAxis
        this.yAxis = yAxis
    }

    static func parse(data: JsonObject, expectedType: String): ChartConfig {
        let root = ChartJson.of(data)
        let chartType = root.requiredString("type")
        if (chartType != expectedType) {
            throw ChartException(
                "期望 type 为 ${expectedType}，实际为 ${chartType}",
                kind: ChartErrorKind.UnsupportedChart,
                path: "type"
            )
        }

        let width = root.number("width", default: 800.0)
        let height = root.number("height", default: 480.0)
        if (width <= 0.0 || height <= 0.0) {
            throw chartInvalidValue("width", "画布宽高必须大于 0")
        }

        let theme = ChartTheme.parse(root.object("theme"))
        let padding = ChartPadding.parse(root.value("padding"))

        var title = ""
        var subtitle = ""
        var titleAlign = "center"
        var titleFontSize = 18.0
        var titleColor = theme.textColor
        match (root.value("title")) {
            case Some(value) =>
                if (value.kind.isString) {
                    title = value.asString().value
                } else if (value.kind.isObject) {
                    let titleJson = ChartJson.of(value.asObject(), "title")
                    title = titleJson.string("text", default: "")
                    subtitle = titleJson.string("subtext", default: "")
                    titleAlign = titleJson.string("align", default: "center")
                    titleFontSize = titleJson.number("fontSize", default: 18.0)
                    titleColor = titleJson.string("color", default: theme.textColor)
                } else {
                    throw chartInvalidValue("title", "期望字符串或对象")
                }
            case None => ()
        }

        let legend = ChartLegend.parse(root.object("legend"))
        let xAxis = ChartAxis.parse(root.object("xAxis"), "category", false)
        let yAxis = ChartAxis.parse(root.object("yAxis"), "linear", true)

        ChartConfig(
            chartType, title, subtitle, titleAlign, titleFontSize, titleColor,
            width, height, padding, theme, legend, xAxis, yAxis
        )
    }
}
