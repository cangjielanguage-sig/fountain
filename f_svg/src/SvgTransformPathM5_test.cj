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
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgTransformPathM5_test {
    /** clipPath 子元素的 transform-origin 与主渲染路径一致。 */
    @TestCase
    public func clipChildTransformOriginMatchesDirect(): Unit {
        let clipped = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<defs><clipPath id=\"c\"><rect x=\"8\" y=\"8\" width=\"40\" height=\"16\" " +
            "transform=\"rotate(90)\" transform-origin=\"28 16\" transform-box=\"fill-box\"/>" +
            "</clipPath></defs>" +
            "<rect width=\"64\" height=\"64\" fill=\"red\" clip-path=\"url(#c)\"/></svg>"
        )
        let direct = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<rect x=\"8\" y=\"8\" width=\"40\" height=\"16\" fill=\"red\" " +
            "transform=\"rotate(90)\" transform-origin=\"28 16\" transform-box=\"fill-box\"/></svg>"
        )
        @Assert(clipped.pixels == direct.pixels)
    }

    /** mask 子元素的 transform-origin 与主渲染路径一致。 */
    @TestCase
    public func maskChildTransformOriginMatchesDirect(): Unit {
        let masked = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<defs><mask id=\"m\"><rect x=\"8\" y=\"8\" width=\"40\" height=\"16\" fill=\"white\" " +
            "transform=\"rotate(90)\" transform-origin=\"28 16\" transform-box=\"fill-box\"/>" +
            "</mask></defs>" +
            "<rect width=\"64\" height=\"64\" fill=\"red\" mask=\"url(#m)\"/></svg>"
        )
        let direct = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<rect x=\"8\" y=\"8\" width=\"40\" height=\"16\" fill=\"red\" " +
            "transform=\"rotate(90)\" transform-origin=\"28 16\" transform-box=\"fill-box\"/></svg>"
        )
        @Assert(masked.pixels == direct.pixels)
    }

    /** `g` 的 fill-box 百分比原点按子内容包围盒计算。 */
    @TestCase
    public func groupFillBoxOrigin(): Unit {
        let grouped = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<g transform=\"rotate(90)\" transform-origin=\"50% 50%\" transform-box=\"fill-box\">" +
            "<rect x=\"10\" y=\"20\" width=\"20\" height=\"10\" fill=\"red\"/></g></svg>"
        )
        let direct = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<rect x=\"10\" y=\"20\" width=\"20\" height=\"10\" fill=\"red\" " +
            "transform=\"rotate(90)\" transform-origin=\"50% 50%\" transform-box=\"fill-box\"/></svg>"
        )
        @Assert(grouped.pixels == direct.pixels)
    }

    /** getCTM 与同一元素在显示列表中的矩阵一致。 */
    @TestCase
    public func ctmMatchesRenderMatrix(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<g transform=\"translate(3,4)\">" +
            "<rect id=\"r\" x=\"10\" y=\"20\" width=\"20\" height=\"10\" transform=\"rotate(30)\" " +
            "transform-origin=\"50% 50%\" transform-box=\"fill-box\"/></g></svg>"
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let list = SvgRenderTreeBuilder().build(document)
        var rendered: ?SvgMatrix = None
        for (command in list.commands) {
            if (command.kind == SvgDisplayCommandKind.FillPath || command.kind == SvgDisplayCommandKind.StrokePath) {
                rendered = Some(command.matrix)
            }
        }
        let matrix = match (rendered) {
            case Some(value) => value
            case None => throw invalidValue("缺少绘制指令")
        }
        let ctm = element.getCTM()
        let left = ctm.apply(SvgPoint(17.0, 23.0))
        let right = matrix.apply(SvgPoint(17.0, 23.0))
        @Assert(m5PointNear(left, right.x, right.y))
    }

    /** `screenCTM` 支持可选样式上下文，与 `ctm` 对齐。 */
    @TestCase
    public func screenCtmAcceptsStyles(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\">" +
            "<rect id=\"r\" x=\"10\" y=\"20\" width=\"20\" height=\"10\" " +
            "transform=\"rotate(30)\" transform-origin=\"50% 50%\" transform-box=\"fill-box\"/></svg>"
        )
        let element = document.elementById("r") ?? throw invalidValue("缺少矩形")
        let tree = SvgStyleResolver().compute(document.root, mediaWidth: 64.0, mediaHeight: 64.0)
        let viewport = SvgViewportTransform(64.0, 64.0, SvgMatrix.identity, 1.0)
        let screen = SvgGeometry.screenCTM(element, viewport, styles: tree)
        let expected = SvgGeometry.ctm(
            element,
            styles: tree,
            viewportWidth: 64.0,
            viewportHeight: 64.0
        )
        let left = screen.apply(SvgPoint(17.0, 23.0))
        let right = expected.apply(SvgPoint(17.0, 23.0))
        @Assert(m5PointNear(left, right.x, right.y))
    }
}
