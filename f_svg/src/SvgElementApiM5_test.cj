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

internal func m5BoxNear(box: ?SvgBounds, x: Float64, y: Float64, width: Float64, height: Float64): Bool {
    match (box) {
        case Some(value) =>
            abs(value.x - x) <= 0.01 && abs(value.y - y) <= 0.01 &&
                abs(value.width - width) <= 0.01 && abs(value.height - height) <= 0.01
        case None => false
    }
}

internal func m5ParsedElement(svg: String, id: String): SvgElement {
    let document = SvgParser.parse(svg)
    document.elementById(id) ?? throw invalidValue("缺少元素 ${id}")
}

@Test
public class SvgElementApiM5_test {
    /** 形状包围盒。 */
    @TestCase
    public func shapeBBox(): Unit {
        let rect = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" x=\"10\" y=\"20\" " +
            "width=\"30\" height=\"40\"/></svg>",
            "r"
        )
        @Assert(m5BoxNear(rect.getBBox(), 10.0, 20.0, 30.0, 40.0))
    }

    /** 描边外扩与无描边不扩展。 */
    @TestCase
    public func strokeBBox(): Unit {
        let stroked = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" x=\"10\" y=\"20\" " +
            "width=\"30\" height=\"40\" stroke=\"red\" stroke-width=\"4\"/></svg>",
            "r"
        )
        @Assert(m5BoxNear(stroked.getBBox(options: SvgBBoxOptions(stroke: true)), 8.0, 18.0, 34.0, 44.0))
        let plain = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" x=\"10\" y=\"20\" " +
            "width=\"30\" height=\"40\" stroke=\"none\" stroke-width=\"4\"/></svg>",
            "r"
        )
        @Assert(m5BoxNear(plain.getBBox(options: SvgBBoxOptions(stroke: true)), 10.0, 20.0, 30.0, 40.0))
    }

    /** 视口裁剪。 */
    @TestCase
    public func clippedBBox(): Unit {
        let rect = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"50\" height=\"50\">" +
            "<rect id=\"r\" x=\"40\" y=\"0\" width=\"100\" height=\"10\"/></svg>",
            "r"
        )
        @Assert(m5BoxNear(rect.getBBox(options: SvgBBoxOptions(clipped: true)), 40.0, 0.0, 10.0, 10.0))
        @Assert(m5BoxNear(rect.getBBox(), 40.0, 0.0, 100.0, 10.0))
    }

    /** 不可渲染元素返回 None。 */
    @TestCase
    public func nonRenderableBBox(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><defs id=\"d\"/>" +
            "<path id=\"p\" d=\"\"/></svg>"
        )
        let defs = document.elementById("d") ?? throw invalidValue("缺少 defs")
        @Assert(defs.getBBox().isNone())
        let path = document.elementById("p") ?? throw invalidValue("缺少 path")
        @Assert(path.getBBox().isNone())
    }

    /** 容器并集与子 transform。 */
    @TestCase
    public func containerBBox(): Unit {
        let group = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"g\">" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>" +
            "<rect x=\"20\" y=\"5\" width=\"10\" height=\"10\"/></g></svg>",
            "g"
        )
        @Assert(m5BoxNear(group.getBBox(), 0.0, 0.0, 30.0, 15.0))
        let transformed = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"g\">" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>" +
            "<rect x=\"20\" y=\"5\" width=\"10\" height=\"10\" transform=\"translate(100,0)\"/></g></svg>",
            "g"
        )
        @Assert(m5BoxNear(transformed.getBBox(), 0.0, 0.0, 130.0, 15.0))
    }

    /** use 平移与 image / 定义型元素。 */
    @TestCase
    public func useAndImageBBox(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><defs><rect id=\"r\" width=\"10\" height=\"10\"/></defs>" +
            "<use id=\"u\" href=\"#r\" x=\"5\" y=\"6\"/>" +
            "<image id=\"i\" x=\"1\" y=\"2\" width=\"30\" height=\"40\"/>" +
            "<symbol id=\"s\"/></svg>"
        )
        let use = document.elementById("u") ?? throw invalidValue("缺少 use")
        @Assert(m5BoxNear(use.getBBox(), 5.0, 6.0, 10.0, 10.0))
        let image = document.elementById("i") ?? throw invalidValue("缺少 image")
        @Assert(m5BoxNear(image.getBBox(), 1.0, 2.0, 30.0, 40.0))
        let symbol = document.elementById("s") ?? throw invalidValue("缺少 symbol")
        @Assert(symbol.getBBox().isNone())
    }

    /** 祖先变换与未挂载元素的 CTM。 */
    @TestCase
    public func ctm(): Unit {
        let rect = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g transform=\"translate(10,0)\">" +
            "<rect id=\"r\"/></g></svg>",
            "r"
        )
        let matrix = rect.getCTM()
        @Assert(m5PointNear(matrix.apply(SvgPoint(0.0, 0.0)), 10.0, 0.0))
        let unmounted = SvgRect()
        @Assert(m5PointNear(unmounted.getCTM().apply(SvgPoint(5.0, 6.0)), 5.0, 6.0))
    }

    /** 屏幕矩阵含 DPR。 */
    @TestCase
    public func screenCtm(): Unit {
        let rect = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect id=\"r\"/></svg>",
            "r"
        )
        let viewport = SvgViewportTransform(100.0, 100.0, SvgMatrix.identity, 2.0)
        let matrix = rect.getScreenCTM(viewport: viewport)
        @Assert(m5PointNear(matrix.apply(SvgPoint(10.0, 10.0)), 20.0, 20.0))
        let byDefault = rect.getScreenCTM()
        @Assert(m5PointNear(byDefault.apply(SvgPoint(10.0, 10.0)), 10.0, 10.0))
    }

    /** transform-origin 参与 getCTM。 */
    @TestCase
    public func ctmWithOrigin(): Unit {
        let rect = m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" transform=\"rotate(90)\" " +
            "transform-origin=\"50 50\"/></svg>",
            "r"
        )
        @Assert(m5PointNear(rect.getCTM().apply(SvgPoint(50.0, 50.0)), 50.0, 50.0))
    }

    /** 路径长度与取点。 */
    @TestCase
    public func pathLength(): Unit {
        let path = match (m5ParsedElement(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><path id=\"p\" d=\"M0 0 L100 0\"/></svg>",
            "p"
        )) {
            case value: SvgPath => value
            case _ => throw invalidValue("不是路径")
        }
        @Assert(abs(path.getTotalLength() - 100.0) < 0.001)
        @Assert(m5PointNear(path.getPointAtLength(25.0), 25.0, 0.0))
        @Assert(m5PointNear(path.getPointAtLength(-5.0), 0.0, 0.0))
        @Assert(m5PointNear(path.getPointAtLength(500.0), 100.0, 0.0))
        let empty = SvgPath()
        @Assert(empty.getTotalLength() == 0.0)
        @Assert(m5PointNear(empty.getPointAtLength(10.0), 0.0, 0.0))
    }

    /** 类名查询与选择器查询。 */
    @TestCase
    public func queries(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"g\" class=\"a\">" +
            "<rect id=\"r1\" class=\"a b\"/><circle id=\"c1\" class=\"ab\"/>" +
            "<rect id=\"r2\" class=\"a skip\"/><circle id=\"c2\"/></g></svg>"
        )
        let group = document.elementById("g") ?? throw invalidValue("缺少 g")
        let byClass = group.getElementsByClassName("a")
        @Assert(byClass.size == 2)
        @Assert(byClass[0].tag == "rect")
        @Assert(byClass[1].attr("id") == Some("r2"))
        @Assert(group.getElementsByClassName("").size == 0)
        let queried = group.querySelectorAll("rect:not(.skip) + circle")
        @Assert(queried.size == 1)
        @Assert(queried[0].attr("id") == Some("c1"))
        var threw = false
        try {
            group.querySelectorAll("[x=")
        } catch (error: SvgException) {
            threw = error.kind == SvgErrorKind.InvalidValue
        }
        @Assert(threw)
    }

    /** 查询不修改文档。 */
    @TestCase
    public func queriesAreReadOnly(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><g id=\"g\"><rect id=\"r\" class=\"a\"/></g></svg>"
        )
        let group = document.elementById("g") ?? throw invalidValue("缺少 g")
        let before = group.toString()
        let first = group.querySelectorAll("rect").size
        let second = group.querySelectorAll("rect").size
        @Assert(first == second)
        @Assert(group.toString() == before)
    }
}
