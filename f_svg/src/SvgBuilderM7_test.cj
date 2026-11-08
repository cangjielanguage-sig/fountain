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
public class SvgBuilderM7_test {
    /** 根尺寸以 `px` 写入，`viewBox` 使用规范形式。 */
    @TestCase
    public func rootSizeAndViewBox(): Unit {
        let builder = SvgBuilder(200.0, 100.0)
        let root = builder.document().root
        @Assert(root.tag == "svg")
        @Assert(root.attr("width") == Some("200px"))
        @Assert(root.attr("height") == Some("100px"))
        @Assert(root.attr("viewBox") == Option<String>.None)

        let withBox = SvgBuilder(200.0, 100.0, viewBox: SvgViewBox(0.0, 0.0, 200.0, 100.0))
        @Assert(withBox.document().root.attr("viewBox") == Some("0 0 200 100"))
    }

    /** 分组嵌套与回退：`end` 把游标退回父元素。 */
    @TestCase
    public func groupNestingAndEnd(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.group(id: "outer").group(id: "inner").end().group(id: "second").end().end()
        let root = builder.document().root
        @Assert(root.children.size == 1)
        let outer = root.child("g")
        match (outer) {
            case Some(group) =>
                @Assert(group.attr("id") == Some("outer"))
                @Assert(group.children.size == 2)
                let inner = group.child("g")
                match (inner) {
                    case Some(nested) => @Assert(nested.attr("id") == Some("inner"))
                    case None => @Fail("缺少内层 g")
                }
            case None => @Fail("缺少 outer 分组")
        }
    }

    /** 根级 `end()` 无副作用，后续分组仍追加到根。 */
    @TestCase
    public func endAtRootIsNoop(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.end()
        builder.group(id: "after").end()
        let root = builder.document().root
        @Assert(root.children.size == 1)
        @Assert(root.child("g").isSome())
    }

    /** 同一父元素下的子元素顺序与调用顺序一致。 */
    @TestCase
    public func siblingOrderFollowsCalls(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.group(id: "first").end()
        builder.group(id: "second").end()
        let root = builder.document().root
        @Assert(root.children.size == 2)
        var index = 0
        for (node in root.children) {
            match (node) {
                case ElementNode(element) =>
                    let expected = if (index == 0) {
                        "first"
                    } else {
                        "second"
                    }
                    @Assert(element.attr("id") == Some(expected))
                    index++
                case _ => @Fail("根下不应出现非元素节点")
            }
        }
    }

    /** 规格场景：rect 在内层组，end 后 circle 回到 outer 组。 */
    @TestCase
    public func groupScenarioWithShapes(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.group(id: "outer")
            .group()
            .rect(x: 1.0, y: 2.0, width: 3.0, height: 4.0)
            .end()
            .circle(cx: 5.0, cy: 6.0, r: 7.0)
            .end()
        let root = builder.document().root
        @Assert(root.children.size == 1)
        match (root.child("g")) {
            case Some(outer) =>
                @Assert(outer.attr("id") == Some("outer"))
                @Assert(outer.child("circle").isSome())
                match (outer.child("g")) {
                    case Some(inner) =>
                        @Assert(inner.child("rect").isSome())
                        @Assert(inner.child("circle").isNone())
                    case None => @Fail("缺少内层 g")
                }
            case None => @Fail("缺少 outer 分组")
        }
    }

    /** 七种形状的标签、几何属性与 `px` 单位。 */
    @TestCase
    public func shapeGeometry(): Unit {
        let builder = SvgBuilder(200.0, 200.0)
        builder.rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0, rx: 2.0, ry: 3.0)
        builder.circle(cx: 5.0, cy: 6.0, r: 7.0)
        builder.ellipse(cx: 1.0, cy: 2.0, rx: 3.0, ry: 4.0)
        builder.line(x1: 1.0, y1: 2.0, x2: 3.0, y2: 4.0)
        builder.polyline(points: "0,0 10,10")
        builder.polygon(points: "0,0 5,5 0,10")
        builder.path(d: "M0 0L10 10")

