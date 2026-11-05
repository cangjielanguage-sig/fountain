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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

private func m4StrokeAlphaAt(bitmap: SvgBitmap, x: Int64, fromY: Int64, toY: Int64): Int64 {
    var count = 0
    for (y in fromY..toY) {
        if (bitmap.pixel(x, y).alpha > 0.5) {
            count++
        }
    }
    count
}

@Test
public class SvgVectorEffectM4_test {
    /** 缩放系数：1 / sqrt(|det|)。 */
    @TestCase
    public func strokeScale(): Unit {
        @Assert(near(SvgVectorEffect.strokeScale(SvgMatrix.scale(2.0, 2.0)), 0.5))
        @Assert(near(SvgVectorEffect.strokeScale(SvgMatrix.scale(2.0, 1.0)), 1.0 / sqrt(2.0)))
        @Assert(SvgVectorEffect.strokeScale(SvgMatrix(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)) == 0.0)
    }

    /** scale(2) 下描边宽度在设备空间保持不变。 */
    @TestCase
    public func nonScalingUniform(): Unit {
        let scaled = svgDoc(
            '<g transform="scale(2)">' +
            '<line x1="0" y1="5" x2="10" y2="5" stroke="red" stroke-width="4" ' +
            'vector-effect="non-scaling-stroke"/></g>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(scaled)
        // 设备空间中心 y = 10，宽度 4 → 约 y 8..12。
        @Assert(m4StrokeAlphaAt(bitmap, 10, 8, 13) >= 3)
        @Assert(bitmap.pixel(10, 6).alpha == 0.0)

        let plain = svgDoc(
            '<g transform="scale(2)">' +
            '<line x1="0" y1="5" x2="10" y2="5" stroke="red" stroke-width="4"/></g>',
            width: 20,
            height: 20
        )
        let plainBitmap = SvgRenderer().render(plain)
        @Assert(plainBitmap.pixel(10, 6).alpha > 0.5)
    }

    /** scale(2,1) 使用 sqrt(|det|) 的平均缩放。 */
    @TestCase
    public func nonScalingNonUniform(): Unit {
        let document = svgDoc(
            '<g transform="scale(2,1)">' +
            '<line x1="0" y1="5" x2="10" y2="5" stroke="red" stroke-width="4" ' +
            'vector-effect="non-scaling-stroke"/></g>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        let thickness = m4StrokeAlphaAt(bitmap, 10, 0, 20)
        @Assert(thickness >= 2 && thickness <= 4)
    }

    /** 虚线段长按设备空间解释：与未缩放版本图案周期一致。 */
    @TestCase
    public func dashNotScaled(): Unit {
        let base = svgDoc(
            '<line x1="0" y1="5" x2="20" y2="5" stroke="red" stroke-width="2" ' +
            'stroke-dasharray="4 2"/>',
            width: 20,
            height: 20
        )
        let scaled = svgDoc(
            '<g transform="scale(2)">' +
            '<line x1="0" y1="5" x2="10" y2="5" stroke="red" stroke-width="2" ' +
            'stroke-dasharray="4 2" vector-effect="non-scaling-stroke"/></g>',
            width: 20,
            height: 20
        )
        let baseBitmap = SvgRenderer().render(base)
        let scaledBitmap = SvgRenderer().render(scaled)
        @Assert(m4StrokeAlphaAt(baseBitmap, 0, 4, 7) > 0)
        @Assert(m4StrokeAlphaAt(scaledBitmap, 0, 9, 12) > 0)
        // 非缩放时设备周期仍为 6，20 像素内约 4 段。
        var transitions = 0
        var previous = scaledBitmap.pixel(1, 10).alpha > 0.5
        for (x in 2..20) {
            let current = scaledBitmap.pixel(x, 10).alpha > 0.5
            if (current != previous) {
                transitions++
            }
            previous = current
        }
        @Assert(transitions >= 3 && transitions <= 7)
    }

    /** 非法取值记 warning 并按 none 处理。 */
    @TestCase
    public func invalidValue(): Unit {
        let document = svgDoc(
            '<line x1="0" y1="5" x2="20" y2="5" stroke="red" stroke-width="2" ' +
            'vector-effect="scaling-stroke"/>',
            width: 20,
            height: 20
        )
        let renderer = SvgRenderer()
        let bitmap = renderer.render(document)
        @Assert(bitmap.pixel(10, 5).alpha > 0.5)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("vector-effect")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** non-scaling-stroke 与 clip / 渐变描边叠加仍然确定。 */
    @TestCase
    public func combined(): Unit {
        let document = svgDoc(
            '<linearGradient id="g"><stop offset="0" stop-color="red"/>' +
            '<stop offset="1" stop-color="blue"/></linearGradient>' +
            '<g transform="scale(2)">' +
            '<line x1="0" y1="5" x2="10" y2="5" stroke="url(#g)" stroke-width="4" ' +
            'stroke-dasharray="4 2" vector-effect="non-scaling-stroke" ' +
            'clip="rect(0, 10, 10, 0)"/></g>',
            width: 20,
            height: 20
        )
        let renderer = SvgRenderer()
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(bitmapHasInk(first))
    }
}

private func bitmapHasInk(bitmap: SvgBitmap): Bool {
    for (index in 0..bitmap.pixels.size) {
        if (bitmap.pixels[index] != 0) {
            return true
        }
    }
    false
}
