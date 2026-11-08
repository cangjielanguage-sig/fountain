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

/** 矩形区域。 */
internal struct ChartRect {
    let x: Float64
    let y: Float64
    let width: Float64
    let height: Float64

    init(x: Float64, y: Float64, width: Float64, height: Float64) {
        this.x = x
        this.y = y
        this.width = width
        this.height = height
    }

    func right(): Float64 {
        this.x + this.width
    }

    func bottom(): Float64 {
        this.y + this.height
    }

    func centerX(): Float64 {
        this.x + this.width / 2.0
    }

    func centerY(): Float64 {
        this.y + this.height / 2.0
    }
}

/** 通用坐标框：标题、图例、绘图区、网格、轴与刻度。 */
internal class ChartFrame {
    let config: ChartConfig
    let legendVisible: Bool
    let plot: ChartRect
    let legendY: Float64

    init(
        config: ChartConfig,
        legendVisible: Bool,
        yLabelWidth: Float64,
        xLabelHeight: Float64
    ) {
        this.config = config
        this.legendVisible = legendVisible
        let padding = config.padding
        var top = padding.top
        if (!config.title.isEmpty()) {
            top += config.titleFontSize + 6.0
            if (!config.subtitle.isEmpty()) {
                top += config.theme.fontSize + 4.0
            }
        }
        var legendY = 0.0
        if (legendVisible) {
            if (config.legend.position == "top") {
                legendY = top + 10.0
                top += 26.0
            } else if (config.legend.position == "bottom") {
                legendY = config.height - padding.bottom - 10.0
            }
        }
        this.legendY = legendY
        let left = padding.left + yLabelWidth
        let right = padding.right
        var bottom = padding.bottom + xLabelHeight
        if (legendVisible && config.legend.position == "bottom") {
            bottom += 26.0
        }
        this.plot = ChartRect(left, top, config.width - left - right, config.height - top - bottom)
    }

    func drawBackground(kit: ChartSvgKit): Unit {
        kit.background(this.config.width, this.config.height)
    }

    func drawTitle(kit: ChartSvgKit): Unit {
        if (this.config.title.isEmpty()) {
            return
        }
        let anchor = match (this.config.titleAlign) {
            case "left" => "start"
            case "right" => "end"
            case _ => "middle"
        }
        let x = match (this.config.titleAlign) {
            case "left" => this.config.padding.left
            case "right" => this.config.width - this.config.padding.right
            case _ => this.config.width / 2.0
        }
        kit.text(
            x,
            this.config.padding.top + this.config.titleFontSize / 2.0,
            this.config.title,
            size: this.config.titleFontSize,
            color: this.config.titleColor,
            anchor: anchor,
            className: "title"
        )
        if (!this.config.subtitle.isEmpty()) {
            kit.text(
                x,
                this.config.padding.top + this.config.titleFontSize + 6.0 + this.config.theme.fontSize / 2.0,
                this.config.subtitle,
                size: this.config.theme.fontSize,
                color: this.config.theme.textColor,
                anchor: anchor,
                className: "subtitle"
            )
        }
    }

    func drawLegend(kit: ChartSvgKit, names: Array<String>, colors: Array<String>): Unit {
        if (!this.legendVisible || names.isEmpty()) {
            return
        }
        let fontSize = this.config.theme.fontSize
        let marker = this.config.legend.markerSize
        let gap = this.config.legend.itemGap
        var total = 0.0
        for (index in 0..names.size) {
            total += marker + 4.0 + chartTextWidth(names[index], fontSize)
            if (index + 1 < names.size) {
                total += gap
            }
        }
        var x = (this.config.width - total) / 2.0
        let centerY = this.legendY
        for (index in 0..names.size) {
            kit.rect(
                x, centerY - marker / 2.0, marker, marker,
                fill: colors[index % colors.size],
                className: "legend-marker"
            )
            let textX = x + marker + 4.0
            kit.text(
                textX, centerY, names[index],
                size: fontSize,
                color: this.config.theme.legendTextColor,
                anchor: "start",
                className: "legend-item"
            )
            x = textX + chartTextWidth(names[index], fontSize) + gap
        }
    }