        let root = builder.document().root
        @Assert(root.children.size == 7)
        match (root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("x") == Some("10px"))
                @Assert(rect.attr("y") == Some("30px"))
                @Assert(rect.attr("width") == Some("40px"))
                @Assert(rect.attr("height") == Some("40px"))
                @Assert(rect.attr("rx") == Some("2px"))
                @Assert(rect.attr("ry") == Some("3px"))
            case None => @Fail("缺少 rect")
        }
        match (root.child("circle")) {
            case Some(circle) =>
                @Assert(circle.attr("cx") == Some("5px"))
                @Assert(circle.attr("cy") == Some("6px"))
                @Assert(circle.attr("r") == Some("7px"))
            case None => @Fail("缺少 circle")
        }
        match (root.child("ellipse")) {
            case Some(ellipse) =>
                @Assert(ellipse.attr("cx") == Some("1px"))
                @Assert(ellipse.attr("cy") == Some("2px"))
                @Assert(ellipse.attr("rx") == Some("3px"))
                @Assert(ellipse.attr("ry") == Some("4px"))
            case None => @Fail("缺少 ellipse")
        }
        match (root.child("line")) {
            case Some(line) =>
                @Assert(line.attr("x1") == Some("1px"))
                @Assert(line.attr("y1") == Some("2px"))
                @Assert(line.attr("x2") == Some("3px"))
                @Assert(line.attr("y2") == Some("4px"))
            case None => @Fail("缺少 line")
        }
        @Assert(root.child("polyline").isSome())
        match (root.child("polyline")) {
            case Some(polyline) => @Assert(polyline.attr("points") == Some("0,0 10,10"))
            case None => @Fail("缺少 polyline")
        }
        match (root.child("polygon")) {
            case Some(polygon) => @Assert(polygon.attr("points") == Some("0,0 5,5 0,10"))
            case None => @Fail("缺少 polygon")
        }
        match (root.child("path")) {
            case Some(path) => @Assert(path.attr("d") == Some("M0 0L10 10"))
            case None => @Fail("缺少 path")
        }
    }

    /** `text` 的文本节点转义，`use` / `image` 的引用与坐标。 */
    @TestCase
    public func textUseAndImage(): Unit {
        let builder = SvgBuilder(200.0, 200.0)
        builder.text(content: "a<b&c", x: 1.0, y: 2.0)
        builder.use(href: "#r", x: 3.0, y: 4.0)
        builder.image(href: "a.png", x: 0.0, y: 0.0, width: 10.0, height: 10.0)
        let root = builder.document().root
        @Assert(root.children.size == 3)

        match (root.child("text")) {
            case Some(text) =>
                @Assert(text.text() == "a<b&c")
                @Assert(text.attr("x") == Some("1px"))
                @Assert(text.attr("y") == Some("2px"))
            case None => @Fail("缺少 text")
        }
        let serialized = writeSvgString(builder.document())
        @Assert(serialized.contains("a&lt;b&amp;c"))

        match (root.child("use")) {
            case Some(use) =>
                @Assert(readSvgHref(use) == Some("#r"))
                @Assert(use.attr("x") == Some("3px"))
                @Assert(use.attr("y") == Some("4px"))
            case None => @Fail("缺少 use")
        }
        match (root.child("image")) {
            case Some(image) =>
                @Assert(readSvgHref(image) == Some("a.png"))
                @Assert(image.attr("x") == Some("0px"))
                @Assert(image.attr("y") == Some("0px"))
                @Assert(image.attr("width") == Some("10px"))
                @Assert(image.attr("height") == Some("10px"))
            case None => @Fail("缺少 image")
        }
    }

    /** 样式只作用于当前元素；形状之后的兄弟不继承。 */
    @TestCase
    public func styleTargetsCurrentElementOnly(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0).fill("#3366cc")
        builder.circle(cx: 5.0, cy: 5.0, r: 2.0)
        builder.group(id: "g").fill("red").end()
        let root = builder.document().root
        match (root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("fill") == Some("#3366cc"))
                @Assert(rect.children.size == 0)
            case None => @Fail("缺少 rect")
        }
        match (root.child("circle")) {
            case Some(circle) => @Assert(circle.attr("fill") == Option<String>.None)
            case None => @Fail("缺少 circle")
        }
        match (root.child("g")) {
            case Some(group) =>
                @Assert(group.attr("fill") == Some("red"))
                @Assert(group.children.size == 0)
            case None => @Fail("缺少 g")
        }
    }
}
