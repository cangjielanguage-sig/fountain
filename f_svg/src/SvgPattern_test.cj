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

@Test
public class SvgPattern_test {
    /** pattern 保持容器语义，默认单位与尺寸。 */
    @TestCase
    public func typeAndDefaults(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><pattern id=\"p\" width=\"10\" height=\"10\"/></defs></svg>"
        )
        let element = document.root.child("defs").getOrThrow().child("pattern").getOrThrow()
        @Assert(element is SvgPattern)
        @Assert(element is SvgContainer)
        let pattern = (element as SvgPattern).getOrThrow()
        @Assert(pattern.kind == SvgContainerKind.Pattern)
        @Assert(pattern.tag == "pattern")
        @Assert(pattern.patternUnits == SvgCoordinateUnits.ObjectBoundingBox)
        @Assert(pattern.patternContentUnits == SvgCoordinateUnits.UserSpaceOnUse)
        @Assert(pattern.x.isNone())
        @Assert(pattern.y.isNone())
        @Assert(pattern.width == Some(SvgLength(10.0)))
        @Assert(pattern.height == Some(SvgLength(10.0)))
        @Assert(pattern.patternTransform.isNone())
        @Assert(pattern.href.isNone())
    }

    /** href 读写与 xlink 形式兼容。 */
    @TestCase
    public func hrefRoundTrip(): Unit {
        let pattern = SvgPattern()
        pattern.href = Some("#base")
        @Assert(pattern.href == Some("#base"))
        @Assert(pattern.attr(SvgNamespaces.XLINK, "href") == Some("#base"))

        pattern.href = None
        @Assert(pattern.href.isNone())
    }

    /** patternTransform 与内容单位可写回。 */
    @TestCase
    public func transformAndUnits(): Unit {
        let pattern = SvgPattern()
        pattern.patternUnits = SvgCoordinateUnits.UserSpaceOnUse
        pattern.patternContentUnits = SvgCoordinateUnits.ObjectBoundingBox
        pattern.patternTransform = SvgTransform.parse("rotate(45)")
        @Assert(pattern.patternUnits == SvgCoordinateUnits.UserSpaceOnUse)
        @Assert(pattern.patternContentUnits == SvgCoordinateUnits.ObjectBoundingBox)
        @Assert(pattern.patternTransform.getOrThrow().toString() == "rotate(45)")
    }
}
