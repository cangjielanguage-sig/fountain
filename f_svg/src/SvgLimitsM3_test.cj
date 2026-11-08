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

@Test
public class SvgLimitsM3_test {
    /** pattern 引用链深度超过 64 抛 Limit。 */
    @TestCase
    public func patternDepthLimit(): Unit {
        let defs = StringBuilder("<defs>")
        for (index in 0..70) {
            defs.append(
                "<pattern id=\"p${index}\" href=\"#p${index + 1}\" width=\"10\" height=\"10\" " +
                "patternUnits=\"userSpaceOnUse\"/>"
            )
        }
        defs.append(
            "<pattern id=\"p70\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\"/></pattern></defs>"
        )
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            defs.toString() + "</svg>"
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        let error = expectSvgException(
            {=>
                SvgPatternSampler(root: Some(document.root)).sample(
                    pattern,
                    SvgBounds(0.0, 0.0, 20.0, 20.0),
                    SvgMatrix.identity,
                    SvgRenderOptions()
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** marker 循环引用只 warning，不崩溃。 */
    @TestCase
    public func markerCycleWarns(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs>" +
            "<marker id=\"a\" href=\"#b\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
            "<marker id=\"b\" href=\"#a\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
            "</defs>" +
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" stroke=\"black\" marker-end=\"url(#a)\"/>" +
            "</svg>"
        )
        let line = (document.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let expander = SvgMarkerExpander(root: Some(document.root))
        let warningParent: ?SvgComputedStyle = None
        let style = SvgStyleResolver().computeElement(line, warningParent)
        expander.expand(line, style)
        var found = false
        for (warning in expander.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 多类失败同时出现时 warning 可审计，渲染不中断。 */
    @TestCase
    public func warningAudit(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><pattern id=\"empty\" width=\"0\" height=\"10\"/></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#empty)\"/>" +
            "<line x1=\"0\" y1=\"25\" x2=\"20\" y2=\"25\" stroke=\"black\" " +
            "marker-end=\"url(#none)\"/>" +
            "<image href=\"mem://x\" width=\"10\" height=\"10\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(bitmap.width == 40 && bitmap.height == 40)
        var hasPattern = false
        var hasMarker = false
        var hasImage = false
        for (warning in renderer.warnings) {
            if (warning.contains("pattern")) {
                hasPattern = true
            }
            if (warning.contains("marker")) {
                hasMarker = true
            }
            if (warning.contains("image")) {
                hasImage = true
            }
        }
        @Assert(renderer.warnings.size >= 3)
        @Assert(hasPattern)
        @Assert(hasMarker)
        @Assert(hasImage)
    }
}
