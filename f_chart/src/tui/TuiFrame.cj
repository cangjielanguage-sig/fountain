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
package fountain::f_chart.tui

import std.math.*
import fountain::f_chart.*

/** 字符矩形：坐标为字符行列。 */
internal class TuiRect {
    let x: Int64
    let y: Int64
    let width: Int64
    let height: Int64

    init(x: Int64, y: Int64, width: Int64, height: Int64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }

    func right(): Int64 {
        this.x + this.width - 1
    }

    func bottom(): Int64 {
        this.y + this.height - 1
    }

    func centerX(): Int64 {
        this.x + this.width / 2
    }

    func centerY(): Int64 {
        this.y + this.height / 2
    }
}

/** TUI 坐标框：标题、图例、绘图区、刻度与标签。 */
internal class TuiFrame {
    let config: ChartConfig
    let plot: TuiRect
    private let titleRow: Int64
    private let subtitleRow: Int64
    private let legendRow: Int64
    private let legendVisible: Bool
    private let yLabelWidth: Int64
    private let xAxisRow: Int64
    private let xLabelRow: Int64
    private let xTitleRow: Int64

    init(
        config: ChartConfig,
        yLabelWidth: Int64,
        rightLabelWidth!: Int64 = 0,
        legendVisible!: Bool = false
    ) {
        if (config.width < 20.0 || config.height < 8.0) {
            throw chartInvalidValue("width", "TUI 画布至少需要 20×8 字符")
        }
        let width = Int64(config.width)
        let height = Int64(config.height)
        var top: Int64 = 0
        var titleRow: Int64 = -1
        var subtitleRow: Int64 = -1
        if (!config.title.isEmpty()) {
            titleRow = top
            top++
            if (!config.subtitle.isEmpty()) {
                subtitleRow = top
                top++
            }
        }
        var legendRow: Int64 = -1
        let showLegend = legendVisible && config.legend.show
        if (showLegend && config.legend.position != "bottom") {
            legendRow = top
            top++
        }
        var bottom: Int64 = 2
        if (!config.xAxis.title.isEmpty()) {
            bottom++
        }
        if (showLegend && config.legend.position == "bottom") {
            bottom++
        }
        let left = yLabelWidth + 2
        let plotWidth = width - left - rightLabelWidth - 1
        let plotHeight = height - top - bottom
        if (plotWidth < 1 || plotHeight < 1) {
            throw chartInvalidValue("width", "TUI 画布可用绘图区过小")
        }
        this.config = config
        this.plot = TuiRect(left, top, plotWidth, plotHeight)
        this.titleRow = titleRow
        this.subtitleRow = subtitleRow
        this.legendRow = if (showLegend && config.legend.position == "bottom") {
            height - 1
        } else {
            legendRow
        }
        this.legendVisible = showLegend
        this.yLabelWidth = yLabelWidth
        this.xAxisRow = this.plot.bottom() + 1
        this.xLabelRow = this.plot.bottom() + 2
        this.xTitleRow = this.plot.bottom() + 3
    }

    func drawTitle(canvas: TuiCanvas): Unit {
        if (this.titleRow >= 0) {
            canvas.putText(
                0, this.titleRow, this.config.title, this.config.titleColor,
                align: this.titleAlign()
            )
        }
        if (this.subtitleRow >= 0) {
            canvas.putText(
                0, this.subtitleRow, this.config.subtitle, this.config.theme.axisColor,
                align: this.titleAlign()
            )
        }
    }

    private func titleAlign(): String {
        if (this.config.titleAlign == "left") {
            "start"
        } else if (this.config.titleAlign == "right") {
            "end"
        } else {
            "middle"
        }
    }

    func drawLegend(canvas: TuiCanvas, names: Array<String>, colors: Array<String>): Unit {
        if (!this.legendVisible || this.legendRow < 0) {
            return
        }
        var cursor: Int64 = 0
        for (index in 0..names.size) {
            if (cursor >= canvas.width) {
                break
            }
            let color = if (index < colors.size) { colors[index] } else { this.config.theme.colorAt(index) }
            canvas.putText(cursor, this.legendRow, "■", color)
            cursor += 2
            canvas.putText(
                cursor, this.legendRow, names[index], this.config.theme.legendTextColor
            )
            cursor += tuiDisplayWidth(names[index]) + 2
        }
    }

    func drawYAxis(canvas: TuiCanvas, ticks: Array<Float64>, scale: LinearScale): Unit {
        for (tick in ticks) {
            let row = this.clampRow(Int64(round(scale.scale(tick))))
            for (column in this.plot.x..this.plot.right() + 1) {
                canvas.set(column, row, "·", this.config.theme.gridColor)
            }
            let label = chartFormatTick(tick, this.config.yAxis.labelFormat)
            canvas.putText(
                0, row, tuiPadLeft(tuiTruncate(label, this.yLabelWidth), this.yLabelWidth),
                this.config.theme.axisColor
            )
        }
        for (row in this.plot.y..this.plot.bottom() + 1) {
            canvas.set(this.plot.x - 1, row, "│", this.config.theme.axisColor)
        }
    }

    func drawXAxisCategory(
        canvas: TuiCanvas,
        labels: Array<String>,
        band: BandScale
    ): Unit {
        this.drawXAxisLine(canvas)
        let bandWidth = Int64(floor(band.bandWidth))
        for (index in 0..labels.size) {
            let center = Int64(round(band.center(index)))
            canvas.set(center, this.xAxisRow, "┬", this.config.theme.axisColor)
            if (bandWidth >= 2) {
                let start = Int64(round(band.bandStart(index)))
                canvas.putText(
                    start, this.xLabelRow, labels[index], this.config.theme.axisColor,
                    align: "middle", maxWidth: bandWidth
                )
            }
        }
        this.drawXTitle(canvas)
    }

    func drawXAxisNumeric(
        canvas: TuiCanvas,
        ticks: Array<Float64>,
        scale: LinearScale,
        labels: Array<String>
    ): Unit {
        this.drawXAxisLine(canvas)
        for (index in 0..ticks.size) {
            let column = Int64(round(scale.scale(ticks[index])))
            canvas.set(column, this.xAxisRow, "┬", this.config.theme.axisColor)
            canvas.putText(
                column - 5, this.xLabelRow, labels[index], this.config.theme.axisColor,
                align: "middle", maxWidth: 11
            )
        }
        this.drawXTitle(canvas)
    }

    private func drawXAxisLine(canvas: TuiCanvas): Unit {
        for (column in this.plot.x - 1..this.plot.right() + 1) {
            canvas.set(column, this.xAxisRow, "─", this.config.theme.axisColor)
        }
        canvas.set(this.plot.x - 1, this.xAxisRow, "└", this.config.theme.axisColor)
    }

    private func drawXTitle(canvas: TuiCanvas): Unit {
        if (!this.config.xAxis.title.isEmpty()) {
            canvas.putText(
                this.plot.x, this.xTitleRow, this.config.xAxis.title,
                this.config.theme.textColor, align: "middle",
                maxWidth: this.plot.width
            )
        }
    }

    private func clampRow(value: Int64): Int64 {
        if (value < this.plot.y) {
            this.plot.y
        } else if (value > this.plot.bottom()) {
            this.plot.bottom()
        } else {
            value
        }
    }
}
