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
import fountain::f_svg.formatSvgNumber

/** 线性比例尺：数据值 → 像素。`topPixel` 对应最大值，`bottomPixel` 对应最小值。 */
internal class LinearScale {
    let minValue: Float64
    let maxValue: Float64
    let topPixel: Float64
    let bottomPixel: Float64

    init(minValue: Float64, maxValue: Float64, topPixel: Float64, bottomPixel: Float64) {
        this.minValue = minValue
        this.maxValue = maxValue
        this.topPixel = topPixel
        this.bottomPixel = bottomPixel
    }

    func scale(value: Float64): Float64 {
        let span = this.maxValue - this.minValue
        if (abs(span) < 1e-12) {
            (this.topPixel + this.bottomPixel) / 2.0
        } else {
            this.bottomPixel - (value - this.minValue) / span * (this.bottomPixel - this.topPixel)
        }
    }
}

/** 类目比例尺：第 i 个类目占一个等宽槽位。 */
internal class BandScale {
    let startPixel: Float64
    let endPixel: Float64
    let count: Int64
    let bandWidth: Float64

    init(startPixel: Float64, endPixel: Float64, count: Int64) {
        this.startPixel = startPixel
        this.endPixel = endPixel
        this.count = count
        this.bandWidth = if (count <= 0) { 0.0 } else { (endPixel - startPixel) / Float64(count) }
    }

    func bandStart(index: Int64): Float64 {
        this.startPixel + Float64(index) * this.bandWidth
    }

    func center(index: Int64): Float64 {
        this.bandStart(index) + this.bandWidth / 2.0
    }
}

/** 1/2/5×10ⁿ 的 nice 刻度。 */
internal func chartNiceTicks(min: Float64, max: Float64, count: Int64): Array<Float64> {
    if (count <= 0) {
        return [min, max]
    }
    if (max <= min) {
        return [min]
    }
    let rawStep = (max - min) / Float64(count)
    if (rawStep <= 0.0 || rawStep.isNaN() || rawStep.isInf()) {
        return [min, max]
    }
    let exponent = floor(log10(rawStep))
    let magnitude = pow(10.0, exponent)
    let normalized = rawStep / magnitude
    let niceNormalized = if (normalized <= 1.0) {
        1.0
    } else if (normalized <= 2.0) {
        2.0
    } else if (normalized <= 5.0) {
        5.0
    } else {
        10.0
    }
    let step = niceNormalized * magnitude
    let start = floor(min / step) * step
    let stop = ceil(max / step) * step
    let ticks = ArrayList<Float64>()
    var value = start
    var guard = 0
    while (value <= stop + step * 0.5 && guard < 1000) {
        ticks.add(if (abs(value) < step * 1e-9) { 0.0 } else { value })
        value += step
        guard++
    }
    ticks.toArray()
}

/** 按 `labelFormat` 格式化刻度，`{value}` 为占位符。 */
internal func chartFormatTick(value: Float64, labelFormat: String): String {
    labelFormat.replace("{value}", formatSvgNumber(value))
}

/** 粗略文本宽度：CJK 按 1em，其余按 0.56em。用于边距与图例布局。 */
internal func chartTextWidth(text: String, fontSize: Float64): Float64 {
    var width = 0.0
    for (rune in text.runes()) {
        if (rune.position() >= 0x2E80) {
            width += fontSize
        } else {
            width += fontSize * 0.56
        }
    }
    width
}
