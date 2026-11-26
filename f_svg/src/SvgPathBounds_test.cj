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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

internal func pathBounds(d: String): ?SvgBounds {
    let path = SvgPath(d: SvgPathData.parse(d))
    let style = styleOf(computeTree(path), path)
    SvgGeometry.bounds(path, style: style)
}

/** 固定字形：advance = fontSize，字形盒为 (0, -fontSize, fontSize, fontSize)。 */
internal class FixedSvgFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        let d = "M0 0 L${fontSize} 0 L${fontSize} -${fontSize} L0 -${fontSize} Z"
        SvgPathData.tryParse(d)
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        fontSize
    }

    public func ascent(fontSize: Float64): Float64 {
        fontSize
    }

    public func descent(fontSize: Float64): Float64 {
        0.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        Some(SvgBounds(0.0, -fontSize, fontSize, fontSize))
    }
}

@Test
public class SvgPathBounds_test {
    /** M/L/H/V/Z 端点与多子路径。 */
    @TestCase
    public func lineAndSubpaths(): Unit {
        @Assert(boundsNear(pathBounds("M10 20 L30 40") ?? SvgBounds.empty(), SvgBounds(10.0, 20.0, 20.0, 20.0)))
        @Assert(boundsNear(pathBounds("M10 20 H30 V50 Z") ?? SvgBounds.empty(), SvgBounds(10.0, 20.0, 20.0, 30.0)))
        @Assert(
            boundsNear(
                pathBounds("M0 0 L10 10 M100 100 L110 90") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 110.0, 100.0)
            )
        )
        @Assert(boundsNear(pathBounds("m10 10 l5 5") ?? SvgBounds.empty(), SvgBounds(10.0, 10.0, 5.0, 5.0)))
        @Assert(boundsNear(pathBounds("M5 5") ?? SvgBounds.empty(), SvgBounds(5.0, 5.0, 0.0, 0.0)))
        @Assert(geometryBounds(SvgPath()).isNone())
    }

    /** 三次贝塞尔：控制点同侧、异侧、共线、端点极值。 */
    @TestCase
    public func cubicExtrema(): Unit {
        let sameSide = pathBounds("M0 0 C0 10 10 10 10 0") ?? SvgBounds.empty()
        @Assert(near(sameSide.x, 0.0) && near(sameSide.y, 0.0))
        @Assert(near(sameSide.width, 10.0) && near(sameSide.height, 7.5))

        let bothSides = pathBounds("M0 0 C10 10 -10 10 0 0") ?? SvgBounds.empty()
        @Assert(near(bothSides.x, -2.886751345948129))
        @Assert(near(bothSides.width, 5.773502691896258))
        @Assert(near(bothSides.y, 0.0) && near(bothSides.height, 7.5))

        @Assert(
            boundsNear(
                pathBounds("M0 0 C5 5 10 10 15 15") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 15.0, 15.0)
            )
        )
        @Assert(
            boundsNear(
                pathBounds("M0 0 C0 0 10 0 10 10") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 10.0, 10.0)
            )
        )
    }

    /** 二次贝塞尔与 T 的隐式控制点。 */
    @TestCase
    public func quadraticAndSmooth(): Unit {
        @Assert(
            boundsNear(
                pathBounds("M0 0 Q5 10 10 0") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 10.0, 5.0)
            )
        )
        let smooth = pathBounds("M0 0 Q5 10 10 0 T20 0") ?? SvgBounds.empty()
        @Assert(near(smooth.x, 0.0) && near(smooth.y, -5.0))
        @Assert(near(smooth.width, 20.0) && near(smooth.height, 10.0))
    }

    /** 弧：半圆、翻转标志、整圆、rx/ry=0、非等比。 */
    @TestCase
    public func arcBounds(): Unit {
        let upper = pathBounds("M0 0 A10 10 0 0 1 20 0") ?? SvgBounds.empty()
        @Assert(near(upper.x, 0.0) && near(upper.y, -10.0))
        @Assert(near(upper.width, 20.0) && near(upper.height, 10.0))

        let lower = pathBounds("M0 0 A10 10 0 0 0 20 0") ?? SvgBounds.empty()
        @Assert(near(lower.y, 0.0) && near(lower.height, 10.0))

        let circle = pathBounds("M-10 0 A10 10 0 1 1 10 0 A10 10 0 1 1 -10 0") ?? SvgBounds.empty()
        @Assert(near(circle.x, -10.0) && near(circle.y, -10.0))
        @Assert(near(circle.width, 20.0) && near(circle.height, 20.0))

        @Assert(
            boundsNear(
                pathBounds("M0 0 A0 10 0 0 1 10 10") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 10.0, 10.0)
            )
        )

        let flat = pathBounds("M0 0 A20 10 0 0 1 40 0") ?? SvgBounds.empty()
        @Assert(near(flat.x, 0.0) && near(flat.y, -10.0))
        @Assert(near(flat.width, 40.0) && near(flat.height, 10.0))

        let minorPath = SvgPathData.parse("M0 0 A20 20 0 0 1 20 0")
        let majorPath = SvgPathData.parse("M0 0 A20 20 0 1 1 20 0")
        let minor = pathDataBounds(minorPath) ?? SvgBounds.empty()
        let major = pathDataBounds(majorPath) ?? SvgBounds.empty()
        @Assert(!boundsNear(minor, major))
        @Assert(arcBoundsMatchFlattened(minorPath, minor))
        @Assert(arcBoundsMatchFlattened(majorPath, major))
    }

    /** 零长段、重复点与非有限参数。 */
    @TestCase
    public func degenerateSegments(): Unit {
        @Assert(boundsNear(pathBounds("M0 0 L0 0") ?? SvgBounds.empty(), SvgBounds(0.0, 0.0, 0.0, 0.0)))
        @Assert(
            boundsNear(
                pathBounds("M0 0 L0 0 L5 5 L5 5 L10 0") ?? SvgBounds.empty(),
                SvgBounds(0.0, 0.0, 10.0, 5.0)
            )
        )
        let nanData = SvgPathData([
            SvgPathCommand(SvgPathCommandKind.MoveTo, false, [1.0, 2.0]),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [Float64.NaN, 10.0]),
            SvgPathCommand(SvgPathCommandKind.LineTo, false, [5.0, 5.0])
        ])
        let nanBounds = pathDataBounds(nanData) ?? SvgBounds.empty()
        @Assert(boundsNear(nanBounds, SvgBounds(1.0, 2.0, 4.0, 3.0)))
    }

    /** 描边包围盒：无描边、普通外扩、miter 截断与 round。 */
    @TestCase
    public func strokeBounds(): Unit {
        let line = SvgPath(d: SvgPathData.parse("M0 0 L10 0"))
        let noStroke = SvgGeometry.strokeBounds(line, style: strokeStyle(line, "none", 10.0, "miter", 4.0))
        @Assert(boundsNear(noStroke ?? SvgBounds.empty(), SvgBounds(0.0, 0.0, 10.0, 0.0)))

        let normal = SvgGeometry.strokeBounds(line, style: strokeStyle(line, "red", 10.0, "miter", 4.0))
        @Assert(boundsNear(normal ?? SvgBounds.empty(), SvgBounds(-5.0, -5.0, 20.0, 10.0)))

        let sharp = SvgPath(d: SvgPathData.parse("M0 0 L10 0 L0.1 0.1"))
        let capped = SvgGeometry.strokeBounds(sharp, style: strokeStyle(sharp, "red", 2.0, "miter", 4.0))
        @Assert(near((capped ?? SvgBounds.empty()).x, -1.0))
        @Assert(near((capped ?? SvgBounds.empty()).height, 2.1))

        let extended = SvgGeometry.strokeBounds(sharp, style: strokeStyle(sharp, "red", 2.0, "miter", 1000.0))
        let extendedBox = extended ?? SvgBounds.empty()
        @Assert(extendedBox.x + extendedBox.width > 100.0)

        let round = SvgGeometry.strokeBounds(sharp, style: strokeStyle(sharp, "red", 2.0, "round", 1000.0))
        @Assert(near((round ?? SvgBounds.empty()).x, -1.0))
        @Assert(near((round ?? SvgBounds.empty()).height, 2.1))
    }

    /** 祖先变换累乘、无变换、嵌套组。 */
    @TestCase
    public func absoluteBounds(): Unit {
        let rect = SvgRect(x: SvgLength(10.0), y: SvgLength(20.0), width: SvgLength(5.0), height: SvgLength(5.0))
        let plain = SvgGeometry.absoluteBounds(rect, style: styleOf(computeTree(rect), rect))
        @Assert(boundsNear(plain ?? SvgBounds.empty(), SvgBounds(10.0, 20.0, 5.0, 5.0)))

        let root = SvgRoot()
        let outer = SvgContainer(SvgContainerKind.Group)
        outer.setAttr("transform", "translate(10 10)")
        let inner = SvgContainer(SvgContainerKind.Group)
        inner.setAttr("transform", "scale(2)")
        let leaf = SvgRect(width: SvgLength(5.0), height: SvgLength(5.0))
        inner.appendElement(leaf)
        outer.appendElement(inner)
        root.appendElement(outer)
        let tree = computeTree(root)
        let absolute = SvgGeometry.absoluteBounds(leaf, style: styleOf(tree, leaf))
        @Assert(boundsNear(absolute ?? SvgBounds.empty(), SvgBounds(10.0, 10.0, 10.0, 10.0)))

        let translated = SvgRect(width: SvgLength(5.0), height: SvgLength(5.0))
        translated.setAttr("transform", "translate(100 200)")
        let translatedBounds = SvgGeometry.absoluteBounds(
            translated,
            style: styleOf(computeTree(translated), translated)
        )
        @Assert(boundsNear(translatedBounds ?? SvgBounds.empty(), SvgBounds(100.0, 200.0, 5.0, 5.0)))
    }

    /** 文本 bbox：测试字体与无字体提供者。 */
    @TestCase
    public func textBounds(): Unit {
        let text = SvgText()
        text.appendText("AB")
        text.x = [SvgLength(10.0)]
        text.y = [SvgLength(20.0)]
        text.fontSize = SvgLength(10.0)
        text.fontFamily = "test"
        let style = styleOf(computeTree(text), text)
        @Assert(SvgGeometry.bounds(text, style: style).isNone())

        let registry = SvgFontRegistry()
        registry.register("test", FixedSvgFont())
        let withFont = SvgGeometry.bounds(text, style: style, fonts: Some(registry))
        @Assert(boundsNear(withFont ?? SvgBounds.empty(), SvgBounds(10.0, 10.0, 10.0, 10.0)))

        let emptyText = SvgText()
        emptyText.fontSize = SvgLength(10.0)
        emptyText.fontFamily = "test"
        let emptyStyle = styleOf(computeTree(emptyText), emptyText)
        @Assert(SvgGeometry.bounds(emptyText, style: emptyStyle, fonts: Some(registry)).isNone())
    }
}

