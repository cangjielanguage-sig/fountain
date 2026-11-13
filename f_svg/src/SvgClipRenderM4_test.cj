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

import stdx.encoding.base64.*
import std.unittest.*
import std.unittest.testmacro.*

private func m4RedAlpha(bitmap: SvgBitmap, x: Int64, y: Int64): Bool {
    let color = bitmap.pixel(x, y)
    color.alpha > 0.5 && color.red > 200
}

private func m4RedPngData(width: Int64, height: Int64): String {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(SvgColor.fromRgb(255, 0, 0))
    "data:image/png;base64," + toBase64String(bitmap.toPngBytes())
}

@Test
public class SvgClipRenderM4_test {
    /** 四边裁剪。 */
    @TestCase
    public func fourSideClip(): Unit {
        let document = svgDoc(
            '<rect width="20" height="20" fill="red" clip="rect(0, 10, 10, 0)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4RedAlpha(bitmap, 5, 5))
        @Assert(!m4RedAlpha(bitmap, 15, 5))
        @Assert(!m4RedAlpha(bitmap, 5, 15))
    }

    /** 单边 auto 不限制该方向。 */
    @TestCase
    public func singleAutoClip(): Unit {
        let document = svgDoc(
            '<rect width="10" height="20" fill="red" clip="rect(0, 10, auto, 0)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4RedAlpha(bitmap, 5, 15))
        @Assert(!m4RedAlpha(bitmap, 15, 15))
    }

    /** 旋转 45° 后裁剪矩形随 CTM 旋转。 */
    @TestCase
    public func rotatedClip(): Unit {
        let document = svgDoc(
            '<rect width="20" height="20" fill="red" clip="rect(0, 10, 10, 0)" ' +
            'transform="rotate(45)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4RedAlpha(bitmap, 3, 4))
        @Assert(!m4RedAlpha(bitmap, 9, 1))
    }

    /** clip 与 clip-path 叠加：交集。 */
    @TestCase
    public func clipAndClipPath(): Unit {
        let document = svgDoc(
            '<clipPath id="c"><rect x="2" y="2" width="6" height="6"/></clipPath>' +
            '<rect width="20" height="20" fill="red" clip="rect(0, 5, 5, 0)" ' +
            'clip-path="url(#c)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4RedAlpha(bitmap, 3, 3))
        @Assert(!m4RedAlpha(bitmap, 1, 1))
        @Assert(!m4RedAlpha(bitmap, 7, 7))
        @Assert(!m4RedAlpha(bitmap, 4, 7))
    }

    /** 滤镜先于 clip：越出 clip 的滤镜输出被裁掉，重复渲染逐字节一致。 */
    @TestCase
    public func filterBeforeClip(): Unit {
        let document = svgDoc(
            '<filter id="f"><feFlood flood-color="red"/></filter>' +
            '<rect width="20" height="20" filter="url(#f)" clip="rect(0, 5, 5, 0)"/>',
            width: 20,
            height: 20
        )
        let renderer = SvgRenderer()
        let first = renderer.render(document)
        @Assert(m4RedAlpha(first, 2, 2))
        @Assert(!m4RedAlpha(first, 10, 10))
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
    }

    /** clip 作用于文本。 */
    @TestCase
    public func textClip(): Unit {
        let document = svgDoc(
            '<text x="0" y="30" font-family="Hershey" font-size="20" fill="red" ' +
            'clip="rect(0, 5, 40, 0)">A</text>',
            width: 30,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        var inside = false
        var outside = false
        for (y in 0..35) {
            for (x in 0..30) {
                if (m4RedAlpha(bitmap, x, y)) {
                    if (x < 4) {
                        inside = true
                    }
                    if (x >= 8) {
                        outside = true
                    }
                }
            }
        }
        @Assert(inside)
        @Assert(!outside)
    }

    /** clip 作用于图像。 */
    @TestCase
    public func imageClip(): Unit {
        let data = m4RedPngData(20, 20)
        let document = svgDoc(
            '<image width="20" height="20" href="${data}" clip="rect(0, 10, 20, 0)"/>',
            width: 30,
            height: 30
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4RedAlpha(bitmap, 5, 5))
        @Assert(!m4RedAlpha(bitmap, 15, 5))
    }

    /** clip 作用于组内全部子元素。 */
    @TestCase
    public func groupClip(): Unit {
        let document = svgDoc(
            '<g clip="rect(0, 5, 5, 0)">' +
            '<rect width="20" height="20" fill="red"/>' +
            '</g>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4RedAlpha(bitmap, 2, 2))
        @Assert(!m4RedAlpha(bitmap, 10, 10))
    }
}
