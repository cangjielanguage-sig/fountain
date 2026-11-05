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

private let TEXTPATH_LINE: SvgPathData = SvgPathData.parse("M 0 0 L 100 0")

@Test
public class SvgTextPathLayout_test {
    /** 水平路径：字形按 advance 中点落位，切线角 0。 */
    @TestCase
    public func horizontalPlacement(): Unit {
        let layout = SvgTextPathLayout()
        let placements = layout.place(
            [10.0, 10.0],
            TEXTPATH_LINE,
            SvgLength(0.0),
            SvgTextAnchor.Start
        )
        @Assert(placements.size == 2)
        @Assert(near(placements[0].x, 5.0) && near(placements[0].y, 0.0))
        @Assert(near(placements[1].x, 15.0))
        @Assert(near(placements[0].angle, 0.0))
        @Assert(near(placements[0].originX, 0.0))
    }

    /** startOffset 百分比与负值 / 超长钳制。 */
    @TestCase
    public func startOffsetForms(): Unit {
        let layout = SvgTextPathLayout()
        let percent = layout.place(
            [10.0, 10.0],
            TEXTPATH_LINE,
            SvgLength(50.0, unit: SvgLengthUnit.Percent),
            SvgTextAnchor.Start
        )
        @Assert(near(percent[0].x, 55.0))

        let negative = layout.place(
            [10.0],
            TEXTPATH_LINE,
            SvgLength(-10.0),
            SvgTextAnchor.Start
        )
        @Assert(near(negative[0].x, 5.0))

        let overlong = layout.place(
            [10.0],
            TEXTPATH_LINE,
            SvgLength(200.0),
            SvgTextAnchor.Start
        )
        @Assert(overlong.size == 0)
        @Assert(layout.warnings.size >= 1)
    }

    /** text-anchor 三档起点调整。 */
    @TestCase
    public func anchors(): Unit {
        let layout = SvgTextPathLayout()
        let middle = layout.place(
            [10.0, 10.0],
            TEXTPATH_LINE,
            SvgLength(50.0),
            SvgTextAnchor.Middle
        )
        @Assert(near(middle[0].x, 45.0) && near(middle[1].x, 55.0))

        let end = layout.place(
            [10.0, 10.0],
            TEXTPATH_LINE,
            SvgLength(50.0),
            SvgTextAnchor.End
        )
        @Assert(near(end[0].x, 35.0) && near(end[1].x, 45.0))
    }

    /** 路径短于文本时截断并 warning。 */
    @TestCase
    public func truncation(): Unit {
        let layout = SvgTextPathLayout()
        let shortPath = SvgPathData.parse("M 0 0 L 20 0")
        let placements = layout.place(
            [10.0, 10.0, 10.0, 10.0, 10.0],
            shortPath,
            SvgLength(0.0),
            SvgTextAnchor.Start
        )
        @Assert(placements.size == 2)
        @Assert(near(placements[0].x, 5.0) && near(placements[1].x, 15.0))
        @Assert(layout.warnings.size >= 1)
    }

    /** 45° 路径的切线角。 */
    @TestCase
    public func tangentAngle(): Unit {
        let layout = SvgTextPathLayout()
        let diagonal = SvgPathData.parse("M 0 0 L 10 10")
        let placements = layout.place(
            [2.0],
            diagonal,
            SvgLength(6.0710678118654755),
            SvgTextAnchor.Start
        )
        @Assert(placements.size == 1)
        @Assert(near(placements[0].angle, 45.0))
        @Assert(near(placements[0].x, 5.0) && near(placements[0].y, 5.0))
    }
}