internal func arcBoundsMatchFlattened(path: SvgPathData, box: SvgBounds): Bool {
    let contours = flattenPathData(path, SvgMatrix.identity, 0.001)
    if (contours.size == 0 || contours[0].size == 0) {
        return false
    }
    var minX = contours[0][0].x
    var maxX = minX
    var minY = contours[0][0].y
    var maxY = minY
    for (contour in contours) {
        for (point in contour) {
            if (point.x < minX) { minX = point.x }
            if (point.x > maxX) { maxX = point.x }
            if (point.y < minY) { minY = point.y }
            if (point.y > maxY) { maxY = point.y }
        }
    }
    let tolerance = 0.05
    abs(box.x - minX) <= tolerance && abs(box.y - minY) <= tolerance &&
    abs(box.width - (maxX - minX)) <= tolerance && abs(box.height - (maxY - minY)) <= tolerance
}

internal func strokeStyle(
    element: SvgElement,
    stroke: String,
    width: Float64,
    join: String,
    miterLimit: Float64
): SvgComputedStyle {
    let css = element.tag + " { stroke: " + stroke + "; stroke-width: " + formatSvgNumber(width) +
        "; stroke-linejoin: " + join + "; stroke-miterlimit: " + formatSvgNumber(miterLimit) + " }"
    styleOf(computeTree(element, css), element)
}
