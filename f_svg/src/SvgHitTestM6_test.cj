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
public class SvgHitTestM6_test {
    private func rect(id: String, x: Float64, y: Float64, w: Float64, h: Float64): SvgRect {
        let element = SvgRect()
        element.setAttr("id", id)
        element.setAttr("x", formatSvgNumber(x))
        element.setAttr("y", formatSvgNumber(y))
        element.setAttr("width", formatSvgNumber(w))
        element.setAttr("height", formatSvgNumber(h))
        element
    }

    private func rootOf(children: Array<SvgElement>): SvgRoot {
        let root = SvgRoot()
        for (child in children) {
            root.appendElement(child)
        }
        root
    }

    /** 重叠时后绘制者优先。 */
    @TestCase
    public func topmostOverlapping(): Unit {
        let lower = rect("lower", 0.0, 0.0, 100.0, 100.0)
        lower.setAttr("fill", "red")
        let upper = rect("upper", 0.0, 0.0, 100.0, 100.0)
        upper.setAttr("fill", "blue")
        let root = rootOf([lower, upper])
        let hits = SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0))
        @Assert(hits.size == 2)
        @Assert(hits[0] == upper)
        @Assert(hits[1] == lower)
    }

    /** `pointer-events: none` 连同子树退出命中。 */
    @TestCase
    public func nonePrunesSubtree(): Unit {
        let group = SvgContainer(SvgContainerKind.Group)
        group.setAttr("pointer-events", "none")
        group.appendElement(rect("r", 0.0, 0.0, 100.0, 100.0))
        let root = rootOf([group])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
    }

    /** visibleFill 忽略 fill=none；painted 要求实际画笔。 */
    @TestCase
    public func visibleFillAndPainted(): Unit {
        let invisibleFill = rect("a", 0.0, 0.0, 100.0, 100.0)
        invisibleFill.setAttr("fill", "none")
        invisibleFill.setAttr("stroke", "none")
        invisibleFill.setAttr("pointer-events", "visibleFill")
        let rootA = rootOf([invisibleFill])
        @Assert(SvgHitTest().hitTest(rootA, SvgPoint(50.0, 50.0)).size == 1)

        let unpainted = rect("b", 0.0, 0.0, 100.0, 100.0)
        unpainted.setAttr("fill", "none")
        unpainted.setAttr("stroke", "none")
        unpainted.setAttr("pointer-events", "painted")
        let rootB = rootOf([unpainted])
        @Assert(SvgHitTest().hitTest(rootB, SvgPoint(50.0, 50.0)).size == 0)

        unpainted.setAttr("fill", "red")
        @Assert(SvgHitTest().hitTest(rootB, SvgPoint(50.0, 50.0)).size == 1)
    }

    /** fill / stroke 只在各自几何区域命中。 */
    @TestCase
    public func fillVersusStroke(): Unit {
        let shape = rect("r", 0.0, 0.0, 100.0, 100.0)
        shape.setAttr("fill", "red")
        shape.setAttr("stroke", "blue")
        shape.setAttr("stroke-width", "10")
        let root = rootOf([shape])
        shape.setAttr("pointer-events", "fill")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 1)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(-3.0, 50.0)).size == 0)
        shape.setAttr("pointer-events", "stroke")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(-3.0, 50.0)).size == 1)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
    }

    /** bounding-box 命中包围盒内但在图形外的点。 */
    @TestCase
    public func boundingBox(): Unit {
        let circle = SvgCircle()
        circle.setAttr("cx", "50")
        circle.setAttr("cy", "50")
        circle.setAttr("r", "10")
        circle.setAttr("fill", "red")
        circle.setAttr("pointer-events", "bounding-box")
        let root = rootOf([circle])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(42.0, 42.0)).size == 1)
        circle.setAttr("pointer-events", "fill")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(42.0, 42.0)).size == 0)
    }

    /** visibility 与 pointer-events 的组合。 */
    @TestCase
    public func visibilityCombinations(): Unit {
        let shape = rect("r", 0.0, 0.0, 100.0, 100.0)
        shape.setAttr("fill", "red")
        shape.setAttr("visibility", "hidden")
        let root = rootOf([shape])
        shape.setAttr("pointer-events", "visible")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
        shape.setAttr("pointer-events", "all")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 1)
        shape.setAttr("pointer-events", "fill")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 1)
    }

    /** image 按矩形命中。 */
    @TestCase
    public func imageRectangle(): Unit {
        let image = SvgImage(
            href: "data:image/png;base64,AAAA",
            x: SvgLength(10.0),
            y: SvgLength(20.0),
            width: SvgLength(30.0),
            height: SvgLength(40.0)
        )
        let root = rootOf([image])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(25.0, 30.0)).size == 1)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(5.0, 5.0)).size == 0)
    }

    /** text 按字形包围盒 / 轮廓命中。 */
    @TestCase
    public func textHit(): Unit {
        let text = SvgText()
        text.setAttr("x", "10")
        text.setAttr("y", "30")
        text.setAttr("font-size", "20")
        text.setAttr("pointer-events", "all")
        text.appendText("A")
        let root = rootOf([text])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(12.0, 22.0)).size == 1)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(500.0, 500.0)).size == 0)
    }

    /** 规格四参 API：返回 ArrayList，elementAt 取首项，空文档为 None。 */
    @TestCase
    public func elementsAtSpecApi(): Unit {
        let lower = rect("lower", 0.0, 0.0, 100.0, 100.0)
        lower.setAttr("fill", "red")
        let upper = rect("upper", 0.0, 0.0, 100.0, 100.0)
        upper.setAttr("fill", "blue")
        let root = rootOf([lower, upper])
        let viewport = SvgViewport(100.0, 100.0)
        let styles = SvgStyleResolver().compute(root)
        let hits = SvgHitTest().elementsAt(root, SvgPoint(50.0, 50.0), viewport, styles)
        @Assert(hits.size == 2)
        @Assert(hits[0] == upper)
        @Assert(hits[1] == lower)
        let first = SvgHitTest().elementAt(root, SvgPoint(50.0, 50.0), viewport, styles)
        match (first) {
            case Some(value) => @Assert(value == upper)
            case None => @Fail("elementAt 应返回最上层元素")
        }
        let empty = SvgHitTest().elementsAt(root, SvgPoint(500.0, 500.0), viewport, styles)
        @Assert(empty.size == 0)
        @Assert(SvgHitTest().elementAt(root, SvgPoint(500.0, 500.0), viewport, styles).isNone())
        let legacy = SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0))
        @Assert(legacy.size == hits.size)
        @Assert(legacy[0] == hits[0])
    }

    /** 默认 `auto` 等价 `visiblePainted`；隐藏元素不参与，bounding-box 亦不越过 visibility。 */
    @TestCase
    public func autoEqualsVisiblePainted(): Unit {
        let shape = rect("r", 0.0, 0.0, 100.0, 100.0)
        shape.setAttr("fill", "red")
        shape.setAttr("visibility", "hidden")
        let root = rootOf([shape])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
        shape.setAttr("pointer-events", "bounding-box")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
        shape.setAttr("pointer-events", "all")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 1)
    }

    /** 根元素自身 `pointer-events: none` 时整棵子树退出。 */
    @TestCase
    public func rootNonePrunes(): Unit {
        let root = rootOf([rect("r", 0.0, 0.0, 100.0, 100.0)])
        root.setAttr("pointer-events", "none")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
        root.removeAttr("pointer-events")
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 1)
    }

    /** 命中上限缺省读取文档安全选项，显式参数优先。 */
    @TestCase
    public func securityMaxElements(): Unit {
        let root = rootOf([
            rect("a", 0.0, 0.0, 10.0, 10.0), rect("b", 0.0, 0.0, 10.0, 10.0),
            rect("c", 0.0, 0.0, 10.0, 10.0)
        ])
        let document = SvgDocument(root)
        document.parseOptions = SvgParseOptions(security: SvgSecurityOptions(maxElements: 2))
        var limited = false
        try {
            SvgHitTest().hitTest(document, SvgPoint(5.0, 5.0))
        } catch (error: SvgException) {
            limited = error.kind == SvgErrorKind.Limit
        }
        @Assert(limited)
        @Assert(SvgHitTest().hitTest(document, SvgPoint(5.0, 5.0), maxElements: 10).size == 3)
    }

    /** 文本轮廓缺失时不回退包围盒，并产生 warning。 */
    @TestCase
    public func textWithoutOutlineWarns(): Unit {
        let text = SvgText()
        text.setAttr("x", "0")
        text.setAttr("y", "30")
        text.setAttr("font-size", "20")
        text.setAttr("pointer-events", "fill")
        text.appendText(" ")
        let root = rootOf([text])
        let hit = SvgHitTest()
        @Assert(hit.hitTest(root, SvgPoint(1.0, 25.0)).size == 0)
        var warned = false
        for (warning in hit.warnings) {
            if (warning.contains("轮廓")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 设备坐标：DPR 与根 viewBox 都参与换算。 */
    @TestCase
    public func deviceCoordinates(): Unit {
        let root = SvgRoot()
        root.setAttr("viewBox", "0 0 100 100")
        root.appendElement(rect("r", 0.0, 0.0, 50.0, 50.0))
        let options = SvgRenderOptions(width: 100, height: 100, devicePixelRatio: 2.0)
        let hits = SvgHitTest().hitTest(root, SvgPoint(20.0, 20.0), options: options)
        @Assert(hits.size == 1)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(180.0, 180.0), options: options).size == 0)
    }

    /** 路径外、描边外缘、零长度路径、空文档与超限都不崩溃。 */
    @TestCase
    public func boundaries(): Unit {
        let shape = rect("r", 0.0, 0.0, 10.0, 10.0)
        shape.setAttr("fill", "red")
        let root = rootOf([shape])
        @Assert(SvgHitTest().hitTest(root, SvgPoint(50.0, 50.0)).size == 0)
        @Assert(SvgHitTest().hitTest(root, SvgPoint(10.0, 10.0)).size == 1)

        let zero = SvgLine(x1: SvgLength(5.0), y1: SvgLength(5.0), x2: SvgLength(5.0), y2: SvgLength(5.0))
        zero.setAttr("stroke", "red")
        zero.setAttr("stroke-width", "2")
        zero.setAttr("stroke-linecap", "round")
        let zeroRoot = rootOf([zero])
        @Assert(SvgHitTest().hitTest(zeroRoot, SvgPoint(5.0, 5.0)).size == 1)

        @Assert(SvgHitTest().hitTest(rootOf(Array<SvgElement>()), SvgPoint(1.0, 1.0)).size == 0)

        let many = rootOf([rect("a", 0.0, 0.0, 10.0, 10.0), rect("b", 0.0, 0.0, 10.0, 10.0)])
        var limited = false
        try {
            SvgHitTest().hitTest(many, SvgPoint(5.0, 5.0), maxElements: 1)
        } catch (_: SvgException) {
            limited = true
        }
        @Assert(limited)
    }

    /** 未提供交互状态时渲染与 M5 逐字节一致；提供时 :hover 生效。 */
    @TestCase
    public func renderInteractionAndByteStability(): Unit {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<style>rect:hover { fill: red }</style><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"
        let document = SvgParser.parse(svg)
        let baseline = SvgRenderer().render(document)
        let empty = SvgRenderer(options: SvgRenderOptions(hoveredIds: Array<String>())).render(document)
        @Assert(baseline.pixels == empty.pixels)
        @Assert(baseline.pixel(10, 10).toString() == "#000000")
        let hovered = SvgRenderer(options: SvgRenderOptions(hoveredIds: ["missing"])).render(document)
        @Assert(baseline.pixels == hovered.pixels)
        let rectId = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<style>rect:hover { fill: red }</style><rect id=\"r\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"
        )
        let painted = SvgRenderer(options: SvgRenderOptions(hoveredIds: ["r"])).render(rectId)
        @Assert(painted.pixel(10, 10).toString() == "#ff0000")
    }
}