@Test
public class SvgTextRotate_test {
    /** 单值、短列表复用、长列表忽略。 */
    @TestCase
    public func rotateLists(): Unit {
        let text = SvgText()
        text.rotate = Some([15.0])
        let single = resolveTextRotations(text, 5, ArrayList<String>())
        for (value in single) {
            @Assert(near(value, 15.0))
        }

        text.rotate = Some([10.0, 20.0])
        let short = resolveTextRotations(text, 4, ArrayList<String>())
        @Assert(near(short[0], 10.0) && near(short[1], 20.0))
        @Assert(near(short[2], 20.0) && near(short[3], 20.0))

        text.rotate = Some([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
        let long = resolveTextRotations(text, 2, ArrayList<String>())
        @Assert(long.size == 2 && near(long[1], 2.0))
    }

    /** 非法 rotate 值忽略并 warning。 */
    @TestCase
    public func invalidRotate(): Unit {
        let text = SvgText()
        text.setAttr("rotate", "abc")
        let warnings = ArrayList<String>()
        let values = resolveTextRotations(text, 3, warnings)
        for (value in values) {
            @Assert(near(value, 0.0))
        }
        @Assert(warnings.size >= 1)
        @Assert(warnings[0].contains("rotate"))
    }
}

@Test
public class SvgTextPathRender_test {
    /** textPath 沿路径排版；缺失引用降级且 warning。 */
    @TestCase
    public func textPathAndDegrade(): Unit {
        let alongPath = svgDoc(
            "<defs><path id=\"p\" d=\"M 5 60 L 55 60\"/></defs>" +
            "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
            "<textPath href=\"#p\">AB</textPath></text>",
            width: 60,
            height: 70
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(alongPath)
        var inkBelow = 0
        for (y in 50..70) {
            for (x in 0..60) {
                if (bitmap.pixel(x, y).alpha > 0.0) {
                    inkBelow++
                }
            }
        }
        @Assert(inkBelow > 5)

        let missing = svgDoc(
            "<text x=\"5\" y=\"30\" font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
            "<textPath href=\"#missing\">AB</textPath></text>",
            width: 40,
            height: 40
        )
        let fallbackRenderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let fallback = fallbackRenderer.render(missing)
        var inkAbove = 0
        for (y in 0..30) {
            for (x in 0..40) {
                if (fallback.pixel(x, y).alpha > 0.0) {
                    inkAbove++
                }
            }
        }
        @Assert(inkAbove > 5)
        var warned = false
        for (warning in fallbackRenderer.warnings) {
            if (warning.contains("textPath")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}

@Test
public class SvgTextPathInteraction_test {
    /** rotate 与 textPath 切线叠加，输出随之改变。 */
    @TestCase
    public func rotateStacksOnTangent(): Unit {
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc(
                "<defs><path id=\"p\" d=\"M 5 60 L 55 60\"/></defs>" +
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
                "<textPath href=\"#p\" rotate=\"0\">AB</textPath></text>",
                width: 60,
                height: 70
            )
        )
        let rotated = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc(
                "<defs><path id=\"p\" d=\"M 5 60 L 55 60\"/></defs>" +
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
                "<textPath href=\"#p\" rotate=\"30\">AB</textPath></text>",
                width: 60,
                height: 70
            )
        )
        @Assert(!(plain.pixels == rotated.pixels))
    }

    /** textPath 降级不影响同一文档中的其他文本。 */
    @TestCase
    public func degradeDoesNotAffectOthers(): Unit {
        let document = svgDoc(
            "<text x=\"5\" y=\"30\" font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
            "<textPath href=\"#missing\">AB</textPath></text>" +
            "<text x=\"5\" y=\"60\" font-family=\"Hershey\" font-size=\"10\" fill=\"black\">CD</text>",
            width: 60,
            height: 70
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        var first = 0
        var second = 0
        for (y in 15..30) {
            for (x in 0..40) {
                if (bitmap.pixel(x, y).alpha > 0.0) {
                    first++
                }
            }
        }
        for (y in 45..60) {
            for (x in 0..40) {
                if (bitmap.pixel(x, y).alpha > 0.0) {
                    second++
                }
            }
        }
        @Assert(first > 0)
        @Assert(second > 0)
    }
}

@Test
public class SvgTextPathEmptyM3_test {
    /** 空 path 属性降级为普通水平文本。 */
    @TestCase
    public func emptyPathAttributeDegrades(): Unit {
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc(
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">AB</text>",
                width: 40,
                height: 40
            )
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let degraded = renderer.render(
            svgDoc(
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
                "<textPath path=\"\">AB</textPath></text>",
                width: 40,
                height: 40
            )
        )
        @Assert(degraded.pixels == plain.pixels)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("textPath") && warning.contains("降级")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** href 指向零长度路径同样降级。 */
    @TestCase
    public func zeroLengthPathDegrades(): Unit {
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc(
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">AB</text>",
                width: 40,
                height: 40
            )
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let degraded = renderer.render(
            svgDoc(
                "<defs><path id=\"z\" d=\"M 10 10 L 10 10\"/></defs>" +
                "<text font-family=\"Hershey\" font-size=\"10\" fill=\"black\">" +
                "<textPath href=\"#z\">AB</textPath></text>",
                width: 40,
                height: 40
            )
        )
        @Assert(degraded.pixels == plain.pixels)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("textPath") && warning.contains("降级")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}
