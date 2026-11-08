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

internal let M5_NO_BOUNDS: ?SvgBounds = None

internal func m5TransformedPoint(transform: SvgMatrix, x: Float64, y: Float64): SvgPoint {
    transform.apply(SvgPoint(x, y))
}

internal func m5PointNear(point: SvgPoint, x: Float64, y: Float64): Bool {
    abs(point.x - x) <= 0.001 && abs(point.y - y) <= 0.001
}

internal func m5StyleWithOrigin(origin: String, box!: String = "view-box"): SvgComputedStyle {
    let (document, tree, _) = m5ComputeStyles(
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" transform=\"rotate(90)\" " +
        "transform-origin=\"" + origin + "\" transform-box=\"" + box + "\"/></svg>"
    )
    m5StyleOf(tree, document.elementById("r"))
}

@Test
public class SvgTransformOriginM5_test {
    /** 绕 (50,50) 旋转 90°，矩形仍覆盖原区域。 */
    @TestCase
    public func rotateAroundPoint(): Unit {
        let rect = SvgRect()
        rect.setAttr("transform", "rotate(90)")
        rect.setAttr("transform-origin", "50 50")
        let style = m5StyleWithOrigin("50 50")
        let matrix = effectiveElementTransform(
            rect,
            style: Some(style),
            bounds: Some(SvgBounds(0.0, 0.0, 100.0, 100.0)),
            viewportWidth: 100.0,
            viewportHeight: 100.0
        )
        @Assert(m5PointNear(m5TransformedPoint(matrix, 50.0, 50.0), 50.0, 50.0))
        @Assert(m5PointNear(m5TransformedPoint(matrix, 0.0, 0.0), 100.0, 0.0))
        @Assert(m5PointNear(m5TransformedPoint(matrix, 100.0, 0.0), 100.0, 100.0))
    }

    /** fill-box 百分比相对元素包围盒。 */
    @TestCase
    public func fillBoxPercent(): Unit {
        let rect = SvgRect()
        rect.setAttr("transform", "rotate(90)")
        rect.setAttr("transform-origin", "50% 50%")
        rect.setAttr("transform-box", "fill-box")
        let style = m5StyleWithOrigin("50% 50%", box: "fill-box")
        let matrix = effectiveElementTransform(
            rect,
            style: Some(style),
            bounds: Some(SvgBounds(10.0, 20.0, 40.0, 20.0)),
            viewportWidth: 100.0,
            viewportHeight: 100.0
        )
        @Assert(m5PointNear(m5TransformedPoint(matrix, 30.0, 30.0), 30.0, 30.0))
    }

    /** view-box 百分比相对视口。 */
    @TestCase
    public func viewBoxPercent(): Unit {
        let rect = SvgRect()
        rect.setAttr("transform", "rotate(90)")
        rect.setAttr("transform-origin", "50% 50%")
        let style = m5StyleWithOrigin("50% 50%")
        let matrix = effectiveElementTransform(
            rect,
            style: Some(style),
            bounds: M5_NO_BOUNDS,
            viewportWidth: 100.0,
            viewportHeight: 200.0
        )
        @Assert(m5PointNear(m5TransformedPoint(matrix, 50.0, 100.0), 50.0, 100.0))
    }

    /** 缺省 0 0 + view-box 短路为原矩阵。 */
    @TestCase
    public func defaultShortCircuit(): Unit {
        let rect = SvgRect()
        rect.setAttr("transform", "rotate(90)")
        let style = m5StyleWithOrigin("0 0")
        let matrix = effectiveElementTransform(
            rect,
            style: Some(style),
            bounds: Some(SvgBounds(1.0, 2.0, 3.0, 4.0)),
            viewportWidth: 100.0,
            viewportHeight: 100.0
        )
        let plain = SvgTransform.parse("rotate(90)").toMatrix()
        @Assert(m5PointNear(m5TransformedPoint(matrix, 0.0, 0.0), 0.0, 0.0))
        @Assert(m5PointNear(m5TransformedPoint(matrix, 1.0, 0.0), plain.apply(SvgPoint(1.0, 0.0)).x, plain.apply(
            SvgPoint(1.0, 0.0)
        ).y))
    }

    /** 关键字 left/right/top/bottom 与单值补 center。 */
    @TestCase
    public func keywordOrigins(): Unit {
        let rect = SvgRect()
        rect.setAttr("transform", "translate(1,2)")
        let bottomRight = effectiveElementTransform(
            rect,
            style: Some(m5StyleWithOrigin("right bottom")),
            bounds: M5_NO_BOUNDS,
            viewportWidth: 100.0,
            viewportHeight: 50.0
        )
        // translate 与原点无关，结果仍是平移。
        @Assert(m5PointNear(m5TransformedPoint(bottomRight, 0.0, 0.0), 1.0, 2.0))
        let single = effectiveElementTransform(
            rect,
            style: Some(m5StyleWithOrigin("50%")),
            bounds: M5_NO_BOUNDS,
            viewportWidth: 100.0,
            viewportHeight: 50.0
        )
        @Assert(m5PointNear(m5TransformedPoint(single, 0.0, 0.0), 1.0, 2.0))
    }

    /** 无 transform 时原点不影响结果。 */
    @TestCase
    public func noTransformIgnoresOrigin(): Unit {
        let rect = SvgRect()
        let matrix = effectiveElementTransform(
            rect,
            style: Some(m5StyleWithOrigin("50 50")),
            bounds: M5_NO_BOUNDS,
            viewportWidth: 10.0,
            viewportHeight: 10.0
        )
        @Assert(m5PointNear(m5TransformedPoint(matrix, 3.0, 4.0), 3.0, 4.0))
    }
}
