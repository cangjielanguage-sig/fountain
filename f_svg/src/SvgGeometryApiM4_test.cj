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

@Test
public class SvgPathMeasureM4_test {
    /** 直线 / 折线 / 圆 / 弧长度。 */
    @TestCase
    public func lengths(): Unit {
        @Assert(near(SvgPathData.parse("M0 0 L100 0").totalLength(), 100.0))
        @Assert(near(SvgPathData.parse("M0 0 L3 4 L3 14").totalLength(), 15.0))

        let circle = SvgPathData.parse(
            "M10 0 A10 10 0 1 0 -10 0 A10 10 0 1 0 10 0"
        )
        let circumference = circle.totalLength()
        @Assert(circumference > 62.7 && circumference < 62.95)

        let arc = SvgPathData.parse("M0 0 A10 10 0 0 1 10 10")
        @Assert(arc.totalLength() > 15.0 && arc.totalLength() < 16.0)
    }

    /** 中点取点与端点钳制。 */
    @TestCase
    public func pointAtLength(): Unit {
        let line = SvgPathData.parse("M0 0 L100 0")
        let middle = line.pointAtLength(50.0)
        @Assert(near(middle.x, 50.0))
        @Assert(near(middle.y, 0.0))
        let before = line.pointAtLength(-10.0)
        @Assert(near(before.x, 0.0))
        let after = line.pointAtLength(200.0)
        @Assert(near(after.x, 100.0))

        let polyline = SvgPathData.parse("M0 0 L3 4 L3 14")
        let corner = polyline.pointAtLength(5.0)
        @Assert(near(corner.x, 3.0))
        @Assert(near(corner.y, 4.0))
    }

    /** 只有 MoveTo 的零长度路径返回该起点。 */
    @TestCase
    public func pointAtMoveOnlyPath(): Unit {
        let path = SvgPathData.parse("M10 20")
        @Assert(near(path.totalLength(), 0.0))
        let start = path.pointAtLength(0.0)
        @Assert(near(start.x, 10.0) && near(start.y, 20.0))
        let beyond = path.pointAtLength(100.0)
        @Assert(near(beyond.x, 10.0) && near(beyond.y, 20.0))
    }

