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
public class SvgContextPaintM5_test {
    /** 两个字面量可解析并往返。 */
    @TestCase
    public func parseAndRoundTrip(): Unit {
        let fill = SvgPaint.parse("context-fill")
        @Assert(fill.kind == SvgPaintKind.ContextFill)
        @Assert(fill.toString() == "context-fill")
        let stroke = SvgPaint.parse("context-stroke")
        @Assert(stroke.kind == SvgPaintKind.ContextStroke)
        @Assert(stroke.toString() == "context-stroke")
        @Assert(SvgPaint.parse(" CONTEXT-FILL ").kind == SvgPaintKind.ContextFill)
    }

    /** 新取值不改变既有取值语义。 */
    @TestCase
    public func existingKindsUnchanged(): Unit {
        @Assert(SvgPaint.parse("none").kind == SvgPaintKind.None)
        @Assert(SvgPaint.parse("currentColor").kind == SvgPaintKind.CurrentColor)
        @Assert(SvgPaint.parse("red").kind == SvgPaintKind.Color)
        @Assert(SvgPaint.parse("url(#a)").kind == SvgPaintKind.Reference)
        @Assert(SvgPaint.parse("context-fill") != SvgPaint.None)
        @Assert(SvgPaint.parse("context-fill") != SvgPaint.parse("context-stroke"))
    }

    /** 计算样式保留 context-* 原值，便于 use 展开后解析。 */
    @TestCase
    public func computedStyleKeepsContextPaint(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " +
            "fill=\"context-fill\" stroke=\"context-stroke\"/></svg>"
        )
        let style = m5StyleOf(tree, document.elementById("r"))
        @Assert(style.fill().kind == SvgPaintKind.ContextFill)
        @Assert(style.stroke().kind == SvgPaintKind.ContextStroke)
    }
}
