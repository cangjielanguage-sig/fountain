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
public class SvgShape_test {
    /** 填充与描边画笔。 */
    @TestCase
    public func paintProperties(): Unit {
        let rect = SvgRect()
        rect.fill = SvgPaint.of(SvgColor.fromRgb(255, 0, 0))
        @Assert(rect.attr("fill") == Some("#ff0000"))
        @Assert(rect.fill == Some(SvgPaint.of(SvgColor.fromRgb(255, 0, 0))))

        rect.fill = SvgPaint.None
        @Assert(rect.attr("fill") == Some("none"))
        @Assert(rect.fill == Some(SvgPaint.None))

        rect.stroke = SvgPaint.CurrentColor
        @Assert(rect.attr("stroke") == Some("currentColor"))
        @Assert(rect.stroke == Some(SvgPaint.CurrentColor))

        rect.stroke = SvgPaint.referencing("#g")
        @Assert(rect.attr("stroke") == Some("url(#g)"))
        @Assert(rect.stroke == Some(SvgPaint.referencing("#g")))

        rect.fill = None
        @Assert(rect.fill.isNone())
        @Assert(rect.attr("fill").isNone())
    }

    /** 数值型绘制属性。 */
    @TestCase
    public func numericProperties(): Unit {
        let rect = SvgRect()
        rect.fillOpacity = 0.5
        rect.strokeOpacity = 0.25
        rect.strokeMiterLimit = 4.0
        rect.opacity = 0.75
        @Assert(rect.attr("fill-opacity") == Some("0.5"))
        @Assert(rect.attr("stroke-opacity") == Some("0.25"))
        @Assert(rect.attr("stroke-miterlimit") == Some("4"))
        @Assert(rect.attr("opacity") == Some("0.75"))
        @Assert(rect.fillOpacity == Some(0.5))
        @Assert(rect.strokeOpacity == Some(0.25))
        @Assert(rect.strokeMiterLimit == Some(4.0))
        @Assert(rect.opacity == Some(0.75))
        rect.opacity = None
        @Assert(rect.opacity.isNone())
        @Assert(rect.attr("opacity").isNone())
    }

    /** 长度型绘制属性。 */
    @TestCase
    public func lengthProperties(): Unit {
        let rect = SvgRect()
        rect.strokeWidth = SvgLength(2.0, unit: SvgLengthUnit.Px)
        rect.strokeDashOffset = SvgLength(1.5)
        @Assert(rect.attr("stroke-width") == Some("2px"))
        @Assert(rect.attr("stroke-dashoffset") == Some("1.5"))
        @Assert(rect.strokeWidth == Some(SvgLength(2.0, unit: SvgLengthUnit.Px)))
        @Assert(rect.strokeDashOffset == Some(SvgLength(1.5)))
    }

    /** 枚举型绘制属性。 */
    @TestCase
    public func enumProperties(): Unit {
        let rect = SvgRect()
        rect.strokeLineCap = SvgLineCap.Round
        rect.strokeLineJoin = SvgLineJoin.Bevel
        rect.fillRule = SvgFillRule.Evenodd
        @Assert(rect.attr("stroke-linecap") == Some("round"))
        @Assert(rect.attr("stroke-linejoin") == Some("bevel"))
        @Assert(rect.attr("fill-rule") == Some("evenodd"))
        @Assert(rect.strokeLineCap == Some(SvgLineCap.Round))
        @Assert(rect.strokeLineJoin == Some(SvgLineJoin.Bevel))
        @Assert(rect.fillRule == Some(SvgFillRule.Evenodd))

        rect.setAttr("stroke-linecap", "square")
        @Assert(rect.strokeLineCap == Some(SvgLineCap.Square))
        rect.setAttr("fill-rule", "bogus")
        @Assert(rect.fillRule.isNone())
    }

    /** color 属性与 currentColor 基准。 */
    @TestCase
    public func colorProperty(): Unit {
        let rect = SvgRect()
        rect.color = SvgColor.parse("#0f0")
        @Assert(rect.attr("color") == Some("#00ff00"))
        @Assert(rect.color == Some(SvgColor.fromRgb(0, 255, 0)))
        rect.setAttr("color", "nope")
        @Assert(rect.color.isNone())
    }

    /** stroke-dasharray 的 none 与列表。 */
    @TestCase
    public func dashArray(): Unit {
        let rect = SvgRect()
        rect.strokeDashArray = [SvgLength(1.0), SvgLength(2.0, unit: SvgLengthUnit.Px)]
        @Assert(rect.attr("stroke-dasharray") == Some("1,2px"))
        @Assert(rect.strokeDashArray == Some([SvgLength(1.0), SvgLength(2.0, unit: SvgLengthUnit.Px)]))

        rect.setAttr("stroke-dasharray", "none")
        @Assert(rect.strokeDashArray.isNone())

        rect.setAttr("stroke-dasharray", "3 4.5")
        @Assert(rect.strokeDashArray == Some([SvgLength(3.0), SvgLength(4.5)]))

        rect.setAttr("stroke-dasharray", "1,bad")
        @Assert(rect.strokeDashArray.isNone())

        rect.strokeDashArray = None
        @Assert(rect.attr("stroke-dasharray").isNone())
    }

