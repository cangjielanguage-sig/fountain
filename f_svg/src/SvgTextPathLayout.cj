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
package fountain::f_svg

import std.collection.*
import std.math.*
import fountain::f_base.*

/** 一个字形在路径上的落位。 */
public class SvgTextPlacement {
    /** 字形中心点。 */
    public let x: Float64
    public let y: Float64
    /** 字形原点（advance 起点）。 */
    public let originX: Float64
    public let originY: Float64
    /** 切线方向，单位为度。 */
    public let angle: Float64

    internal init(
        x: Float64,
        y: Float64,
        originX: Float64,
        originY: Float64,
        angle: Float64
    ) {
        this.x = x
        this.y = y
        this.originX = originX
        this.originY = originY
        this.angle = angle
    }
}

private class SvgPathSegment {
    let x0: Float64
    let y0: Float64
    let x1: Float64
    let y1: Float64
    let start: Float64
    let length: Float64

    init(x0: Float64, y0: Float64, x1: Float64, y1: Float64, start: Float64, length: Float64) {
        this.x0 = x0
        this.y0 = y0
        this.x1 = x1
        this.y1 = y1
        this.start = start
        this.length = length
    }
}

/**
 * `textPath` 弧长排版：把字形 advance 序列映射到扁平化路径的弧长上。
 *
 * 字形中心落在 advance 中点的弧长处，原点落在 advance 起点；切线角按所在线段方向计算。
 * 路径短于文本时截断并记 warning。
 */
public class SvgTextPathLayout {
    public let warnings = ArrayList<String>()
    /** 路径本身无命令或总弧长 ≤ 0；用于区分“空路径”与“有效路径但无可放置字形”。 */
    internal var pathEmpty: Bool = false

    public func place(
        advances: Array<Float64>,
        path: SvgPathData,
        startOffset: SvgLength,
        anchor: SvgTextAnchor,
        side!: SvgTextPathSide = SvgTextPathSide.Left,
        method!: SvgTextPathMethod = SvgTextPathMethod.Align,
        spacing!: SvgTextPathSpacing = SvgTextPathSpacing.Auto,
        sideOffsets!: Array<Float64> = Array<Float64>(),
        dxOffsets!: Array<Float64> = Array<Float64>()
    ): Array<SvgTextPlacement> {
        this.pathEmpty = false
        let contours = flattenPathData(path, SvgMatrix.identity, 0.25)
        let segments = ArrayList<SvgPathSegment>()
        var total: Float64 = 0.0
        for (contour in contours) {
            var index = 1
            while (index < contour.size) {
                let previous = contour[index - 1]
                let current = contour[index]
                let dx = current.x - previous.x
                let dy = current.y - previous.y
                let length = sqrt(dx * dx + dy * dy)
                if (length > 0.0) {
                    segments.add(
                        SvgPathSegment(previous.x, previous.y, current.x, current.y, total, length)
                    )
                    total += length
                }
                index++
            }
        }
        if (total <= 0.0) {
            this.pathEmpty = true
            this.warnings.add("textPath 的路径为空，无法排版")
            return Array<SvgTextPlacement>()
        }
        var textAdvance: Float64 = 0.0
        for (advance in advances) {
            textAdvance += advance
        }
        let adjusted = Array<Float64>(advances.size, repeat: 0.0)
        for (index in 0..advances.size) {
            adjusted[index] = advances[index]
        }
        if (method == SvgTextPathMethod.Stretch && total > 0.0 && textAdvance > 0.0) {
            let factor = total / textAdvance
            for (index in 0..adjusted.size) {
                adjusted[index] = adjusted[index] * factor
            }
            textAdvance = total
        }
        var start = if (startOffset.unit == SvgLengthUnit.Percent) {
            startOffset.value / 100.0 * total
        } else {
            startOffset.value
        }
        if (start < 0.0) {
            start = 0.0
        }
        if (start > total) {
            start = total
        }
        match (anchor) {
            case Start => ()
            case Middle => start -= textAdvance / 2.0
            case End => start -= textAdvance
        }
        if (start < 0.0) {
            start = 0.0
        }
        let result = ArrayList<SvgTextPlacement>()
        var cursor = start
        var truncated = false
        var index: Int64 = 0
        while (index < adjusted.size) {
            let advance = adjusted[index]
            if (spacing == SvgTextPathSpacing.Exact && index < dxOffsets.size) {
                cursor += dxOffsets[index]
            }
            let centerDistance = cursor + advance / 2.0
            if (cursor + advance > total || centerDistance > total) {
                truncated = true
                break
            }
            let origin = samplePoint(segments, cursor)
            let center = samplePoint(segments, centerDistance)
            var originX = origin.x
            var originY = origin.y
            var centerX = center.x
            var centerY = center.y
            if (index < sideOffsets.size && sideOffsets[index] != 0.0) {
                let offset = if (side == SvgTextPathSide.Left) {
                    sideOffsets[index]
                } else {
                    -sideOffsets[index]
                }
                let radians = center.angle * 3.141592653589793 / 180.0
                let normalX = -sin(radians) * offset
                let normalY = cos(radians) * offset
                originX += normalX
                originY += normalY
                centerX += normalX
                centerY += normalY
            }
            result.add(
                SvgTextPlacement(centerX, centerY, originX, originY, center.angle)
            )
            cursor += advance
            index++
        }
        if (truncated) {
            this.warnings.add("文本长度超过 textPath 路径长度，超出部分已截断")
        }
        result.toArray()
    }
}

private class SvgPathSample {
    let x: Float64
    let y: Float64
    let angle: Float64

    init(x: Float64, y: Float64, angle: Float64) {
        this.x = x
        this.y = y
        this.angle = angle
    }
}

private func samplePoint(segments: ArrayList<SvgPathSegment>, distance: Float64): SvgPathSample {
    var last = segments[0]
    for (segment in segments) {
        last = segment
        if (distance <= segment.start + segment.length) {
            let offset = distance - segment.start
            let parameter = if (segment.length > 0.0) {
                offset / segment.length
            } else {
                0.0
            }
            let x = segment.x0 + (segment.x1 - segment.x0) * parameter
            let y = segment.y0 + (segment.y1 - segment.y0) * parameter
            let angle = atan2(segment.y1 - segment.y0, segment.x1 - segment.x0) * 180.0 /
                3.141592653589793
            return SvgPathSample(x, y, angle)
        }
    }
    SvgPathSample(last.x1, last.y1, 0.0)
}
