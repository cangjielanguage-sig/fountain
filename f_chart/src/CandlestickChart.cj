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
import fountain::f_svg.{SvgBuilder, SvgViewBox}

/** 蜡烛图的一根 K 线。 */
internal class Candle {
    let date: String
    let open: Float64
    let high: Float64
    let low: Float64
    let close: Float64

    init(date: String, open: Float64, high: Float64, low: Float64, close: Float64) {
        this.date = date
        this.open = open
        this.high = high
        this.low = low
        this.close = close
    }
}

/** M83 蜡烛图 / K 线图。 */
public class CandlestickChart <: Chart {
    public init() {}

    public func draw(data: JsonObject): String {
        let config = ChartConfig.parse(data, "candlestick")
        let root = ChartJson.of(data)
        let seriesArray = root.requiredArray("series")
        let seriesItems = seriesArray.getItems()
        if (seriesItems.isEmpty()) {
            throw chartMissingField("series")
        }
        if (seriesItems.size != 1) {
            throw chartInvalidValue("series", "蜡烛图仅支持 1 个系列")
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
        let candles = ArrayList<Candle>()
        var itemIndex = 0
        for (item in dataItems) {
            let itemPath = "series[0].data[${itemIndex}]"
            if (!item.kind.isObject) {
                throw chartInvalidValue(itemPath, "期望 K 线对象")
            }
            let json = ChartJson.of(item.asObject(), itemPath)
            let date = json.string("date", default: (itemIndex + 1).toString())
            let open = bulletNumber(json, "open", itemPath)
            let high = bulletNumber(json, "high", itemPath)
            let low = bulletNumber(json, "low", itemPath)
            let close = bulletNumber(json, "close", itemPath)
            if (high < open || high < close || high < low) {
                throw chartInvalidValue("${itemPath}.high", "最高价不得低于开盘、收盘或最低价")
            }
            if (low > open || low > close) {
                throw chartInvalidValue("${itemPath}.low", "最低价不得高于开盘或收盘")
            }
            candles.add(Candle(date, open, high, low, close))
            itemIndex++
        }
        let candleArray = candles.toArray()

        let labels = ArrayList<String>()
        if (!config.xAxis.labels.isEmpty()) {
            if (config.xAxis.labels.size != candleArray.size) {
                throw chartInvalidValue("xAxis.labels", "标签数量与数据长度不一致")
            }
            for (label in config.xAxis.labels) {
                labels.add(label)
            }
        } else {
            for (candle in candleArray) {
                labels.add(candle.date)
            }
        }

        var dataMin = candleArray[0].low
        var dataMax = candleArray[0].high
        for (candle in candleArray) {
            dataMin = minFloat(dataMin, candle.low)
            dataMax = maxFloat(dataMax, candle.high)
        }
        var span = dataMax - dataMin
        if (span <= 0.0) {
            span = 1.0
        }
        let yMin = match (config.yAxis.min) {
            case Some(value) => value
            case None => dataMin - span * 0.05
        }
        let yMax = match (config.yAxis.max) {
            case Some(value) => value
            case None => dataMax + span * 0.05
        }
        if (yMax <= yMin) {
            throw chartInvalidValue("yAxis.min", "yAxis.min 必须小于 yAxis.max")
        }
        let yTicks = if (!config.yAxis.values.isEmpty()) {
            config.yAxis.values
        } else {
            chartNiceTicks(yMin, yMax, config.yAxis.tickCount)
        }

        let legendVisible = config.legend.show && !seriesName.isEmpty()
        var maxYLabelWidth = 0.0
        for (tick in yTicks) {
            maxYLabelWidth = maxFloat(
                maxYLabelWidth,
                chartTextWidth(chartFormatTick(tick, config.yAxis.labelFormat), config.theme.fontSize)
            )
        }
        let xLabelHeight = if (config.xAxis.labelRotate == 0.0) {
            config.theme.fontSize + 12.0
        } else {
            48.0
        }
        let frame = ChartFrame(config, legendVisible, maxYLabelWidth + 12.0, xLabelHeight)
        let band = BandScale(frame.plot.x, frame.plot.right(), candleArray.size)
        let yScale = LinearScale(yMin, yMax, frame.plot.y, frame.plot.bottom())

        let builder = SvgBuilder(
            config.width,
            config.height,
            viewBox: SvgViewBox(0.0, 0.0, config.width, config.height)
        )
        builder.attr("font-family", config.theme.fontFamily)
        let kit = ChartSvgKit(builder, config.theme)
        frame.drawBackground(kit)
        frame.drawTitle(kit)

        let legendNames: Array<String> = if (legendVisible) { [seriesName] } else { Array<String>() }
        let legendColors: Array<String> = if (legendVisible) {
            [config.theme.colorAt(0)]
        } else {
            Array<String>()
        }
        frame.drawLegend(kit, legendNames, legendColors)
        frame.drawYAxis(kit, yTicks, yScale)

        let bodyWidth = minFloat(band.bandWidth * 0.6, 18.0)
        for (index in 0..candleArray.size) {
            let candle = candleArray[index]
            let centerX = band.center(index)
            let up = candlestickUp(candle.open, candle.close)
            let color = if (up) { "#e53935" } else { "#43a047" }
            kit.line(
                centerX, yScale.scale(candle.high), centerX, yScale.scale(candle.low),
                stroke: color, strokeWidth: 1.0, className: "candlestick-wick"
            )
            let openY = yScale.scale(candle.open)
            let closeY = yScale.scale(candle.close)
            let top = minFloat(openY, closeY)
            let height = maxFloat(abs(openY - closeY), 1.0)
            let className = if (up) {
                "candlestick-body candlestick-up"
            } else {
                "candlestick-body candlestick-down"
            }
            kit.rect(
                centerX - bodyWidth / 2.0, top, bodyWidth, height,
                fill: color, className: className
            )
        }
        frame.drawXAxis(kit, labels.toArray(), band)
        builder.toSvgString()
    }
}

/** 收盘不低于开盘即为上涨（含平盘）。 */
internal func candlestickUp(open: Float64, close: Float64): Bool {
    close >= open
}
