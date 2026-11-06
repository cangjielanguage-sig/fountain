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
import std.unittest.*
import std.unittest.testmacro.*

internal func m5RenderSvg(svg: String): SvgBitmap {
    SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(SvgParser.parse(svg))
}

@Test
public class SvgDropShadowRenderM5_test {
    /** 默认投影：原图保持红色，右下方出现半透明阴影。 */
    @TestCase
    public func defaultShadow(): Unit {
        let bitmap = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\">" +
            "<defs><filter id=\"f\"><feDropShadow/></filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(20, 20), 255, 0, 0))
        let shadow = bitmap.pixel(31, 20)
        @Assert(shadow.alpha > 0.0)
        @Assert(shadow.red < 128)
    }

    /** dx/dy 与零模糊产生硬边平移副本。 */
    @TestCase
    public func hardEdgeOffset(): Unit {
        let bitmap = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"60\">" +
            "<defs><filter id=\"f\"><feDropShadow dx=\"10\" dy=\"0\" stdDeviation=\"0\"/></filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(19, 15), 255, 0, 0))
        let shadow = bitmap.pixel(35, 15)
        @Assert(shadow.alpha > 0.9)
        @Assert(shadow.red < 20)
        @Assert(bitmap.pixel(41, 15).alpha == 0.0)
    }

    /** flood-color / flood-opacity 控制阴影颜色与透明度。 */
    @TestCase
    public func floodParameters(): Unit {
        let bitmap = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"60\">" +
            "<defs><filter id=\"f\"><feDropShadow dx=\"10\" dy=\"0\" stdDeviation=\"0\" " +
            "flood-color=\"blue\" flood-opacity=\"0.5\"/></filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let shadow = bitmap.pixel(35, 15)
        @Assert(m5ColorNear(shadow, 0, 0, 255))
        let alpha = shadow.alpha
        @Assert(alpha > 0.45 && alpha < 0.55)
        @Assert(m5ColorNear(bitmap.pixel(15, 15), 255, 0, 0))
    }

    /** 非法参数回退缺省值并告警，渲染继续。 */
    @TestCase
    public func invalidParameters(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\">" +
            "<defs><filter id=\"f\"><feDropShadow stdDeviation=\"-1\" flood-color=\"not-a-color\"/>" +
            "</filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(m5ColorNear(bitmap.pixel(20, 20), 255, 0, 0))
        var sawDeviation = false
        for (warning in renderer.warnings) {
            if (warning.contains("stdDeviation")) {
                sawDeviation = true
            }
        }
        @Assert(sawDeviation)
    }

    /** 与手写 blur + offset + flood + composite + merge 链逐字节一致。 */
    @TestCase
    public func equalsManualChain(): Unit {
        let shorthand = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"70\" height=\"70\">" +
            "<defs><filter id=\"f\"><feDropShadow dx=\"4\" dy=\"5\" stdDeviation=\"2\" " +
            "flood-color=\"blue\" flood-opacity=\"0.6\"/></filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"25\" height=\"25\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let manual = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"70\" height=\"70\">" +
            "<defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"70\" height=\"70\">" +
            "<feGaussianBlur stdDeviation=\"2\"/>" +
            "<feOffset dx=\"4\" dy=\"5\" result=\"o\"/>" +
            "<feFlood flood-color=\"blue\" flood-opacity=\"0.6\"/>" +
            "<feComposite in2=\"o\" operator=\"in\" result=\"s\"/>" +
            "<feMerge><feMergeNode in=\"s\"/><feMergeNode in=\"SourceGraphic\"/></feMerge>" +
            "</filter></defs>" +
            "<rect x=\"10\" y=\"10\" width=\"25\" height=\"25\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        @Assert(shorthand.pixels == manual.pixels)
    }

    /** 同一输入连续渲染逐字节一致。 */
    @TestCase
    public func deterministic(): Unit {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"50\">" +
            "<defs><filter id=\"f\"><feDropShadow/></filter></defs>" +
            "<circle cx=\"20\" cy=\"20\" r=\"10\" fill=\"green\" filter=\"url(#f)\"/></svg>"
        @Assert(m5RenderSvg(svg).pixels == m5RenderSvg(svg).pixels)
    }

    /** filterUnits 生效：userSpaceOnUse 的小区域只覆盖指定范围。 */
    @TestCase
    public func filterUnitsApplied(): Unit {
        let bitmap = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"80\">" +
            "<defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"30\" height=\"30\">" +
            "<feDropShadow dx=\"5\" dy=\"5\" stdDeviation=\"0\"/></filter></defs>" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        @Assert(m5ColorNear(bitmap.pixel(5, 5), 255, 0, 0))
        @Assert(bitmap.pixel(60, 60).alpha == 0.0)
    }
}
