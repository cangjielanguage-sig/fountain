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

/** 扁平化后的一段折线。 */
internal struct SvgMeasuredSegment {
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

/** 弧长采样点。 */
internal struct SvgMeasuredPoint {
    let x: Float64
    let y: Float64
    let angle: Float64

    init(x: Float64, y: Float64, angle: Float64) {
        this.x = x
        this.y = y
        this.angle = angle
    }
}

/**
 * 路径长度与取点的唯一实现。
 *
 * 与 `textPath` 共用同一份扁平化段表；容差非正或非有限抛 `InvalidValue`。
 */
internal class SvgPathMeasure {
    static func validateTolerance(tolerance: Float64): Unit {
        if (!isFiniteSvgNumber(tolerance) || tolerance <= 0.0) {
            throw invalidValue("路径长度容差必须为正的有限数，实际 ${tolerance}")
        }
    }

    static func buildSegments(
        path: SvgPathData,
        tolerance: Float64,
        refine!: Bool = true
    ): ArrayList<SvgMeasuredSegment> {
        validateTolerance(tolerance)
        // 折线长度是弦长，始终低估真实弧长；用更细的细分保证默认容差下误差足够小。
        // `textPath` 走 `refine = false` 以保持 M3 的逐字节输出。
        let effectiveTolerance = if (refine) { tolerance * 0.05 } else { tolerance }
        let contours = flattenPathData(path, SvgMatrix.identity, effectiveTolerance)
        let segments = ArrayList<SvgMeasuredSegment>()
        var total = 0.0
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
                        SvgMeasuredSegment(
                            previous.x,
                            previous.y,
                            current.x,
                            current.y,
                            total,
                            length
                        )
                    )
                    total += length
                }
                index++
            }
        }
        segments
    }

    static func totalLength(path: SvgPathData, tolerance: Float64): Float64 {
        let segments = buildSegments(path, tolerance)
        if (segments.size == 0) {
            return 0.0
        }
        let last = segments[segments.size - 1]
        last.start + last.length
    }

    static func sample(segments: ArrayList<SvgMeasuredSegment>, distance: Float64): SvgMeasuredPoint {
        if (segments.size == 0) {
            return SvgMeasuredPoint(0.0, 0.0, 0.0)
        }
        let last = segments[segments.size - 1]
        let total = last.start + last.length
        var target = distance
        if (target < 0.0) {
            target = 0.0
        }
        if (target > total) {
            target = total
        }
        for (segment in segments) {
            if (target <= segment.start + segment.length) {
                let offset = target - segment.start
                let parameter = if (segment.length > 0.0) {
                    offset / segment.length
                } else {
                    0.0
                }
                let x = segment.x0 + (segment.x1 - segment.x0) * parameter
                let y = segment.y0 + (segment.y1 - segment.y0) * parameter
                let angle = atan2(segment.y1 - segment.y0, segment.x1 - segment.x0) *
                    180.0 / 3.141592653589793
                return SvgMeasuredPoint(x, y, angle)
            }
        }
        SvgMeasuredPoint(last.x1, last.y1, 0.0)
    }

    static func pointAt(
        path: SvgPathData,
        distance: Float64,
        tolerance: Float64
    ): SvgMeasuredPoint {
        // 与 textPath 使用同一细分精度，保证落点逐点一致。
        sample(buildSegments(path, tolerance, refine: false), distance)
    }
}
