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
import fountain::f_base.*

/** `clip: rect()` 的四个分量；`None` 表示 `auto`（该边不限制）。 */
public struct SvgClipRect <: ToString {
    public let top: ?Float64
    public let right: ?Float64
    public let bottom: ?Float64
    public let left: ?Float64

    public init(top: ?Float64, right: ?Float64, bottom: ?Float64, left: ?Float64) {
        this.top = top
        this.right = right
        this.bottom = bottom
        this.left = left
    }

    public func toString(): String {
        "rect(${clipEdge(this.top)}, ${clipEdge(this.right)}, ${clipEdge(this.bottom)}, ${clipEdge(this.left)})"
    }
}

private func clipEdge(value: ?Float64): String {
    match (value) {
        case Some(number) => formatSvgNumber(number)
        case None => "auto"
    }
}

/** `clip` 属性解析与覆盖率裁剪。 */
public class SvgClipProperty {
    /** 解析 `clip` 的计算值；无法识别返回 `None`。 */
    public static func parse(text: String): ?SvgClipRect {
        let trimmed = text.trimAscii()
        let lower = trimmed.toAsciiLower()
        if (lower == "none" || lower == "auto") {
            return None
        }
        if (lower.size <= 5 || lower[0..5] != "rect(") {
            return None
        }
        let close = indexOfSvgByte(trimmed, b')')
        if (close < 0 || close != trimmed.size - 1) {
            return None
        }
        let body = trimmed[5..close]
        let tokens = splitClipComponents(body)
        if (tokens.size != 4) {
            return None
        }
        var values = ArrayList<?Float64>()
        for (token in tokens) {
            if (token.toAsciiLower() == "auto") {
                values.add(Option<Float64>.None)
            } else {
                match (SvgLength.tryParse(token)) {
                    case Some(length) =>
                        if (!isFiniteSvgNumber(length.value)) {
                            return None
                        }
                        values.add(Some(length.value))
                    case None => return None
                }
            }
        }
        SvgClipRect(values[0], values[1], values[2], values[3])
    }

    /** 归一化 `clip` 值；`none` / `auto` 原样返回，非法返回 `None`。 */
    internal static func normalize(text: String): ?String {
        let trimmed = text.trimAscii()
        let lower = trimmed.toAsciiLower()
        if (lower == "none" || lower == "auto") {
            return Some(lower)
        }
        match (parse(trimmed)) {
            case Some(rect) => Some(rect.toString())
            case None => None
        }
    }

    /** 转为用户空间矩形；`auto` 边扩展到无穷，`limit` 取足够大的值。 */
    public static func toBounds(rect: SvgClipRect, limit!: Float64 = 1.0e9): SvgBounds {
        let top = rect.top ?? -limit
        let right = rect.right ?? limit
        let bottom = rect.bottom ?? limit
        let left = rect.left ?? -limit
        let width = if (right > left) { right - left } else { 0.0 }
        let height = if (bottom > top) { bottom - top } else { 0.0 }
        SvgBounds(left, top, width, height)
    }
}

/** `clip` 的覆盖率蒙版渲染。 */
public class SvgClipCoverage {
    public static func render(
        clip: SvgClipRect,
        matrix: SvgMatrix,
        width: Int64,
        height: Int64,
        samplesPerPixel!: Int64 = 4,
        antiAlias!: SvgAntiAliasMode = SvgAntiAliasMode.Supersample
    ): SvgCoverageMask {
        if (width <= 0 || height <= 0) {
            throw invalidValue("clip 蒙版尺寸必须为正，实际 ${width}×${height}")
        }
        let mask = SvgCoverageMask(width, height)
        let box = SvgClipProperty.toBounds(clip)
        if (box.width <= 0.0 || box.height <= 0.0) {
            return mask
        }
        let scratch = SvgBitmap(width, height)
        let path = SvgPathData([
            SvgPathCommand(SvgPathCommandKind.MoveTo, false, [box.x, box.y]),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [box.x + box.width, box.y]),
            SvgPathCommand(
                SvgPathCommandKind.LineTo,
                false,
                [box.x + box.width, box.y + box.height]
            ),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [box.x, box.y + box.height]),
            SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
        ])
        SvgRasterizer(scratch, samplesPerPixel: samplesPerPixel, antiAlias: antiAlias).fill(
            path,
            matrix: matrix,
            color: SvgColor.White,
            fillRule: SvgFillRule.Nonzero,
            opacity: 1.0
        )
        for (index in 0..(width * height)) {
            mask.coverage[index] = scratch.pixels[index * 4 + 3]
        }
        mask
    }
}

private func splitClipComponents(body: String): Array<String> {    let result = ArrayList<String>()
    let bytes = body.unsafeBytes()
    var index = 0
    while (index < bytes.size) {
        while (index < bytes.size && (isSvgSpace(bytes[index]) || bytes[index] == b',')) {
            index++
        }
        if (index >= bytes.size) {
            break
        }
        let start = index
        while (index < bytes.size && bytes[index] != b',' && !isSvgSpace(bytes[index])) {
            index++
        }
        let token = body[start..index].trimAscii()
        if (token.size > 0) {
            result.add(token)
        }
    }
    result.toArray()
}