    func drawYAxis(kit: ChartSvgKit, ticks: Array<Float64>, scale: LinearScale): Unit {
        let axis = this.config.yAxis
        let theme = this.config.theme
        for (tick in ticks) {
            let y = scale.scale(tick)
            if (axis.grid) {
                kit.line(
                    this.plot.x, y, this.plot.right(), y,
                    stroke: theme.gridColor, strokeWidth: 1.0, className: "grid"
                )
            }
            kit.text(
                this.plot.x - 8.0, y,
                chartFormatTick(tick, axis.labelFormat),
                size: theme.fontSize,
                color: theme.axisColor,
                anchor: "end",
                className: "tick-label"
            )
        }
        kit.line(
            this.plot.x, this.plot.y, this.plot.x, this.plot.bottom(),
            stroke: theme.axisColor, strokeWidth: 1.0, className: "axis"
        )
        if (!axis.title.isEmpty()) {
            kit.text(
                14.0, this.plot.centerY(), axis.title,
                size: theme.fontSize,
                color: theme.textColor,
                anchor: "middle",
                className: "axis-title",
                rotate: -90.0
            )
        }
    }

    func drawXAxis(kit: ChartSvgKit, labels: Array<String>, band: BandScale): Unit {
        let axis = this.config.xAxis
        let theme = this.config.theme
        kit.line(
            this.plot.x, this.plot.bottom(), this.plot.right(), this.plot.bottom(),
            stroke: theme.axisColor, strokeWidth: 1.0, className: "axis"
        )
        let rotate = axis.labelRotate
        for (index in 0..labels.size) {
            let center = band.center(index)
            kit.line(
                center, this.plot.bottom(), center, this.plot.bottom() + 4.0,
                stroke: theme.axisColor, strokeWidth: 1.0, className: "tick"
            )
            let labelY = if (rotate == 0.0) {
                this.plot.bottom() + 6.0 + theme.fontSize / 2.0
            } else {
                this.plot.bottom() + 10.0
            }
            kit.text(
                center, labelY, labels[index],
                size: theme.fontSize,
                color: theme.axisColor,
                anchor: if (rotate == 0.0) { "middle" } else { "end" },
                className: "tick-label",
                rotate: rotate
            )
        }
        if (!axis.title.isEmpty()) {
            kit.text(
                this.plot.centerX(),
                this.plot.bottom() + theme.fontSize + 14.0,
                axis.title,
                size: theme.fontSize,
                color: theme.textColor,
                anchor: "middle",
                className: "axis-title"
            )
        }
    }

    func drawXAxisNumeric(
        kit: ChartSvgKit,
        ticks: Array<Float64>,
        scale: LinearScale,
        labels: Array<String>
    ): Unit {
        let axis = this.config.xAxis
        let theme = this.config.theme
        kit.line(
            this.plot.x, this.plot.bottom(), this.plot.right(), this.plot.bottom(),
            stroke: theme.axisColor, strokeWidth: 1.0, className: "axis"
        )
        let rotate = axis.labelRotate
        for (index in 0..ticks.size) {
            let x = scale.scale(ticks[index])
            kit.line(
                x, this.plot.bottom(), x, this.plot.bottom() + 4.0,
                stroke: theme.axisColor, strokeWidth: 1.0, className: "tick"
            )
            let labelY = if (rotate == 0.0) {
                this.plot.bottom() + 6.0 + theme.fontSize / 2.0
            } else {
                this.plot.bottom() + 10.0
            }
            kit.text(
                x, labelY, labels[index],
                size: theme.fontSize,
                color: theme.axisColor,
                anchor: if (rotate == 0.0) { "middle" } else { "end" },
                className: "tick-label",
                rotate: rotate
            )
        }
        if (!axis.title.isEmpty()) {
            kit.text(
                this.plot.centerX(),
                this.plot.bottom() + theme.fontSize + 14.0,
                axis.title,
                size: theme.fontSize,
                color: theme.textColor,
                anchor: "middle",
                className: "axis-title"
            )
        }
    }
}
