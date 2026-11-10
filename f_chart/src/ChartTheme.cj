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

internal let CHART_DEFAULT_PALETTE: Array<String> = [
    "#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f",
    "#edc948", "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac"
]

/** 主题：背景、调色板、字体与文字/轴/网格颜色。 */
internal class ChartTheme {
    var background: String = "#ffffff"
    var palette: Array<String> = CHART_DEFAULT_PALETTE
    var fontFamily: String = "sans-serif"
    var fontSize: Float64 = 12.0
    var textColor: String = "#333333"
    var axisColor: String = "#999999"
    var gridColor: String = "#e5e5e5"
    var legendTextColor: String = "#333333"

    static func parse(json: ?ChartJson): ChartTheme {
        let theme = ChartTheme()
        match (json) {
            case Some(value) =>
                theme.background = value.string("background", default: theme.background)
                let palette = value.stringArray("palette", default: Array<String>())
                if (!palette.isEmpty()) {
                    theme.palette = palette
                }
                theme.fontFamily = value.string("fontFamily", default: theme.fontFamily)
                theme.fontSize = value.number("fontSize", default: theme.fontSize)
                theme.textColor = value.string("textColor", default: theme.textColor)
                theme.axisColor = value.string("axisColor", default: theme.axisColor)
                theme.gridColor = value.string("gridColor", default: theme.gridColor)
                theme.legendTextColor = value.string("legendTextColor", default: theme.textColor)
            case None => ()
        }
        theme
    }

    func colorAt(index: Int64): String {
        if (this.palette.isEmpty()) {
            "#4e79a7"
        } else {
            this.palette[index % this.palette.size]
        }
    }
}
