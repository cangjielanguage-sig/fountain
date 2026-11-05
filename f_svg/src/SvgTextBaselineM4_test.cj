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

private class M4ZeroMetricFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        SvgPathData([
            SvgPathCommand(SvgPathCommandKind.MoveTo, false, [0.0, 0.0]),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [fontSize * 0.5, 0.0]),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [fontSize * 0.5, -fontSize * 0.7]),
            SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
        ])
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        fontSize * 0.5
    }

    public func ascent(fontSize: Float64): Float64 {
        0.0
    }

    public func descent(fontSize: Float64): Float64 {
        0.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Some(SvgBounds(0.0, -fontSize * 0.7, fontSize * 0.5, fontSize * 0.7))
    }
}

private func m4BaselineY(name: String, size!: Float64 = 10.0): Float64 {
    let text = makeText("A", size: size)
    text.setAttr("dominant-baseline", name)
    let layout = SvgTextRenderer().layout(text, style: textStyleOf(text))
    layout.glyphs[0].y
}

@Test
public class SvgTextBaselineM4_test {
    /** 基线表的偏移值。 */
    @TestCase
    public func offsetTable(): Unit {
        let ascent = 8.0
        let descent = 2.0
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Alphabetic, ascent, descent, 10.0), 0.0))
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Auto, ascent, descent, 10.0), 0.0))
        @Assert(near(
            SvgTextBaseline.offset(SvgDominantBaseline.TextBeforeEdge, ascent, descent, 10.0), -8.0))
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Hanging, ascent, descent, 10.0), -6.4))
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Middle, ascent, descent, 10.0), -3.0))
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Central, ascent, descent, 10.0), -3.0))
        @Assert(near(
            SvgTextBaseline.offset(SvgDominantBaseline.Mathematical, ascent, descent, 10.0), -4.0))
        @Assert(near(
            SvgTextBaseline.offset(SvgDominantBaseline.Ideographic, ascent, descent, 10.0), 2.0))
        @Assert(near(
            SvgTextBaseline.offset(SvgDominantBaseline.TextAfterEdge, ascent, descent, 10.0), 2.0))
        @Assert(near(SvgTextBaseline.offset(SvgDominantBaseline.Middle, 0.0, 0.0, 10.0), 0.0))
    }

    /** 五种基线的字形 y 依次递增。 */
    @TestCase
    public func renderedOrder(): Unit {
        let before = m4BaselineY("text-before-edge")
        let hanging = m4BaselineY("hanging")
        let middle = m4BaselineY("middle")
        let alphabetic = m4BaselineY("alphabetic")
        let after = m4BaselineY("text-after-edge")
        @Assert(near(before, -8.0))
        @Assert(near(hanging, -6.4))
        @Assert(near(middle, -3.0))
        @Assert(near(alphabetic, 0.0))
        @Assert(near(after, 2.0))
        @Assert(before < hanging && hanging < middle && middle < alphabetic && alphabetic < after)

        let unfset = makeText("A")
        @Assert(near(
            SvgTextRenderer().layout(unfset, style: textStyleOf(unfset)).glyphs[0].y,
            0.0
        ))
    }

    /** 无字体度量时按 0 回退。 */
    @TestCase
    public func zeroMetrics(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Zero", M4ZeroMetricFont())
        let text = makeText("A")
        text.fontFamily = "Zero"
        text.setAttr("dominant-baseline", "middle")
        let layout = SvgTextRenderer(registry: registry).layout(text, style: textStyleOf(text))
        @Assert(near(layout.glyphs[0].y, 0.0))
        @Assert(layout.glyphs.size == 1)
    }

    /** baseline-shift：sub / super / 长度 / 百分比。 */
    @TestCase
    public func baselineShift(): Unit {
        let sub = makeText("A")
        sub.setAttr("baseline-shift", "sub")
        @Assert(near(SvgTextRenderer().layout(sub, style: textStyleOf(sub)).glyphs[0].y, 2.0))

        let superText = makeText("A")
        superText.setAttr("baseline-shift", "super")
        @Assert(near(SvgTextRenderer().layout(superText, style: textStyleOf(superText)).glyphs[0].y, -4.0))

        let length = makeText("A", size: 20.0)
        length.setAttr("baseline-shift", "10%")
        let noParent: ?SvgComputedStyle = None
        let style = SvgStyleResolver().computeElement(length, noParent)
        @Assert(near(SvgTextRenderer().layout(length, style: style).glyphs[0].y, -2.0))

        let absolute = makeText("A")
        absolute.setAttr("baseline-shift", "3px")
        @Assert(near(SvgTextRenderer().layout(absolute, style: textStyleOf(absolute)).glyphs[0].y, -3.0))
    }

    /** alignment-baseline：tspan 相对父基线偏移，auto / baseline 不偏移。 */
    @TestCase
    public func alignmentBaseline(): Unit {
        let text = makeText("A")
        text.setAttr("y", "100")
        let span = SvgTspan()
        span.appendText("B")
        span.setAttr("alignment-baseline", "middle")
        text.appendElement(span)
        let layout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 2)
        @Assert(near(layout.glyphs[0].y, 100.0))
        @Assert(near(layout.glyphs[1].y, 97.0))

        span.setAttr("alignment-baseline", "baseline")
        let baselineLayout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(near(baselineLayout.glyphs[1].y, 100.0))

        span.setAttr("alignment-baseline", "auto")
        let autoLayout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(near(autoLayout.glyphs[1].y, 100.0))
    }

    /** 嵌套 tspan：alignment 相对直接父基线。 */
    @TestCase
    public func nestedAlignment(): Unit {
        let text = makeText("A")
        let outer = SvgTspan()
        outer.setAttr("dominant-baseline", "text-before-edge")
        outer.appendText("B")
        let inner = SvgTspan()
        inner.appendText("C")
        inner.setAttr("alignment-baseline", "middle")
        outer.appendElement(inner)
        text.appendElement(outer)
        let layout = SvgTextRenderer().layout(text, style: textStyleOf(text))
        @Assert(layout.glyphs.size == 3)
        @Assert(near(layout.glyphs[1].y, -8.0))
        @Assert(near(layout.glyphs[2].y, -3.0))
    }
}

