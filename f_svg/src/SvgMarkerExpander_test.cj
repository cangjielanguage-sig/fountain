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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

internal func markerStyleOf(shape: SvgElement): SvgComputedStyle {
    let noParent: ?SvgComputedStyle = None
    SvgStyleResolver().computeElement(shape, noParent)
}

private let MARKER_DEFS = "<defs>" +
    "<marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\" refX=\"0\" refY=\"0\">" +
    "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
    "<marker id=\"ref\" markerWidth=\"4\" markerHeight=\"4\" refX=\"5\" refY=\"5\">" +
    "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
    "<marker id=\"auto\" markerWidth=\"4\" markerHeight=\"4\" orient=\"auto\">" +
    "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
    "<marker id=\"reverse\" markerWidth=\"4\" markerHeight=\"4\" orient=\"auto-start-reverse\">" +
    "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
    "<marker id=\"fixed\" markerWidth=\"4\" markerHeight=\"4\" orient=\"45\">" +
    "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker>" +
    "<marker id=\"wide\" markerWidth=\"3\" markerHeight=\"3\" viewBox=\"0 0 6 6\">" +
    "<rect width=\"3\" height=\"3\" fill=\"red\"/></marker>" +
    "</defs>"

private func markerDocument(body: String): SvgDocument {
    SvgParser.parse(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\">" +
        MARKER_DEFS + body + "</svg>"
    )
}

@Test
public class SvgMarkerExpander_test {
    /** line / polyline / path 的 start / mid / end 派生。 */
    @TestCase
    public func vertexDerivation(): Unit {
        let lineDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-start=\"url(#m)\" " +
            "marker-end=\"url(#m)\"/>"
        )
        let line = (lineDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let lineInstances = SvgMarkerExpander(root: Some(lineDocument.root))
            .expand(line, markerStyleOf(line))
        @Assert(lineInstances.size == 2)
        let startPoint = lineInstances[0].matrix.apply(SvgPoint(0.0, 0.0))
        let endPoint = lineInstances[1].matrix.apply(SvgPoint(0.0, 0.0))
        @Assert(near(startPoint.x, 0.0) && near(startPoint.y, 0.0))
        @Assert(near(endPoint.x, 10.0) && near(endPoint.y, 0.0))

        let polylineDocument = markerDocument(
            "<polyline points=\"0,0 5,5 10,0\" fill=\"none\" stroke=\"black\" " +
            "marker-mid=\"url(#m)\"/>"
        )
        let polyline = (polylineDocument.root.child("polyline").getOrThrow() as SvgPolyline)
            .getOrThrow()
        let polylineInstances = SvgMarkerExpander(root: Some(polylineDocument.root))
            .expand(polyline, markerStyleOf(polyline))
        @Assert(polylineInstances.size == 1)
        let middle = polylineInstances[0].matrix.apply(SvgPoint(0.0, 0.0))
        @Assert(near(middle.x, 5.0) && near(middle.y, 5.0))

        let pathDocument = markerDocument(
            "<path d=\"M 0 0 L 10 0 L 20 0\" fill=\"none\" stroke=\"black\" " +
            "marker-start=\"url(#m)\" marker-mid=\"url(#m)\" marker-end=\"url(#m)\"/>"
        )
        let path = (pathDocument.root.child("path").getOrThrow() as SvgPath).getOrThrow()
        let pathInstances = SvgMarkerExpander(root: Some(pathDocument.root))
            .expand(path, markerStyleOf(path))
        @Assert(pathInstances.size == 3)
    }

    /** 闭合路径首末重合时 mid 不重复派生。 */
    @TestCase
    public func closedPathMid(): Unit {
        let document = markerDocument(
            "<polygon points=\"0,0 10,0 10,10 0,0\" fill=\"none\" stroke=\"black\" " +
            "marker-mid=\"url(#m)\"/>"
        )
        let polygon = (document.root.child("polygon").getOrThrow() as SvgPolygon).getOrThrow()
        let instances = SvgMarkerExpander(root: Some(document.root))
            .expand(polygon, markerStyleOf(polygon))
        @Assert(instances.size == 2)
    }

