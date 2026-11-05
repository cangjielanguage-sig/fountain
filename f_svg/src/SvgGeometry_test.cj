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

internal func geometryBounds(element: SvgElement): ?SvgBounds {
    let style = styleOf(computeTree(element), element)
    SvgGeometry.bounds(element, style: style)
}

@Test
public class SvgGeometry_test {
    /** rect / circle / ellipse / line / polyline / polygon 的精确包围盒。 */
    @TestCase
    public func shapeBounds(): Unit {
        let rect = SvgRect(
            x: SvgLength(10.0),
            y: SvgLength(20.0),
            width: SvgLength(30.0),
            height: SvgLength(40.0)
        )
        @Assert(boundsNear(geometryBounds(rect) ?? SvgBounds.empty(), SvgBounds(10.0, 20.0, 30.0, 40.0)))

        let circle = SvgCircle(cx: SvgLength(50.0), cy: SvgLength(60.0), r: SvgLength(10.0))
        @Assert(boundsNear(geometryBounds(circle) ?? SvgBounds.empty(), SvgBounds(40.0, 50.0, 20.0, 20.0)))

        let ellipse = SvgEllipse(
            cx: SvgLength(5.0),
            cy: SvgLength(6.0),
            rx: SvgLength(4.0),
            ry: SvgLength(2.0)
        )
        @Assert(boundsNear(geometryBounds(ellipse) ?? SvgBounds.empty(), SvgBounds(1.0, 4.0, 8.0, 4.0)))

        let line = SvgLine(
            x1: SvgLength(1.0),
            y1: SvgLength(2.0),
            x2: SvgLength(-3.0),
            y2: SvgLength(8.0)
        )
        @Assert(boundsNear(geometryBounds(line) ?? SvgBounds.empty(), SvgBounds(-3.0, 2.0, 4.0, 6.0)))

        let polyline = SvgPolyline(
            points: SvgPointList([SvgPoint(0.0, 0.0), SvgPoint(10.0, 5.0), SvgPoint(20.0, -5.0)])
        )
        @Assert(boundsNear(geometryBounds(polyline) ?? SvgBounds.empty(), SvgBounds(0.0, -5.0, 20.0, 10.0)))

        let polygon = SvgPolygon(
            points: SvgPointList([SvgPoint(2.0, 3.0), SvgPoint(7.0, 3.0), SvgPoint(7.0, 9.0)])
        )
        @Assert(boundsNear(geometryBounds(polygon) ?? SvgBounds.empty(), SvgBounds(2.0, 3.0, 5.0, 6.0)))
    }

    /** 负尺寸、单点、空列表、缺失必需值。 */
    @TestCase
    public func invalidInputs(): Unit {
        let negativeRect = SvgRect(width: SvgLength(-10.0), height: SvgLength(5.0))
        @Assert(geometryBounds(negativeRect).isNone())
        let zeroRect = SvgRect(width: SvgLength(0.0), height: SvgLength(0.0))
        @Assert(!(geometryBounds(zeroRect) ?? SvgBounds.empty()).isEmpty())
        let missingRect = SvgRect()
        @Assert(geometryBounds(missingRect).isNone())

        let negativeCircle = SvgCircle(r: SvgLength(-1.0))
        @Assert(geometryBounds(negativeCircle).isNone())
        let missingCircle = SvgCircle()
        @Assert(geometryBounds(missingCircle).isNone())

        let negativeEllipse = SvgEllipse(rx: SvgLength(1.0), ry: SvgLength(-1.0))
        @Assert(geometryBounds(negativeEllipse).isNone())

        let singlePoint = SvgPolyline(points: SvgPointList([SvgPoint(5.0, 6.0)]))
        @Assert(boundsNear(geometryBounds(singlePoint) ?? SvgBounds.empty(), SvgBounds(5.0, 6.0, 0.0, 0.0)))

        let emptyPolygon = SvgPolygon(points: SvgPointList(Array<SvgPoint>()))
        @Assert(geometryBounds(emptyPolygon).isNone())

        let missingPoints = SvgPolyline()
        @Assert(geometryBounds(missingPoints).isNone())

        let container = SvgContainer(SvgContainerKind.Group)
        @Assert(geometryBounds(container).isNone())
    }

