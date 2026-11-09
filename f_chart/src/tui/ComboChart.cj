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

import std.collection.ArrayList
import std.math.*
import fountain::f_chart.*
import fountain::f_data.json.*

internal class TuiComboSeries {
    let name: String
    let kind: String
    let values: Array<?Float64>
    let color: String
    let stack: String
    let rightAxis: Bool

    init(
        name: String,
        kind: String,
        values: Array<?Float64>,
        color: String,
        stack: String,
        rightAxis: Bool
    ) {
        this.name = name
        this.kind = kind
        this.values = values
        this.color = color
        this.stack = stack
        this.rightAxis = rightAxis
    }

    func isBar(): Bool {
        this.kind == "bar" || this.kind == "grouped-bar" ||
            this.kind == "stacked-bar" || this.kind == "percent-stacked-bar"
    }
}

internal class TuiBarSlot {
    let mode: String
    let key: String
    let indexes: ArrayList<Int64>

    init(mode: String, key: String) {
        this.mode = mode
        this.key = key
        this.indexes = ArrayList<Int64>()
    }
}

/** M7 组合图的 TUI 实现。 */
public class TuiComboChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(
            data, "combo", defaultWidth: 80.0, defaultHeight: 24.0
        )
        if (config.xAxis.axisType != "category") {
            throw chartInvalidValue("xAxis.type", "TUI 组合图需要类目横轴")
        }
        let root = ChartJson.of(data)
        let items = root.requiredArray("series").getItems()
        if (items.isEmpty()) {
            throw chartMissingField("series")
        }
        let series = ArrayList<TuiComboSeries>()
        var seriesIndex = 0
        for (item in items) {
            let seriesPath = "series[${seriesIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(seriesPath, "期望系列对象")
            }
            let json = ChartJson.of(item.asObject(), seriesPath)
            let kind = json.string("type", default: "bar")
            if (!isSupportedComboKind(kind)) {
                throw chartInvalidValue("${seriesPath}.type", "不支持的组合系列类型 ${kind}")
            }
            let values = json.numberOrNullArray("data")
            if (values.isEmpty()) {
                throw chartInvalidValue("${seriesPath}.data", "数据不能为空")
            }
            let rightAxis = json.string("axis", default: "left") == "right"
            if (rightAxis && config.yAxis2.isNone()) {
                throw chartInvalidValue("${seriesPath}.axis", "right 轴需要 yAxis2")
            }
            series.add(TuiComboSeries(
                json.string("name", default: ""),
                kind,
                values,
                tuiSeriesColor(config, seriesIndex, json.string("color", default: "")),
                json.string("stack", default: ""),
                rightAxis
            ))
            seriesIndex++
        }
        var count: Int64 = 1
        for (item in series) {
            count = tuiMaxInt64(count, item.values.size)
        }
        let labels = tuiResolveLabels(config, count)
        for (item in series) {
            if (item.values.size != labels.size) {
                throw chartInvalidValue("series.data", "数据长度必须与 xAxis.labels 一致")
            }
        }

        let leftValues = ArrayList<Float64>()
        let rightValues = ArrayList<Float64>()
        var hasBarLeft = false
        var hasBarRight = false
        var hasRight = false
        for (item in series) {
            if (item.rightAxis) {
                hasRight = true
                if (item.isBar()) {
                    hasBarRight = true
                }
            } else if (item.isBar()) {
                hasBarLeft = true
            }
            for (value in item.values) {
                match (value) {
                    case Some(number) =>
                        if (item.rightAxis) {
                            rightValues.add(number)
                        } else {
                            leftValues.add(number)
                        }
                    case None => ()
                }
            }
        }
        let leftRange = tuiValueRange(leftValues.toArray(), config.yAxis, hasBarLeft)
        let leftTicks = tuiTicks(leftRange, config.yAxis)
        let leftLabelWidth = tuiTickLabelWidth(leftTicks, config.yAxis)
        let rightAxisConfig = match (config.yAxis2) {
            case Some(axis) => axis
            case None => config.yAxis
        }
        let rightRange = tuiValueRange(rightValues.toArray(), rightAxisConfig, hasBarRight)
        let rightTicks = if (hasRight) {
            tuiTicks(rightRange, rightAxisConfig)
        } else {
            Array<Float64>()
        }
        let rightLabelWidth = if (hasRight) {
            tuiTickLabelWidth(rightTicks, rightAxisConfig) + 2
        } else {
            0
        }
        let names = ArrayList<String>()
        let colors = ArrayList<String>()
        for (item in series) {
            names.add(item.name)
            colors.add(item.color)
        }
        let legend = tuiLegendVisible(config, names.toArray())
        let frame = TuiFrame(
            config, leftLabelWidth, rightLabelWidth: rightLabelWidth,
            legendVisible: legend
        )
        let canvas = TuiCanvas(Int64(config.width), Int64(config.height))
        frame.drawTitle(canvas)
        frame.drawLegend(canvas, names.toArray(), colors.toArray())
        let leftScale = LinearScale(
            leftRange[0], leftRange[1],
            Float64(frame.plot.y), Float64(frame.plot.bottom())
        )
        frame.drawYAxis(canvas, leftTicks, leftScale)
        var rightScale = leftScale
        if (hasRight) {
            rightScale = LinearScale(
                rightRange[0], rightRange[1],
                Float64(frame.plot.y), Float64(frame.plot.bottom())
            )
            for (tick in rightTicks) {
                let row = clampTuiRow(
                    Int64(round(rightScale.scale(tick))), frame.plot
                )
                canvas.putText(
                    frame.plot.right() + 2, row,
                    chartFormatTick(tick, rightAxisConfig.labelFormat),
                    config.theme.axisColor
                )
            }
        }
        let band = BandScale(
            Float64(frame.plot.x), Float64(frame.plot.right()), labels.size
        )
        let slots = buildBarSlots(series)
        drawBars(canvas, frame, band, series, slots, leftScale, rightScale)
        drawOverlays(canvas, frame, band, series, leftScale, rightScale)
        frame.drawXAxisCategory(canvas, labels, band)
        canvas.render()
    }

    private func isSupportedComboKind(kind: String): Bool {
        kind == "bar" || kind == "line" || kind == "scatter" ||
            kind == "grouped-bar" || kind == "stacked-bar" ||
            kind == "percent-stacked-bar"
    }

    private func buildBarSlots(series: ArrayList<TuiComboSeries>): ArrayList<TuiBarSlot> {
        let slots = ArrayList<TuiBarSlot>()
        for (index in 0..series.size) {
            let item = series[index]
            if (!item.isBar()) {
                continue
            }
            if (item.kind == "bar" || item.kind == "grouped-bar") {
                let slot = TuiBarSlot("plain", "plain-${index}")
                slot.indexes.add(index)
                slots.add(slot)
            } else if (item.kind == "percent-stacked-bar") {
                let key = "percent"
                var slot: Option<TuiBarSlot> = None
                for (existing in slots) {
                    if (existing.mode == "percent") {
                        slot = Some(existing)
                    }
                }
                match (slot) {
                    case Some(existing) => existing.indexes.add(index)
                    case None =>
                        let created = TuiBarSlot("percent", key)
                        created.indexes.add(index)
                        slots.add(created)
                }
            } else {
                let key = if (item.stack.isEmpty()) { item.name } else { item.stack }
                var slot: Option<TuiBarSlot> = None
                for (existing in slots) {
                    if (existing.mode == "stacked" && existing.key == key) {
                        slot = Some(existing)
                    }
                }
                match (slot) {
                    case Some(existing) => existing.indexes.add(index)
                    case None =>
                        let created = TuiBarSlot("stacked", key)
                        created.indexes.add(index)
                        slots.add(created)
                }
            }
        }
        slots
    }

    private func drawBars(
        canvas: TuiCanvas,
        frame: TuiFrame,
        band: BandScale,
        series: ArrayList<TuiComboSeries>,
        slots: ArrayList<TuiBarSlot>,
        leftScale: LinearScale,
        rightScale: LinearScale
    ): Unit {
        if (slots.isEmpty()) {
            return
        }
        let slotWidth = band.bandWidth / Float64(slots.size)
        let barWidth = tuiMaxInt64(Int64(floor(slotWidth * 0.6)), 1)
        for (slotIndex in 0..slots.size) {
            let slot = slots[slotIndex]
            let first = series[slot.indexes[0]]
            let scale = if (first.rightAxis) { rightScale } else { leftScale }
            let categoryCount = first.values.size
            for (category in 0..categoryCount) {
                let slotStart = band.bandStart(category) + Float64(slotIndex) * slotWidth
                let x = Int64(round(slotStart + (slotWidth - Float64(barWidth)) / 2.0))
                if (slot.mode == "plain") {
                    match (first.values[category]) {
                        case Some(value) =>
                            let fromRow = clampTuiRow(
                                Int64(round(scale.scale(0.0))), frame.plot
                            )
                            let toRow = clampTuiRow(
                                Int64(round(scale.scale(value))), frame.plot
                            )
                            tuiFillColumn(
                                canvas, x, barWidth, fromRow, toRow, first.color,
                                symbol: tuiSeriesSymbol(slot.indexes[0])
                            )
                        case None => ()
                    }
                } else {
                    var positive = 0.0
                    if (slot.mode == "percent") {
                        for (index in 0..slot.indexes.size) {
                            match (series[slot.indexes[index]].values[category]) {
                                case Some(value) =>
                                    if (value > 0.0) {
                                        positive += value
                                    }
                                case None => ()
                            }
                        }
                    }
                    var positiveBase = 0.0
                    var negativeBase = 0.0
                    for (index in 0..slot.indexes.size) {
                        let item = series[slot.indexes[index]]
                        match (item.values[category]) {
                            case Some(value) =>
                                var from = 0.0
                                var to = 0.0
                                if (slot.mode == "percent") {
                                    if (value <= 0.0 || positive <= 0.0) {
                                        continue
                                    }
                                    from = positiveBase
                                    to = positiveBase + value / positive * 100.0
                                    positiveBase = to
                                } else if (value >= 0.0) {
                                    from = positiveBase
                                    to = positiveBase + value
                                    positiveBase = to
                                } else {
                                    from = negativeBase
                                    to = negativeBase + value
                                    negativeBase = to
                                }
                                let fromRow = clampTuiRow(
                                    Int64(round(scale.scale(from))), frame.plot
                                )
                                let toRow = clampTuiRow(
                                    Int64(round(scale.scale(to))), frame.plot
                                )
                                tuiFillColumn(
                                    canvas, x, barWidth, fromRow, toRow, item.color,
                                    symbol: tuiSeriesSymbol(slot.indexes[index])
                                )
                            case None => ()
                        }
                    }
                }
            }
        }
    }

    private func drawOverlays(
        canvas: TuiCanvas,
        frame: TuiFrame,
        band: BandScale,
        series: ArrayList<TuiComboSeries>,
        leftScale: LinearScale,
        rightScale: LinearScale
    ): Unit {
        for (item in series) {
            if (item.isBar()) {
                continue
            }
            let scale = if (item.rightAxis) { rightScale } else { leftScale }
            var previousX: Int64 = 0
            var previousY: Int64 = 0
            var hasPrevious = false
            for (index in 0..item.values.size) {
                match (item.values[index]) {
                    case Some(value) =>
                        let px = clampTuiColumn(
                            Int64(round(band.center(index))), frame.plot
                        )
                        let py = clampTuiRow(
                            Int64(round(scale.scale(value))), frame.plot
                        )
                        if (item.kind == "line" && hasPrevious) {
                            canvas.drawLine(
                                previousX, previousY, px, py, "*", item.color
                            )
                        }
                        canvas.set(px, py, "o", item.color)
                        previousX = px
                        previousY = py
                        hasPrevious = true
                    case None => hasPrevious = false
                }
            }
        }
    }
}