    /** refX / refY 对齐与 viewBox 映射。 */
    @TestCase
    public func alignmentAndViewBox(): Unit {
        let alignedDocument = markerDocument(
            "<line x1=\"10\" y1=\"0\" x2=\"30\" y2=\"0\" marker-start=\"url(#ref)\"/>"
        )
        let aligned = (alignedDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let instances = SvgMarkerExpander(root: Some(alignedDocument.root))
            .expand(aligned, markerStyleOf(aligned))
        @Assert(instances.size == 1)
        let reference = instances[0].matrix.apply(SvgPoint(5.0, 5.0))
        @Assert(near(reference.x, 10.0) && near(reference.y, 0.0))

        let viewBoxDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"30\" y2=\"0\" marker-start=\"url(#wide)\"/>"
        )
        let viewBoxLine = (viewBoxDocument.root.child("line").getOrThrow() as SvgLine)
            .getOrThrow()
        let viewBoxInstances = SvgMarkerExpander(root: Some(viewBoxDocument.root))
            .expand(viewBoxLine, markerStyleOf(viewBoxLine))
        let corner = viewBoxInstances[0].matrix.apply(SvgPoint(6.0, 6.0))
        @Assert(near(corner.x, 3.0) && near(corner.y, 3.0))
    }

    /** markerUnits=strokeWidth 的缩放。 */
    @TestCase
    public func strokeWidthScaling(): Unit {
        let document = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"30\" y2=\"0\" stroke-width=\"4\" " +
            "marker-start=\"url(#wide)\"/>"
        )
        let line = (document.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let instances = SvgMarkerExpander(root: Some(document.root))
            .expand(line, markerStyleOf(line))
        let scaled = instances[0].matrix.apply(SvgPoint(6.0, 6.0))
        @Assert(near(scaled.x, 12.0) && near(scaled.y, 12.0))
    }

    /** orient 三种形式。 */
    @TestCase
    public func orientations(): Unit {
        let autoDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-start=\"url(#auto)\"/>"
        )
        let autoLine = (autoDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let auto = SvgMarkerExpander(root: Some(autoDocument.root))
            .expand(autoLine, markerStyleOf(autoLine))[0]
        let autoDirection = auto.matrix.apply(SvgPoint(1.0, 0.0))
        @Assert(near(autoDirection.x, 1.0) && near(autoDirection.y, 0.0))

        let reverseDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-start=\"url(#reverse)\"/>"
        )
        let reverseLine = (reverseDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let reverse = SvgMarkerExpander(root: Some(reverseDocument.root))
            .expand(reverseLine, markerStyleOf(reverseLine))[0]
        let reverseDirection = reverse.matrix.apply(SvgPoint(1.0, 0.0))
        @Assert(near(reverseDirection.x, -1.0) && abs(reverseDirection.y) < 1e-9)

        let fixedDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-start=\"url(#fixed)\"/>"
        )
        let fixedLine = (fixedDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let fixed = SvgMarkerExpander(root: Some(fixedDocument.root))
            .expand(fixedLine, markerStyleOf(fixedLine))[0]
        let fixedDirection = fixed.matrix.apply(SvgPoint(1.0, 0.0))
        @Assert(abs(fixedDirection.x - 0.7071067811865476) < 1e-6)
        @Assert(abs(fixedDirection.y - 0.7071067811865476) < 1e-6)
    }

