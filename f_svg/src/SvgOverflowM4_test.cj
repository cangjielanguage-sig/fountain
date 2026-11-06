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

    /** viewBox 放大后的 marker 内容越界必须裁剪。 */
    @TestCase
    public func markerViewBoxScalingClips(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="10" markerHeight="10" refX="0" refY="0" ' +
            'markerUnits="userSpaceOnUse" viewBox="0 0 5 5">' +
            '<rect width="6" height="6" fill="red"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4OpaqueRed(bitmap, 5, 5))
        // viewBox 把 6 单位内容放大到 12，超出 10×10 视口。
        @Assert(!m4OpaqueRed(bitmap, 11, 5))
    }

    /** 计算样式里的描边同样算作越界风险，不能跳过裁剪。 */
    @TestCase
    public func markerStyledStrokeClips(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="4" markerHeight="4" refX="0" refY="0" ' +
            'markerUnits="userSpaceOnUse">' +
            '<rect width="4" height="4" fill="blue" style="stroke:red;stroke-width:4"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(!m4OpaqueRed(bitmap, 5, 2))
    }

    /** 计算样式里的滤镜会扩大绘制区域，仍需按 marker 视口裁剪。 */
    @TestCase
    public func markerStyledFilterClips(): Unit {
        let document = svgDoc(
            '<defs><filter id="f" x="-100%" y="-100%" width="300%" height="300%">' +
            '<feFlood flood-color="red"/></filter></defs>' +
            '<marker id="m" markerWidth="4" markerHeight="4" refX="0" refY="0" ' +
            'markerUnits="userSpaceOnUse">' +
            '<rect width="2" height="2" fill="red" style="filter:url(#f)"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4OpaqueRed(bitmap, 1, 1))
        @Assert(!m4OpaqueRed(bitmap, 5, 1))
    }

    /** 内容完全在视口内时保留不建蒙版的快路径。 */
    @TestCase
    public func markerContentFitsSkipsMask(): Unit {
        let document = svgDoc(
            '<marker id="m" markerWidth="10" markerHeight="10" refX="0" refY="0" ' +
            'markerUnits="userSpaceOnUse" viewBox="0 0 5 5">' +
            '<rect width="4" height="4" fill="red"/></marker>' +
            '<line x1="0" y1="0" x2="20" y2="0" stroke="black" marker-start="url(#m)"/>',
            width: 20,
            height: 20
        )
        let list = SvgRenderTreeBuilder().build(document)
        var found = false
        for (command in list.commands) {
            if (command.tag == "rect") {
                found = true
                @Assert(command.clipRect.isNone())
                @Assert(command.clipQuads.size == 0)
            }
        }
        @Assert(found)
    }

    /** 嵌套旋转视口共用一张蒙版时仍按交集裁剪。 */
    @TestCase
    public func nestedRotatedQuadsIntersect(): Unit {
        let document = svgDoc(
            '<svg x="10" y="10" width="60" height="60" transform="rotate(20 40 40)" ' +
            'viewBox="0 0 60 60">' +
            '<svg x="10" y="10" width="40" height="40" transform="rotate(-25 30 30)" ' +
            'viewBox="0 0 40 40">' +
            '<rect x="-20" y="-20" width="100" height="100" fill="red"/></svg></svg>',
            width: 80,
            height: 80
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4OpaqueRed(bitmap, 40, 40))
        @Assert(!m4OpaqueRed(bitmap, 2, 2))
        @Assert(!m4OpaqueRed(bitmap, 77, 77))
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
