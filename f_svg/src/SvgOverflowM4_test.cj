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

import std.unittest.*
import std.unittest.testmacro.*

private func m4OpaqueRed(bitmap: SvgBitmap, x: Int64, y: Int64): Bool {
    let color = bitmap.pixel(x, y)
    color.alpha > 0.5 && color.red > 200
}

@Test
public class SvgOverflowM4_test {
    /** marker 默认裁剪到 markerWidth × markerHeight。 */
    @TestCase
    public func markerDefaultClip(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="4" markerHeight="4" refX="0" refY="0">' +
            '<rect width="20" height="20" fill="red"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 1, 1))
        @Assert(!m4OpaqueRed(bitmap, 10, 10))
    }

    /** overflow="visible" 放行 marker 内容。 */
    @TestCase
    public func markerVisible(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="4" markerHeight="4" refX="0" refY="0" ' +
            'overflow="visible"><rect width="20" height="20" fill="red"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 10, 10))
    }

    /** symbol 默认裁剪到 use 的宽高。 */
    @TestCase
    public func symbolClip(): Unit {
        let document = svgDoc(
            '<symbol id="s" viewBox="0 0 4 4">' +
            '<rect width="20" height="20" fill="red"/></symbol>' +
            '<use href="#s" x="0" y="0" width="4" height="4"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 1, 1))
        @Assert(!m4OpaqueRed(bitmap, 10, 10))
    }

    /** symbol overflow="visible" 放行。 */
    @TestCase
    public func symbolVisible(): Unit {
        let document = svgDoc(
            '<symbol id="s" viewBox="0 0 4 4" overflow="visible">' +
            '<rect width="20" height="20" fill="red"/></symbol>' +
            '<use href="#s" x="0" y="0" width="4" height="4"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 10, 10))
    }

    /** 嵌套 svg overflow="visible" 不裁剪。 */
    @TestCase
    public func nestedSvgVisible(): Unit {
        let document = svgDoc(
            '<svg x="0" y="0" width="4" height="4" overflow="visible">' +
            '<rect width="20" height="20" fill="red"/></svg>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 10, 10))
    }

    /** 嵌套 svg 默认（hidden）裁剪到视口。 */
    @TestCase
    public func nestedSvgHidden(): Unit {
        let document = svgDoc(
            '<svg x="0" y="0" width="4" height="4">' +
            '<rect width="20" height="20" fill="red"/></svg>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        @Assert(m4OpaqueRed(bitmap, 1, 1))
        @Assert(!m4OpaqueRed(bitmap, 10, 10))
    }

    /** 旋转视口按四边形裁剪，AABB 角部不得放行。 */
    @TestCase
    public func rotatedNestedSvgClip(): Unit {
        let document = svgDoc(
            '<svg x="10" y="10" width="40" height="40" transform="rotate(45 30 30)" ' +
            'viewBox="0 0 40 40"><rect x="-10" y="-10" width="60" height="60" fill="red"/></svg>',
            width: 60,
            height: 60
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4OpaqueRed(bitmap, 30, 30))
        @Assert(!m4OpaqueRed(bitmap, 12, 12))
        @Assert(!m4OpaqueRed(bitmap, 48, 48))
    }

    /** 旋转 marker 视口按四边形裁剪，且不放宽一个像素。 */
    @TestCase
    public func rotatedMarkerClip(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="10" markerHeight="10" refX="5" refY="5" orient="45">' +
            '<rect x="-10" y="-10" width="30" height="30" fill="red"/></marker>' +
            '<line x1="30" y1="30" x2="40" y2="30" stroke="black" marker-start="url(#m)"/>',
            width: 60,
            height: 60
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4OpaqueRed(bitmap, 30, 30))
        @Assert(!m4OpaqueRed(bitmap, 24, 24))
        @Assert(!m4OpaqueRed(bitmap, 36, 36))
    }

    /** pattern overflow="visible" 不向相邻 tile 扩展。 */
    @TestCase
    public func patternTileBoundary(): Unit {
        let document = svgDoc(
            '<pattern id="p" width="4" height="4" patternUnits="userSpaceOnUse" ' +
            'overflow="visible"><rect x="10" y="0" width="4" height="4" fill="red"/></pattern>' +
            '<rect width="20" height="20" fill="url(#p)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer().render(document)
        for (y in 0..20) {
            for (x in 0..20) {
                @Assert(!m4OpaqueRed(bitmap, x, y))
            }
        }
    }
}
