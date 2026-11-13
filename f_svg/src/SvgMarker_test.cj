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
public class SvgMarker_test {
    /** marker 保持容器语义，缺省属性生效。 */
    @TestCase
    public func typeAndDefaults(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><marker id=\"m\"><path d=\"M0 0L10 0\"/></marker></defs></svg>"
        )
        let element = document.root.child("defs").getOrThrow().child("marker").getOrThrow()
        @Assert(element is SvgMarker)
        @Assert(element is SvgContainer)
        let marker = (element as SvgMarker).getOrThrow()
        @Assert(marker.kind == SvgContainerKind.Marker)
        @Assert(marker.tag == "marker")
        @Assert(marker.markerUnits == SvgMarkerUnits.StrokeWidth)
        @Assert(marker.refX.isNone())
        @Assert(marker.refY.isNone())
        @Assert(marker.markerWidth.isNone())
        @Assert(marker.markerHeight.isNone())
        @Assert(marker.orient == SvgMarkerOrient.Angle(0.0))
        @Assert(marker.preserveAspectRatio == SvgPreserveAspectRatio.Default)
        @Assert(marker.viewBox.isNone())
    }

    /** 显式 0 与缺省可区分。 */
    @TestCase
    public func explicitZeroIsNotAbsent(): Unit {
        let marker = SvgMarker()
        marker.refX = Some(SvgLength(0.0))
        marker.markerWidth = Some(SvgLength(0.0))
        @Assert(marker.refX == Some(SvgLength(0.0)))
        @Assert(marker.markerWidth == Some(SvgLength(0.0)))
        marker.refX = None
        @Assert(marker.refX.isNone())
    }

    /** 属性读写往返。 */
    @TestCase
    public func propertiesRoundTrip(): Unit {
        let marker = SvgMarker()
        marker.markerUnits = SvgMarkerUnits.UserSpaceOnUse
        marker.orient = SvgMarkerOrient.Auto
        marker.refX = Some(SvgLength(5.0))
        marker.refY = Some(SvgLength(6.0))
        marker.markerWidth = Some(SvgLength(7.0))
        marker.markerHeight = Some(SvgLength(8.0))
        marker.viewBox = SvgViewBox(0.0, 0.0, 10.0, 10.0)
        marker.preserveAspectRatio = SvgPreserveAspectRatio(SvgAspectAlign.XMinYMin)

        @Assert(marker.markerUnits == SvgMarkerUnits.UserSpaceOnUse)
        @Assert(marker.orient == SvgMarkerOrient.Auto)
        @Assert(marker.refX == Some(SvgLength(5.0)))
        @Assert(marker.refY == Some(SvgLength(6.0)))
        @Assert(marker.markerWidth == Some(SvgLength(7.0)))
        @Assert(marker.markerHeight == Some(SvgLength(8.0)))
        @Assert(marker.viewBox == Some(SvgViewBox(0.0, 0.0, 10.0, 10.0)))
        @Assert(marker.preserveAspectRatio == SvgPreserveAspectRatio(SvgAspectAlign.XMinYMin))
    }

    /** 缺省 markerWidth / markerHeight 按 3×3 参与 viewBox 映射。 */
    @TestCase
    public func defaultSizeUsedByViewBox(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><marker id=\"m\" viewBox=\"0 0 6 6\">" +
            "<rect width=\"6\" height=\"6\" fill=\"red\"/></marker></defs>" +
            "<line x1=\"10\" y1=\"10\" x2=\"20\" y2=\"10\" marker-start=\"url(#m)\"/></svg>"
        )
        let line = (document.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let noParent: ?SvgComputedStyle = None
        let style = SvgStyleResolver().computeElement(line, noParent)
        let instance = SvgMarkerExpander(root: Some(document.root)).expand(line, style)[0]
        let corner = instance.matrix.apply(SvgPoint(6.0, 6.0))
        @Assert(near(corner.x, 13.0) && near(corner.y, 13.0))
    }

    /** orient 三种形式。 */
    @TestCase
    public func orientForms(): Unit {
        let document = SvgParser.parse(
            "<svg><defs>" +
            "<marker id=\"a\" orient=\"auto\"/>" +
            "<marker id=\"b\" orient=\"auto-start-reverse\"/>" +
            "<marker id=\"c\" orient=\"45\"/>" +
            "</defs></svg>"
        )
        let defs = document.root.child("defs").getOrThrow()
        @Assert((defs.child("marker").getOrThrow() as SvgMarker).getOrThrow().orient == SvgMarkerOrient.Auto)
        @Assert((defs.childrenOf("marker")[1] as SvgMarker).getOrThrow().orient == SvgMarkerOrient.AutoStartReverse)
        @Assert((defs.childrenOf("marker")[2] as SvgMarker).getOrThrow().orient == SvgMarkerOrient.Angle(45.0))
    }
}
