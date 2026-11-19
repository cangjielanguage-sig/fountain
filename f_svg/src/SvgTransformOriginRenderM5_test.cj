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

/** 首个指定 tag / kind 的命令矩阵。 */
internal func m5CommandMatrix(list: SvgDisplayList, tag: String, kind: SvgDisplayCommandKind): SvgMatrix {
    for (command in list.commands) {
        if (command.tag == tag && command.kind == kind) {
            return command.matrix
        }
    }
    @Fail("显示列表缺少 ${tag}:${kind.toString()}")
}

@Test
public class SvgTransformOriginRenderM5_test {
    private static let ROTATE: String = "transform=\"rotate(90)\" transform-origin=\"40 40\""

    /** rect：绕 (40,40) 旋转。 */
    @TestCase
    public func rectOrigin(): Unit {
        let list = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<rect x=\"30\" y=\"30\" width=\"20\" height=\"20\" fill=\"red\" " + SvgTransformOriginRenderM5_test.ROTATE +
            "/></svg>"
        )
        let matrix = m5CommandMatrix(list, "rect", SvgDisplayCommandKind.FillPath)
        let moved = matrix.apply(SvgPoint(30.0, 30.0))
        @Assert(m5PointNear(moved, 50.0, 30.0))
        let center = matrix.apply(SvgPoint(40.0, 40.0))
        @Assert(m5PointNear(center, 40.0, 40.0))
    }

    /** g：组的原点作用于子元素。 */
    @TestCase
    public func groupOrigin(): Unit {
        let list = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<g " + SvgTransformOriginRenderM5_test.ROTATE + ">" +
            "<rect x=\"30\" y=\"30\" width=\"20\" height=\"20\" fill=\"red\"/></g></svg>"
        )
        let matrix = m5CommandMatrix(list, "rect", SvgDisplayCommandKind.FillPath)
        @Assert(m5PointNear(matrix.apply(SvgPoint(30.0, 30.0)), 50.0, 30.0))
    }

    /** text：文本命令矩阵使用同一原点。 */
    @TestCase
    public func textOrigin(): Unit {
        let list = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<text x=\"30\" y=\"30\" " + SvgTransformOriginRenderM5_test.ROTATE + ">A</text></svg>"
        )
        let matrix = m5CommandMatrix(list, "text", SvgDisplayCommandKind.Text)
        @Assert(m5PointNear(matrix.apply(SvgPoint(30.0, 30.0)), 50.0, 30.0))
    }

    /** image：图像命令矩阵使用同一原点。 */
    @TestCase
    public func imageOrigin(): Unit {
        let list = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<image x=\"30\" y=\"30\" width=\"20\" height=\"20\" href=\"x.png\" " +
            SvgTransformOriginRenderM5_test.ROTATE + "/></svg>"
        )
        let matrix = m5CommandMatrix(list, "image", SvgDisplayCommandKind.Image)
        @Assert(m5PointNear(matrix.apply(SvgPoint(30.0, 30.0)), 50.0, 30.0))
    }

    /** fill-box 百分比以元素包围盒为参考。 */
    @TestCase
    public func fillBoxRender(): Unit {
        let list = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<rect x=\"30\" y=\"30\" width=\"20\" height=\"20\" fill=\"red\" " +
            "transform=\"rotate(90)\" transform-origin=\"50% 50%\" transform-box=\"fill-box\"/></svg>"
        )
        let matrix = m5CommandMatrix(list, "rect", SvgDisplayCommandKind.FillPath)
        @Assert(m5PointNear(matrix.apply(SvgPoint(40.0, 40.0)), 40.0, 40.0))
        @Assert(m5PointNear(matrix.apply(SvgPoint(30.0, 30.0)), 50.0, 30.0))
    }

    /** getCTM 风格：带样式上下文与渲染矩阵一致。 */
    @TestCase
    public func geometryCtmWithStyles(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<rect id=\"r\" x=\"30\" y=\"30\" width=\"20\" height=\"20\" " +
            SvgTransformOriginRenderM5_test.ROTATE + "/></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let styled = SvgGeometry.ctm(rect, styles: tree)
        @Assert(m5PointNear(styled.apply(SvgPoint(40.0, 40.0)), 40.0, 40.0))
        let plain = SvgGeometry.ctm(rect)
        @Assert(m5PointNear(plain.apply(SvgPoint(40.0, 40.0)), -40.0, 40.0))
    }

    /** absoluteBounds 带样式上下文时与绕原点旋转一致。 */
    @TestCase
    public func absoluteBoundsWithStyles(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<rect id=\"r\" x=\"0\" y=\"0\" width=\"10\" height=\"10\" " +
            "transform=\"rotate(90)\" transform-origin=\"5 5\"/></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let rect = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let style = tree.get(rect) ?? throw invalidValue("缺少样式")
        let box = SvgGeometry.absoluteBounds(rect, style: style, styles: tree)
        match (box) {
            case Some(value) =>
                @Assert(abs(value.x) <= 0.001)
                @Assert(abs(value.y) <= 0.001)
                @Assert(abs(value.width - 10.0) <= 0.001)
                @Assert(abs(value.height - 10.0) <= 0.001)
            case None => @Fail("应有包围盒")
        }
    }

    /** 缺省 transform-origin / transform-box 时输出与 M4 逐字节一致。 */
    @TestCase
    public func defaultsMatchM4(): Unit {
        m5RenderAndCompare("m3-marker")
        m5RenderAndCompare("m4-text")
        m5RenderAndCompare("m4-view")
    }
}