    /** 非法画笔读取返回 None。 */
    @TestCase
    public func invalidPaint(): Unit {
        let rect = SvgRect()
        rect.setAttr("fill", "notacolor")
        @Assert(rect.fill.isNone())
        rect.setAttr("stroke", "url(http://x/y.svg#a)")
        @Assert(rect.stroke.isNone())
    }

    /** 矩形几何属性。 */
    @TestCase
    public func rectangle(): Unit {
        let rect = SvgRect(
            x: SvgLength(1.0),
            y: SvgLength(2.0),
            width: SvgLength(80.0, unit: SvgLengthUnit.Px),
            height: SvgLength(40.0),
            rx: SvgLength(3.0),
            ry: SvgLength(4.0)
        )
        @Assert(rect.tag == "rect")
        @Assert(rect.attr("x") == Some("1"))
        @Assert(rect.attr("width") == Some("80px"))
        @Assert(rect.x == Some(SvgLength(1.0)))
        @Assert(rect.y == Some(SvgLength(2.0)))
        @Assert(rect.width == Some(SvgLength(80.0, unit: SvgLengthUnit.Px)))
        @Assert(rect.height == Some(SvgLength(40.0)))
        @Assert(rect.rx == Some(SvgLength(3.0)))
        @Assert(rect.ry == Some(SvgLength(4.0)))
        @Assert(rect.toString().contains("x=\"1\""))
    }

    /** 圆与椭圆。 */
    @TestCase
    public func circleAndEllipse(): Unit {
        let circle = SvgCircle(cx: SvgLength(10.0), cy: SvgLength(20.0), r: SvgLength(5.0))
        @Assert(circle.tag == "circle")
        @Assert(circle.cx == Some(SvgLength(10.0)))
        @Assert(circle.cy == Some(SvgLength(20.0)))
        @Assert(circle.r == Some(SvgLength(5.0)))

        let ellipse = SvgEllipse(cx: SvgLength(1.0), cy: SvgLength(2.0), rx: SvgLength(3.0), ry: SvgLength(4.0))
        @Assert(ellipse.tag == "ellipse")
        @Assert(ellipse.rx == Some(SvgLength(3.0)))
        @Assert(ellipse.ry == Some(SvgLength(4.0)))
    }

    /** 线段。 */
    @TestCase
    public func line(): Unit {
        let line = SvgLine(
            x1: SvgLength(1.0),
            y1: SvgLength(2.0),
            x2: SvgLength(3.0),
            y2: SvgLength(4.0)
        )
        @Assert(line.tag == "line")
        @Assert(line.x1 == Some(SvgLength(1.0)))
        @Assert(line.y1 == Some(SvgLength(2.0)))
        @Assert(line.x2 == Some(SvgLength(3.0)))
        @Assert(line.y2 == Some(SvgLength(4.0)))
    }

    /** 折线与多边形。 */
    @TestCase
    public func polylines(): Unit {
        let polyline = SvgPolyline()
        polyline.points = SvgPointList.parse("10,20 30,40")
        @Assert(polyline.tag == "polyline")
        @Assert(polyline.attr("points") == Some("10,20 30,40"))
        @Assert(polyline.points.getOrThrow().points.size == 2)
        @Assert(polyline.points.getOrThrow().points[1] == SvgPoint(30.0, 40.0))

        let polygon = SvgPolygon()
        polygon.points = SvgPointList.parse("1 2 3 4")
        @Assert(polygon.tag == "polygon")
        @Assert(polygon.points.getOrThrow().points.size == 2)
        polygon.setAttr("points", "1,2,3")
        @Assert(polygon.points.isNone())

        polyline.points = None
        @Assert(polyline.points.isNone())
    }

    /** 路径元素。 */
    @TestCase
    public func path(): Unit {
        let path = SvgPath()
        path.d = SvgPathData.parse("M0 0 L10 10 Z")
        @Assert(path.tag == "path")
        @Assert(path.attr("d") == Some("M 0 0 L 10 10 Z"))
        @Assert(path.d.getOrThrow().commands.size == 3)
        path.setAttr("d", "M1")
        @Assert(path.d.isNone())
        path.d = None
        @Assert(path.d.isNone())
    }

    /** 缺省几何属性保持 None。 */
    @TestCase
    public func missingGeometry(): Unit {
        let rect = SvgRect()
        @Assert(rect.x.isNone())
        @Assert(rect.y.isNone())
        @Assert(rect.width.isNone())
        @Assert(rect.height.isNone())
        rect.setAttr("width", "10")
        rect.setAttr("height", "10")
        @Assert(rect.width == Some(SvgLength(10.0)))
        @Assert(rect.x.isNone())
    }
}
