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

import std.fs.{File, Path}
import std.io.ByteBuffer
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

    /** 十个样式与通用属性方法全部落在当前形状。 */
    @TestCase
    public func styleMethods(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .fill("#3366cc")
            .stroke("#000")
            .strokeWidth(2.0)
            .opacity(0.5)
            .fillOpacity(0.25)
            .strokeOpacity(0.75)
            .transform("translate(1 2)")
            .attr("data-x", "v")
            .id("r1")
            .className("card")
        let root = builder.document().root
        match (root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("fill") == Some("#3366cc"))
                @Assert(rect.attr("stroke") == Some("#000"))
                @Assert(rect.attr("stroke-width") == Some("2px"))
                @Assert(rect.attr("opacity") == Some("0.5"))
                @Assert(rect.attr("fill-opacity") == Some("0.25"))
                @Assert(rect.attr("stroke-opacity") == Some("0.75"))
                @Assert(rect.attr("transform") == Some("translate(1 2)"))
                @Assert(rect.attr("data-x") == Some("v"))
                @Assert(rect.attr("id") == Some("r1"))
                @Assert(rect.attr("class") == Some("card"))
            case None => @Fail("缺少 rect")
        }
    }

    /** 单位与转义：透明度无单位、描边带 px、属性值经 Writer 转义后可重解析。 */
    @TestCase
    public func unitsAndEscaping(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .fill("url(#g)")
            .strokeWidth(1.5)
            .opacity(0.25)
            .attr("data-x", "a\"b")
        let text = writeSvgString(builder.document())
        @Assert(text.contains("fill=\"url(#g)\""))
        @Assert(text.contains("stroke-width=\"1.5px\""))
        @Assert(text.contains("opacity=\"0.25\""))
        @Assert(text.contains("data-x=\"a&quot;b\""))
        @Assert(!text.contains("opacity=\"0.25px\""))

        let parsed = SvgParser.parse(text)
        match (parsed.root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("data-x") == Some("a\"b"))
                @Assert(rect.attr("stroke-width") == Some("1.5px"))
                @Assert(rect.attr("fill") == Some("url(#g)"))
            case None => @Fail("重解析缺少 rect")
        }
    }

    /** 样式只用呈现属性，不生成 `style` 元素或 CSS。 */
    @TestCase
    public func stylesNeverCreateStyleElement(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .fill("red")
            .stroke("blue")
            .opacity(0.5)
        let document = builder.document()
        let text = writeSvgString(document)
        @Assert(!text.contains("<style"))
        @Assert(document.elementsByTag("style").size == 0)
        let parsed = SvgParser.parse(text)
        @Assert(parsed.elementsByTag("style").size == 0)
        match (parsed.root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("fill") == Some("red"))
                @Assert(rect.attr("stroke") == Some("blue"))
                @Assert(rect.attr("opacity") == Some("0.5"))
            case None => @Fail("重解析缺少 rect")
        }
    }

    /** 四种动画方法追加到当前元素，公共属性正确落盘。 */
    @TestCase
    public func animationMethodsAppendToCursor(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .animate(
                attribute: "x",
                from: "10",
                to: "150",
                values: ["10", "150"],
                dur: "2s",
                begin: SvgBegin.offset(0.0),
                repeatCount: "3",
                fill: SvgAnimationFill.Freeze,
                restart: SvgRestart.Never
            )
            .animateTransform(
                attribute: "transform",
                transformType: SvgAnimationTransformType.Rotate,
                from: "0",
                to: "360",
                dur: "1s",
                begin: SvgBegin.event("click"),
                repeatCount: "2",
                fill: SvgAnimationFill.Remove,
                restart: SvgRestart.WhenNotActive
            )
            .animateMotion(
                path: "M0 0L10 10",
                dur: "3s",
                begin: SvgBegin.offset(0.5),
                repeatCount: "indefinite",
                rotate: SvgMotionRotate.Fixed(90.0),
                keyPoints: "0;1",
                keyTimes: "0;1",
                fill: SvgAnimationFill.Freeze,
                restart: SvgRestart.Always
            )
            .set(
                attribute: "visibility",
                to: "hidden",
                begin: SvgBegin.offset(1.0),
                restart: SvgRestart.Never
            )
        let root = builder.document().root
        match (root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.children.size == 4)
                match (rect.child("animate")) {
                    case Some(animate) =>
                        @Assert(animate.attr("attributeName") == Some("x"))
                        @Assert(animate.attr("from") == Some("10"))
                        @Assert(animate.attr("to") == Some("150"))
                        @Assert(animate.attr("values") == Some("10;150"))
                        @Assert(animate.attr("dur") == Some("2s"))
                        @Assert(animate.attr("begin") == Some("0s"))
                        @Assert(animate.attr("repeatCount") == Some("3"))
                        @Assert(animate.attr("fill") == Some("freeze"))
                        @Assert(animate.attr("restart") == Some("never"))
                    case None => @Fail("缺少 animate")
                }
                match (rect.child("animateTransform")) {
                    case Some(transform) =>
                        @Assert(transform.attr("type") == Some("rotate"))
                        @Assert(transform.attr("attributeName") == Some("transform"))
                        @Assert(transform.attr("begin") == Some("click"))
                    case None => @Fail("缺少 animateTransform")
                }
                match (rect.child("animateMotion")) {
                    case Some(motion) =>
                        @Assert(motion.attr("path") == Some("M0 0L10 10"))
                        @Assert(motion.attr("rotate") == Some("90"))
                        @Assert(motion.attr("keyPoints") == Some("0;1"))
                        @Assert(motion.attr("repeatCount") == Some("indefinite"))
                    case None => @Fail("缺少 animateMotion")
                }
                match (rect.child("set")) {
                    case Some(set) =>
                        @Assert(set.attr("attributeName") == Some("visibility"))
                        @Assert(set.attr("to") == Some("hidden"))
                        @Assert(set.attr("begin") == Some("1s"))
                        @Assert(set.attr("restart") == Some("never"))
                    case None => @Fail("缺少 set")
                }
            case None => @Fail("缺少 rect")
        }
    }

    /** `animateMotion` 的 `mpath` 便捷参数；路径与引用都为空时不生成子元素。 */
    @TestCase
    public func animateMotionMpathConvenience(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .animateMotion(mpath: "#p", dur: "2s")
        builder.circle(cx: 5.0, cy: 5.0, r: 2.0).animateMotion(dur: "1s")
        let root = builder.document().root
        match (root.child("rect")) {
            case Some(rect) =>
                match (rect.child("animateMotion")) {
                    case Some(motion) =>
                        @Assert(motion.children.size == 1)
                        match (motion.child("mpath")) {
                            case Some(mpath) => @Assert(mpath.attr("href") == Some("#p"))
                            case None => @Fail("缺少 mpath")
                        }
                    case None => @Fail("缺少 animateMotion")
                }
            case None => @Fail("缺少 rect")
        }
        match (root.child("circle")) {
            case Some(circle) =>
                match (circle.child("animateMotion")) {
                    case Some(motion) =>
                        @Assert(motion.children.size == 0)
                        @Assert(motion.attr("path") == Option<String>.None)
                    case None => @Fail("缺少 animateMotion")
                }
            case None => @Fail("缺少 circle")
        }
    }

    /** 默认输出带声明与 `xmlns`；缩进选项可重解析且结构一致。 */
    @TestCase
    public func toSvgStringContract(): Unit {
        let builder = SvgBuilder(200.0, 100.0)
        builder.rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0).fill("#3366cc")
        let compact = builder.toSvgString()
        @Assert(compact.startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        @Assert(compact.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        @Assert(compact.contains("<rect x=\"10px\" y=\"30px\" width=\"40px\" height=\"40px\""))

        let indented = builder.toSvgString(options: SvgWriteOptions(indent: Some("  ")))
        @Assert(indented.startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        @Assert(indented.contains("\n  <rect"))

        let compactParsed = SvgParser.parse(compact)
        let indentedParsed = SvgParser.parse(indented)
        let compactRect = compactParsed.root.child("rect")
        let indentedRect = indentedParsed.root.child("rect")
        @Assert(compactRect.isSome())
        @Assert(indentedRect.isSome())
        match ((compactRect, indentedRect)) {
            case (Some(left), Some(right)) =>
                @Assert(left.attr("x") == right.attr("x"))
                @Assert(left.attr("y") == right.attr("y"))
                @Assert(left.attr("width") == right.attr("width"))
                @Assert(left.attr("height") == right.attr("height"))
                @Assert(left.attr("fill") == right.attr("fill"))
            case _ => @Fail("缩进输出与紧凑输出结构不一致")
        }
    }

    /** 两种 `save` 重载写入相同内容，且落盘文件可重解析。 */
    @TestCase
    public func saveWritesParseableFile(): Unit {
        let builder = SvgBuilder(200.0, 100.0)
        builder.rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)
            .fill("#3366cc")
            .animate(attribute: "x", from: "10", to: "150", dur: "2s")
        let target = "target/m7-card.svg"
        let targetPath = Path("target/m7-card-path.svg")
        builder.save(target)
        builder.save(targetPath)
        @Assert(File.readFrom(Path(target)) == File.readFrom(targetPath))
        @Assert(String.fromUtf8(File.readFrom(targetPath)) == builder.toSvgString())

        let parsed = SvgParser.parse(Path(target))
        @Assert(parsed.root.tag == "svg")
        match (parsed.root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("fill") == Some("#3366cc"))
                match (rect.child("animate")) {
                    case Some(animate) =>
                        @Assert(animate.attr("attributeName") == Some("x"))
                        @Assert(animate.attr("dur") == Some("2s"))
                    case None => @Fail("落盘结果缺少 animate")
                }
            case None => @Fail("落盘结果缺少 rect")
        }
    }

    /** 目标目录不存在时抛 `SvgException`，kind 为 `InvalidValue` 且消息含路径。 */
    @TestCase
    public func saveFailureWrapsAsInvalidValue(): Unit {
        let builder = SvgBuilder(200.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
        let missing = "target/m7-missing-dir/card.svg"
        var caught = false
        try {
            builder.save(missing)
        } catch (error: SvgException) {
            caught = true
            @Assert(error.kind == SvgErrorKind.InvalidValue)
            @Assert(error.message.contains(missing))
        }
        @Assert(caught)
    }

    /** 设计文档 §1 端到端：rect + animate 落盘后可重解析。 */
    @TestCase
    public func designExampleEndToEnd(): Unit {
        let builder = SvgBuilder(200.0, 100.0)
        builder.rect(x: 10.0, y: 30.0, width: 40.0, height: 40.0)
            .fill("#3366cc")
            .animate(
                attribute: "x",
                from: "10",
                to: "150",
                dur: "2s",
                begin: SvgBegin.offset(0.0),
                repeatCount: "indefinite"
            )
        let text = builder.toSvgString()
        @Assert(text.contains("width=\"200px\""))
        @Assert(text.contains("height=\"100px\""))
        @Assert(text.contains("x=\"10px\""))
        @Assert(text.contains("y=\"30px\""))
        @Assert(text.contains("width=\"40px\""))
        @Assert(text.contains("height=\"40px\""))
        @Assert(text.contains("fill=\"#3366cc\""))
        @Assert(text.contains("attributeName=\"x\""))
        @Assert(text.contains("from=\"10\""))
        @Assert(text.contains("to=\"150\""))
        @Assert(text.contains("dur=\"2s\""))
        @Assert(text.contains("begin=\"0s\""))
        @Assert(text.contains("repeatCount=\"indefinite\""))

        let target = "target/m7-design-card.svg"
        builder.save(target)
        let parsed = SvgParser.parse(Path(target))
        @Assert(parsed.root.attr("width") == Some("200px"))
        match (parsed.root.child("rect")) {
            case Some(rect) =>
                @Assert(rect.attr("fill") == Some("#3366cc"))
                match (rect.child("animate")) {
                    case Some(animate) =>
                        @Assert(animate.attr("attributeName") == Some("x"))
                        @Assert(animate.attr("from") == Some("10"))
                        @Assert(animate.attr("to") == Some("150"))
                        @Assert(animate.attr("dur") == Some("2s"))
                        @Assert(animate.attr("begin") == Some("0s"))
                        @Assert(animate.attr("repeatCount") == Some("indefinite"))
                    case None => @Fail("端到端结果缺少 animate")
                }
            case None => @Fail("端到端结果缺少 rect")
        }
    }

    /** 扩展 `begin` 不破坏时间轴：采样不抛异常，并按 M6 规则记录 warning。 */
    @TestCase
    public func extendedBeginKeepsTimelineStable(): Unit {
        let builder = SvgBuilder(100.0, 100.0)
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .id("a")
            .animate(attribute: "x", from: "0", to: "10", dur: "1s", begin: SvgBegin.offset(0.0))
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .id("b")
            .animate(attribute: "y", from: "0", to: "10", dur: "1s", begin: SvgBegin.after("a", 1.0))
        builder.rect(x: 0.0, y: 0.0, width: 10.0, height: 10.0)
            .id("c")
            .animate(attribute: "x", from: "0", to: "20", dur: "1s", begin: SvgBegin.repeatOf("a", 2))
        let timeline = SvgTimeline(builder.document())
        let sampled = timeline.sample(0.5)
        @Assert(sampled.root.tag == "svg")
        var endWarned = false
        var repeatWarned = false
        for (warning in timeline.warnings) {
            if (warning.contains("a.end+1s")) {
                endWarned = true
            }
            if (warning.contains("a.repeat(2)")) {
                repeatWarned = true
            }
        }
        @Assert(endWarned)
        @Assert(repeatWarned)
        @Assert(timeline.animations().size == 3)
        @Assert(timeline.duration() > 0.0)
    }

    /** `write(OutputStream)` 与 `toSvgString` 逐字节一致，且不关闭流。 */
    @TestCase
    public func writeOutputStreamMatchesString(): Unit {
        let builder = SvgBuilder(20.0, 10.0)
        builder.rect(x: 1.0, y: 1.0, width: 5.0, height: 5.0).fill("red")
        let expected = builder.toSvgString().toArray()
        let buffer = ByteBuffer()
        builder.write(buffer)
        @Assert(buffer.bytes() == expected)
        buffer.write("tail".toArray())
        @Assert(buffer.bytes().size == expected.size + 4)
    }

    /** `save(File)` 写入已打开文件，且不关闭它。 */
    @TestCase
    public func saveOpenedFile(): Unit {
        let builder = SvgBuilder(20.0, 10.0)
        builder.circle(cx: 5.0, cy: 5.0, r: 4.0).fill("#0f0")
        let file = File.createTemp(Path("target"))
        let target = file.info.path
        builder.save(file)
        file.write("<!--tail-->".toArray())
        file.flush()
        file.close()
        let text = String.fromUtf8(File.readFrom(target))
        @Assert(text == builder.toSvgString() + "<!--tail-->")
    }
}