    /** 数量上限、缺失引用与引用深度。 */
    @TestCase
    public func markerLimits(): Unit {
        let points = StringBuilder()
        for (index in 0..2000) {
            if (index > 0) {
                points.append(" ")
            }
            points.append("${index},0")
        }
        let document = markerDocument(
            "<polyline points=\"${points}\" fill=\"none\" stroke=\"black\" marker-mid=\"url(#m)\"/>"
        )
        let polyline = (document.root.child("polyline").getOrThrow() as SvgPolyline).getOrThrow()
        let expander = SvgMarkerExpander(root: Some(document.root))
        let instances = expander.expand(polyline, markerStyleOf(polyline))
        @Assert(instances.size == 1024)
        @Assert(expander.warnings.size >= 1)

        let missingDocument = markerDocument(
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-end=\"url(#none)\"/>"
        )
        let missingLine = (missingDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let missingExpander = SvgMarkerExpander(root: Some(missingDocument.root))
        @Assert(missingExpander.expand(missingLine, markerStyleOf(missingLine)).size == 0)
        @Assert(missingExpander.warnings.size >= 1)

        let depth = StringBuilder("<defs>")
        for (index in 0..70) {
            depth.append("<marker id=\"d${index}\" href=\"#d${index + 1}\" " +
                "markerWidth=\"4\" markerHeight=\"4\"><rect width=\"4\" height=\"4\" " +
                "fill=\"red\"/></marker>")
        }
        depth.append("<marker id=\"d70\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\"/></marker></defs>")
        let depthDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            depth.toString() +
            "<line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\" marker-start=\"url(#d0)\"/></svg>"
        )
        let depthLine = (depthDocument.root.child("line").getOrThrow() as SvgLine).getOrThrow()
        let error = expectSvgException(
            {=>
                SvgMarkerExpander(root: Some(depthDocument.root))
                    .expand(depthLine, markerStyleOf(depthLine))
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}

@Test
public class SvgMarkerRender_test {
    /** marker 内容进入渲染树，按顶点绘制。 */
    @TestCase
    public func markerRendered(): Unit {
        let document = markerDocument(
            "<line x1=\"5\" y1=\"5\" x2=\"25\" y2=\"5\" stroke=\"black\" " +
            "marker-start=\"url(#m)\" marker-end=\"url(#m)\"/>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(bitmap.pixel(25, 5), SvgColor.fromRgb(255, 0, 0)))
    }
}


@Test
public class SvgMarkerClipM3_test {
    /** marker 内容引用 clipPath 时正常裁剪。 */
    @TestCase
    public func markerContentClipped(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><clipPath id=\"c\"><rect x=\"0\" y=\"0\" width=\"2\" height=\"4\"/></clipPath>" +
            "<marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\" clip-path=\"url(#c)\"/></marker></defs>" +
            "<line x1=\"10\" y1=\"10\" x2=\"25\" y2=\"10\" stroke=\"black\" " +
            "marker-start=\"url(#m)\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(colorNear(bitmap.pixel(10, 10), SvgColor.fromRgb(255, 0, 0)))
        @Assert(bitmap.pixel(13, 10).alpha == 0.0)
    }
}

@Test
public class SvgMarkerSubpathM3_test {
    /** path 的每个子路径都参与 marker 派生。 */
    @TestCase
    public func multipleSubpathsDeriveMarkers(): Unit {
        let document = markerDocument(
            "<path d=\"M 0 0 L 10 0 M 20 0 L 30 0\" fill=\"none\" stroke=\"black\" " +
            "marker-start=\"url(#m)\" marker-end=\"url(#m)\"/>"
        )
        let path = (document.root.child("path").getOrThrow() as SvgPath).getOrThrow()
        let instances = SvgMarkerExpander(root: Some(document.root))
            .expand(path, markerStyleOf(path))
        @Assert(instances.size == 4)
        let starts = ArrayList<Float64>()
        for (instance in instances) {
            starts.add(instance.matrix.apply(SvgPoint(0.0, 0.0)).x)
        }
        @Assert(starts.contains(0.0))
        @Assert(starts.contains(10.0))
        @Assert(starts.contains(20.0))
        @Assert(starts.contains(30.0))
    }
}

@Test
public class SvgMarkerEffectsM3_test {
    /** marker 内容的 filter 与 mask 正常生效。 */
    @TestCase
    public func markerContentMaskAndFilter(): Unit {
        let filtered = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" " +
            "width=\"8\" height=\"8\"><feOffset dx=\"2\" dy=\"0\"/></filter>" +
            "<marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\" filter=\"url(#f)\"/></marker></defs>" +
            "<line x1=\"10\" y1=\"10\" x2=\"25\" y2=\"10\" stroke=\"black\" marker-start=\"url(#m)\"/></svg>"
        )
        let filteredBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(filtered)
        @Assert(colorNear(filteredBitmap.pixel(15, 10), SvgColor.fromRgb(255, 0, 0)))

        let masked = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><mask id=\"m\"><rect x=\"0\" y=\"0\" width=\"2\" height=\"4\" fill=\"white\"/></mask>" +
            "<marker id=\"mk\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\" mask=\"url(#m)\"/></marker></defs>" +
            "<line x1=\"10\" y1=\"10\" x2=\"25\" y2=\"10\" stroke=\"black\" marker-start=\"url(#mk)\"/></svg>"
        )
        let maskedBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(masked)
        @Assert(colorNear(maskedBitmap.pixel(10, 10), SvgColor.fromRgb(255, 0, 0)))
        @Assert(maskedBitmap.pixel(13, 10).alpha == 0.0)
    }
}