    /** 空路径与非正容差。 */
    @TestCase
    public func emptyAndTolerance(): Unit {
        let empty = SvgPathData.parse("")
        @Assert(near(empty.totalLength(), 0.0))
        let point = empty.pointAtLength(10.0)
        @Assert(near(point.x, 0.0) && near(point.y, 0.0))

        for (tolerance in [0.0, -1.0, Float64.NaN]) {
            let error = expectSvgException({=> empty.totalLength(tolerance: tolerance)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }

    /** 容差变小结果收敛。 */
    @TestCase
    public func convergence(): Unit {
        let circle = SvgPathData.parse(
            "M10 0 A10 10 0 1 0 -10 0 A10 10 0 1 0 10 0"
        )
        let coarse = circle.totalLength(tolerance: 0.5)
        let fine = circle.totalLength(tolerance: 0.01)
        let larger = if (coarse > fine) { coarse } else { fine }
        @Assert((if (coarse > fine) { coarse - fine } else { fine - coarse }) <= larger * 0.01)
    }
}

@Test
public class SvgGeometryApiM4_test {
    /** 同一路径的 pointAtLength 与 textPath 落点一致。 */
    @TestCase
    public func textPathConsistency(): Unit {
        let path = SvgPathData.parse("M0 0 C0 50 100 50 100 0")
        let placements = SvgTextPathLayout().place(
            [10.0],
            path,
            SvgLength(20.0),
            SvgTextAnchor.Start
        )
        @Assert(placements.size == 1)
        let expected = path.pointAtLength(20.0)
        @Assert(abs(placements[0].originX - expected.x) <= 0.01)
        @Assert(abs(placements[0].originY - expected.y) <= 0.01)
    }

    /** 嵌套 g 与嵌套 svg 的 CTM；无变换为 identity。 */
    @TestCase
    public func ctm(): Unit {
        let document = svgDoc(
            '<g transform="translate(10,0)"><g transform="scale(2)">' +
            '<rect width="1" height="1"/></g></g>'
        )
        let rect = document.elementsByTag("rect")[0]
        let matrix = SvgGeometry.ctm(rect)
        let origin = matrix.apply(SvgPoint(0.0, 0.0))
        @Assert(near(origin.x, 10.0) && near(origin.y, 0.0))
        let unit = matrix.apply(SvgPoint(1.0, 1.0))
        @Assert(near(unit.x, 12.0) && near(unit.y, 2.0))

        let nested = svgDoc(
            '<svg x="10" y="20" width="20" height="20" viewBox="0 0 10 10">' +
            '<rect width="10" height="10"/></svg>',
            width: 100,
            height: 100
        )
        let innerRect = nested.elementsByTag("rect")[0]
        let innerMatrix = SvgGeometry.ctm(innerRect)
        let p0 = innerMatrix.apply(SvgPoint(0.0, 0.0))
        let p1 = innerMatrix.apply(SvgPoint(10.0, 10.0))
        @Assert(near(p0.x, 10.0) && near(p0.y, 20.0))
        @Assert(near(p1.x, 30.0) && near(p1.y, 40.0))

        let plain = svgDoc('<rect width="1" height="1"/>')
        @Assert(SvgGeometry.ctm(plain.elementsByTag("rect")[0]) == SvgMatrix.identity)

        let detached = SvgRect()
        @Assert(SvgGeometry.ctm(detached) == SvgMatrix.identity)
    }

    /** 带元素变换与 viewBox meet 时，screenCTM 与渲染矩阵一致。 */
    @TestCase
    public func screenCtmWithTransform(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" " +
            "viewBox=\"0 0 50 50\"><g transform=\"translate(10,10)\">" +
            "<rect width=\"10\" height=\"10\"/></g></svg>"
        )
        let rect = document.elementsByTag("rect")[0]
        let options = SvgRenderOptions(devicePixelRatio: 2.0)
        let viewport = SvgViewportTransform.from(document.root, options: options)
        let matrix = SvgGeometry.screenCTM(rect, viewport)
        let origin = matrix.apply(SvgPoint(0.0, 0.0))
        @Assert(near(origin.x, 40.0) && near(origin.y, 40.0))

        let list = SvgRenderTreeBuilder().build(document, options: options)
        var compared = false
        for (command in list.commands) {
            if (command.kind == SvgDisplayCommandKind.FillPath) {
                let rendered = command.matrix.apply(SvgPoint(0.0, 0.0))
                @Assert(near(rendered.x, origin.x) && near(rendered.y, origin.y))
                compared = true
            }
        }
        @Assert(compared)
    }

    /** screenCTM 叠加 viewBox 与 DPR，并与渲染矩阵一致。 */
    @TestCase
    public func screenCtm(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" " +
            "viewBox=\"0 0 50 50\"><rect width=\"10\" height=\"10\"/></svg>"
        )
        let rect = document.elementsByTag("rect")[0]
        let options = SvgRenderOptions(devicePixelRatio: 2.0)
        let viewport = SvgViewportTransform.from(document.root, options: options)
        let matrix = SvgGeometry.screenCTM(rect, viewport)
        let point = matrix.apply(SvgPoint(10.0, 10.0))
        @Assert(near(point.x, 40.0) && near(point.y, 40.0))

        let list = SvgRenderTreeBuilder().build(document, options: options)
        for (command in list.commands) {
            if (command.kind == SvgDisplayCommandKind.FillPath) {
                let rendered = command.matrix.apply(SvgPoint(10.0, 10.0))
                @Assert(near(rendered.x, point.x) && near(rendered.y, point.y))
            }
        }

        let noBox = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<rect width=\"1\" height=\"1\"/></svg>"
        )
        let plainViewport = SvgViewportTransform.from(
            noBox.root,
            options: SvgRenderOptions(devicePixelRatio: 1.0)
        )
        let plainRect = noBox.elementsByTag("rect")[0]
        @Assert(SvgGeometry.screenCTM(plainRect, plainViewport) == SvgGeometry.ctm(plainRect))
    }
}
