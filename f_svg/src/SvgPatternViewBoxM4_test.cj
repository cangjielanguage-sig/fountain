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

private func m4PatternRed(bitmap: SvgBitmap, x: Int64, y: Int64): Bool {
    let color = bitmap.pixel(x, y)
    color.alpha > 0.5 && color.red > 200
}

@Test
public class SvgPatternViewBoxM4_test {
    /** 字段默认值与往返。 */
    @TestCase
    public func model(): Unit {
        let pattern = SvgPattern()
        @Assert(pattern.viewBox.isNone())
        @Assert(pattern.preserveAspectRatio == SvgPreserveAspectRatio.Default)
        pattern.viewBox = tryParseSvgViewBox("0 0 10 20").getOrThrow()
        pattern.preserveAspectRatio = tryParseSvgPreserveAspectRatio("xMinYMax slice").getOrThrow()
        @Assert(pattern.viewBox.isSome())
        @Assert(pattern.viewBox.getOrThrow().width == 10.0)
        @Assert(pattern.preserveAspectRatio.slice)

        let document = SvgParser.parse(
            "<svg><pattern id=\"p\" viewBox=\"0 0 10 20\" " +
            "preserveAspectRatio=\"xMinYMax slice\"/></svg>"
        )
        let parsed = (document.root.child("pattern").getOrThrow() as SvgPattern).getOrThrow()
        @Assert(parsed.viewBox.getOrThrow().height == 20.0)
        @Assert(parsed.preserveAspectRatio.slice)
        let reparsed = SvgParser.parse(document.toString())
        let again = (reparsed.root.child("pattern").getOrThrow() as SvgPattern).getOrThrow()
        @Assert(again.viewBox == parsed.viewBox)
        @Assert(again.preserveAspectRatio == parsed.preserveAspectRatio)
    }

    /** viewBox 把 10×10 内容放大 2 倍填满 20×20 tile。 */
    @TestCase
    public func viewBoxScaling(): Unit {
        let document = svgDoc(
            '<pattern id="p" width="20" height="20" patternUnits="userSpaceOnUse" ' +
            'viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></pattern>' +
            '<rect width="40" height="40" fill="url(#p)"/>',
            width: 40,
            height: 40
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4PatternRed(bitmap, 5, 5))
        @Assert(m4PatternRed(bitmap, 15, 5))
        @Assert(m4PatternRed(bitmap, 25, 25))
        @Assert(m4PatternRed(bitmap, 35, 35))
    }

    /** viewBox 存在时忽略 patternContentUnits。 */
    @TestCase
    public func viewBoxIgnoresContentUnits(): Unit {
        let document = svgDoc(
            '<pattern id="p" width="20" height="20" patternUnits="userSpaceOnUse" ' +
            'patternContentUnits="objectBoundingBox" viewBox="0 0 10 10">' +
            '<rect width="10" height="10" fill="red"/></pattern>' +
            '<rect width="20" height="20" fill="url(#p)"/>',
            width: 20,
            height: 20
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4PatternRed(bitmap, 15, 15))
    }

    /** slice 填满 tile，meet 留白。 */
    @TestCase
    public func sliceAndMeet(): Unit {
        let meet = svgDoc(
            '<pattern id="p" width="10" height="10" patternUnits="userSpaceOnUse" ' +
            'viewBox="0 0 10 5"><rect width="10" height="5" fill="red"/></pattern>' +
            '<rect width="10" height="10" fill="url(#p)"/>',
            width: 10,
            height: 10
        )
        let meetBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(meet)
        @Assert(!m4PatternRed(meetBitmap, 5, 0))
        @Assert(m4PatternRed(meetBitmap, 5, 5))

        let slice = svgDoc(
            '<pattern id="p" width="10" height="10" patternUnits="userSpaceOnUse" ' +
            'viewBox="0 0 10 5" preserveAspectRatio="xMidYMid slice">' +
            '<rect width="10" height="5" fill="red"/></pattern>' +
            '<rect width="10" height="10" fill="url(#p)"/>',
            width: 10,
            height: 10
        )
        let sliceBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(slice)
        @Assert(m4PatternRed(sliceBitmap, 5, 0))
        @Assert(m4PatternRed(sliceBitmap, 5, 5))
    }

    /** 无 viewBox 时保持 M3 的 tile 内容坐标行为。 */
    @TestCase
    public func noViewBoxUnchanged(): Unit {
        let document = svgDoc(
            '<pattern id="p" width="10" height="10" patternUnits="userSpaceOnUse">' +
            '<rect width="5" height="5" fill="red"/></pattern>' +
            '<rect width="20" height="10" fill="url(#p)"/>',
            width: 20,
            height: 10
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m4PatternRed(bitmap, 2, 2))
        @Assert(!m4PatternRed(bitmap, 7, 2))
        @Assert(m4PatternRed(bitmap, 12, 2))
    }

    /** viewBox + patternTransform 合成。 */
    @TestCase
    public func patternTransformComposition(): Unit {
        let document = svgDoc(
            '<pattern id="p" width="10" height="10" patternUnits="userSpaceOnUse" ' +
            'viewBox="0 0 5 5" patternTransform="translate(5,0)">' +
            '<rect width="5" height="5" fill="red"/></pattern>' +
            '<rect width="20" height="10" fill="url(#p)"/>',
            width: 20,
            height: 10
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(m4PatternRed(first, 7, 2))
    }
}
