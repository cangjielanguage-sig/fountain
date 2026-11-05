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

private func elementFilterDoc(body: String): SvgDocument {
    SvgParser.parse(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"40\">" +
        "<defs>" +
        "<filter id=\"shift\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" " +
        "width=\"60\" height=\"40\"><feOffset dx=\"5\" dy=\"0\"/></filter>" +
        "<filter id=\"shift3\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" " +
        "width=\"60\" height=\"40\"><feOffset dx=\"3\" dy=\"0\"/></filter>" +
        "<filter id=\"blur\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" " +
        "width=\"60\" height=\"40\"><feGaussianBlur stdDeviation=\"1.5\"/></filter>" +
        "</defs>" + body + "</svg>"
    )
}

private func renderSvg(body: String): SvgBitmap {
    SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(elementFilterDoc(body))
}

@Test
public class SvgElementFilterM3_test {
    /** 组 filter 与把同一 filter 写在子元素上输出一致。 */
    @TestCase
    public func groupFilterApplies(): Unit {
        let grouped = renderSvg(
            "<g filter=\"url(#shift)\"><rect x=\"10\" y=\"10\" width=\"10\" height=\"10\" " +
            "fill=\"red\"/></g>"
        )
        let element = renderSvg(
            "<rect x=\"10\" y=\"10\" width=\"10\" height=\"10\" fill=\"red\" " +
            "filter=\"url(#shift)\"/>"
        )
        @Assert(grouped.pixels == element.pixels)
        @Assert(colorNear(grouped.pixel(20, 15), SvgColor.fromRgb(255, 0, 0)))
        @Assert(grouped.pixel(12, 15).alpha == 0.0)
    }

    /** 填充 + 描边作为一个图层只滤镜一次。 */
    @TestCase
    public func fillAndStrokeFilteredOnce(): Unit {
        let body =
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" " +
            "stroke=\"blue\" stroke-width=\"6\" filter=\"url(#blur)\"/>"
        let actual = renderSvg(body)
        let plainDocument = elementFilterDoc(
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" " +
            "stroke=\"blue\" stroke-width=\"6\"/>"
        )
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(plainDocument)
        let filter = (findSvgElementById(Some(plainDocument.root), "blur").getOrThrow() as SvgFilter)
            .getOrThrow()
        let expected = SvgFilterRenderer().apply(
            filter,
            plain,
            SvgBounds(10.0, 10.0, 20.0, 20.0),
            SvgMatrix.identity,
            SvgRenderOptions(samplesPerPixel: 1)
        )
        @Assert(actual.pixels == expected.pixels)
    }

    /** marker 内容进入元素滤镜输入。 */
    @TestCase
    public func markerParticipatesInFilter(): Unit {
        let bitmap = renderSvg(
            "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\">" +
            "<rect width=\"6\" height=\"6\" fill=\"red\"/></marker></defs>" +
            "<path d=\"M 10 10 L 30 10\" stroke=\"black\" marker-end=\"url(#m)\" " +
            "filter=\"url(#shift)\"/>"
        )
        @Assert(colorNear(bitmap.pixel(38, 10), SvgColor.fromRgb(255, 0, 0)))
        @Assert(bitmap.pixel(31, 10).alpha == 0.0)
    }

    /** 组 filter 与子元素 filter 各自独立叠加。 */
    @TestCase
    public func groupAndChildFiltersStack(): Unit {
        let bitmap = renderSvg(
            "<g filter=\"url(#shift)\"><rect x=\"10\" y=\"10\" width=\"10\" height=\"10\" " +
            "fill=\"red\" filter=\"url(#shift3)\"/></g>"
        )
        @Assert(colorNear(bitmap.pixel(23, 15), SvgColor.fromRgb(255, 0, 0)))
        @Assert(bitmap.pixel(14, 15).alpha == 0.0)
    }
}
