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
}