    /** 文本包围盒使用注册字体并遵循 tspan / 间距 / textLength 布局。 */
    @TestCase
    public func textBoundsFollowLayout(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Fixed", FixedBBoxFont())
        let text = SvgText()
        text.appendText("AB")
        text.fontFamily = "Fixed"
        text.fontSize = SvgLength(10.0)
        let simple = SvgGeometry.bounds(text, style: textStyleOf(text), fonts: Some(registry))
        @Assert(boundsNear(simple ?? SvgBounds.empty(), SvgBounds(0.0, -8.0, 20.0, 8.0)))

        text.letterSpacing = SvgLength(2.0)
        let spaced = SvgGeometry.bounds(text, style: textStyleOf(text), fonts: Some(registry))
        @Assert(near((spaced ?? SvgBounds.empty()).width, 22.0))

        let complex = SvgText()
        complex.fontFamily = "Fixed"
        complex.fontSize = SvgLength(10.0)
        complex.appendText("A")
        let span = SvgTspan()
        span.fontSize = SvgLength(20.0)
        span.dx = [SvgLength(3.0)]
        span.appendText("B")
        complex.appendElement(span)
        let complexStyle = textStyleOf(complex)
        let layout = SvgTextRenderer(registry: registry).layout(complex, style: complexStyle)
        let geometry = SvgGeometry.bounds(complex, style: complexStyle, fonts: Some(registry))
        @Assert(boundsNear(geometry ?? SvgBounds.empty(), layout.bounds ?? SvgBounds.empty()))
        @Assert((geometry ?? SvgBounds.empty()).width > 20.0)
    }

    /** 缺字时包盒为 None；渲染仍输出占位路径。 */
    @TestCase
    public func textBoundsRequireAllGlyphs(): Unit {
        let registry = SvgFontRegistry()
        registry.register("Single", SingleGlyphFont())
        let partial = SvgText()
        partial.appendText("AB")
        partial.fontFamily = "Single"
        partial.fontSize = SvgLength(10.0)
        @Assert(SvgGeometry.bounds(partial, style: textStyleOf(partial), fonts: Some(registry)).isNone())
        let layout = SvgTextRenderer(registry: registry).layout(partial, style: textStyleOf(partial))
        @Assert(layout.glyphs.size == 2)
        @Assert(layout.glyphs[1].path.isSome())

        let full = SvgText()
        full.appendText("AA")
        full.fontFamily = "Single"
        full.fontSize = SvgLength(10.0)
        @Assert(SvgGeometry.bounds(full, style: textStyleOf(full), fonts: Some(registry)).isSome())
    }
}

internal class SingleGlyphFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        if (codePoint != 65) {
            return None
        }
        let scale = fontSize / 10.0
        Some(
            SvgPathData([
                SvgPathCommand(SvgPathCommandKind.MoveTo, false, [0.0, -8.0 * scale]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [10.0 * scale, -8.0 * scale]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [10.0 * scale, 0.0]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [0.0, 0.0]),
                SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
            ])
        )
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        fontSize
    }

    public func ascent(fontSize: Float64): Float64 {
        fontSize * 0.8
    }

    public func descent(fontSize: Float64): Float64 {
        fontSize * 0.2
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        if (codePoint != 65) {
            return None
        }
        Some(SvgBounds(0.0, -fontSize * 0.8, fontSize, fontSize * 0.8))
    }
}

internal class FixedBBoxFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        if (codePoint == 32) {
            return Some(SvgPathData(Array<SvgPathCommand>()))
        }
        let scale = fontSize / 10.0
        Some(
            SvgPathData([
                SvgPathCommand(SvgPathCommandKind.MoveTo, false, [0.0, -8.0 * scale]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [10.0 * scale, -8.0 * scale]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [10.0 * scale, 0.0]),
                SvgPathCommand(SvgPathCommandKind.LineTo, false, [0.0, 0.0]),
                SvgPathCommand(SvgPathCommandKind.ClosePath, false, Array<Float64>())
            ])
        )
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        fontSize
    }

    public func ascent(fontSize: Float64): Float64 {
        fontSize * 0.8
    }

    public func descent(fontSize: Float64): Float64 {
        fontSize * 0.2
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        if (codePoint == 32) {
            return None
        }
        Some(SvgBounds(0.0, -fontSize * 0.8, fontSize, fontSize * 0.8))
    }
}
