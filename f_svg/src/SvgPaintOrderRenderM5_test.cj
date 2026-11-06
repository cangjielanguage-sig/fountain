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

/** 显示列表中各命令的 `tag:kind` 序列。 */
internal func m5CommandTags(list: SvgDisplayList): Array<String> {
    let result = ArrayList<String>()
    for (command in list.commands) {
        result.add("${command.tag}:${command.kind.toString()}")
    }
    result.toArray()
}

internal func m5DisplayList(svg: String): SvgDisplayList {
    let document = SvgParser.parse(svg)
    SvgRenderTreeBuilder().build(document)
}

internal let M5_PAINT_SHAPE =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"40\">" +
    "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\"/>" +
    "</svg>"

internal let M5_PAINT_MARKER =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\">" +
    "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\" refX=\"3\" refY=\"3\">" +
    "<circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"green\"/></marker></defs>" +
    "<path d=\"M10 30 L100 30\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\" " +
    "marker-start=\"url(#m)\" marker-end=\"url(#m)\"/></svg>"

@Test
public class SvgPaintOrderRenderM5_test {
    /** 缺省顺序：填充、描边、marker（无 marker 时只有前两者）。 */
    @TestCase
    public func defaultOrder(): Unit {
        let tags = m5CommandTags(m5DisplayList(M5_PAINT_SHAPE))
        @Assert(tags == ["rect:FillPath", "rect:StrokePath"])
    }

    /** stroke 优先时描边命令在前。 */
    @TestCase
    public func strokeFirst(): Unit {
        let tags = m5CommandTags(
            m5DisplayList(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"40\">" +
                "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"red\" stroke=\"blue\" " +
                "stroke-width=\"2\" style=\"paint-order: stroke fill\"/></svg>"
            )
        )
        @Assert(tags == ["rect:StrokePath", "rect:FillPath"])
    }

    /** marker 置于序列首位时 marker 命令最先。 */
    @TestCase
    public func markersFirst(): Unit {
        let tags = m5CommandTags(
            m5DisplayList(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\">" +
                "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\" refX=\"3\" refY=\"3\">" +
                "<circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"green\"/></marker></defs>" +
                "<path d=\"M10 30 L100 30\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\" " +
                "marker-start=\"url(#m)\" marker-end=\"url(#m)\" " +
                "style=\"paint-order: markers fill stroke\"/></svg>"
            )
        )
        @Assert(tags.size >= 3)
        @Assert(tags[0].startsWith("circle"))
        @Assert(tags[tags.size - 2].startsWith("path:FillPath"))
        @Assert(tags[tags.size - 1].startsWith("path:StrokePath"))
    }

    /** marker 数量不因 paint-order 改变。 */
    @TestCase
    public func markerCountUnchanged(): Unit {
        let baseline = m5CommandTags(m5DisplayList(M5_PAINT_MARKER))
        var baselineMarkers = 0
        for (tag in baseline) {
            if (tag.startsWith("circle")) {
                baselineMarkers++
            }
        }
        @Assert(baselineMarkers > 0)
        let reordered = m5CommandTags(
            m5DisplayList(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\">" +
                "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\" refX=\"3\" refY=\"3\">" +
                "<circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"green\"/></marker></defs>" +
                "<path d=\"M10 30 L100 30\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\" " +
                "marker-start=\"url(#m)\" marker-end=\"url(#m)\" " +
                "style=\"paint-order: fill markers stroke\"/></svg>"
            )
        )
        var markers = 0
        for (tag in reordered) {
            if (tag.startsWith("circle")) {
                markers++
            }
        }
        @Assert(markers == baselineMarkers)
    }

    /** marker 位置随层序移动，但数量与变换矩阵不变。 */
    @TestCase
    public func markerGeometryIsStable(): Unit {
        let baseline = m5DisplayList(M5_PAINT_MARKER)
        let reordered = m5DisplayList(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\">" +
            "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\" refX=\"3\" refY=\"3\">" +
            "<circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"green\"/></marker></defs>" +
            "<path d=\"M10 30 L100 30\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\" " +
            "marker-start=\"url(#m)\" marker-end=\"url(#m)\" " +
            "style=\"paint-order: markers fill stroke\"/></svg>"
        )
        let baselineMatrices = m5MarkerMatrices(baseline)
        let reorderedMatrices = m5MarkerMatrices(reordered)
        @Assert(baselineMatrices.size == reorderedMatrices.size)
        @Assert(baselineMatrices == reorderedMatrices)
        @Assert(m5CommandTags(reordered)[0].startsWith("circle"))
    }

    private func m5MarkerMatrices(list: SvgDisplayList): Array<String> {
        let result = ArrayList<String>()
        for (command in list.commands) {
            if (command.tag == "circle") {
                result.add(command.matrix.toString())
            }
        }
        result.toArray()
    }

    /** markers 位于中间时，填充先、marker 次、描边最后。 */
    @TestCase
    public func markersInMiddle(): Unit {
        let tags = m5CommandTags(
            m5DisplayList(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\">" +
                "<defs><marker id=\"m\" markerWidth=\"6\" markerHeight=\"6\" refX=\"3\" refY=\"3\">" +
                "<circle cx=\"3\" cy=\"3\" r=\"2\" fill=\"green\"/></marker></defs>" +
                "<path d=\"M10 30 L100 30\" fill=\"red\" stroke=\"blue\" stroke-width=\"2\" " +
                "marker-start=\"url(#m)\" marker-end=\"url(#m)\" " +
                "style=\"paint-order: fill markers stroke\"/></svg>"
            )
        )
        var fillIndex: Int64 = -1
        var strokeIndex: Int64 = -1
        for (index in 0..tags.size) {
            if (tags[index] == "path:FillPath" && fillIndex < 0) {
                fillIndex = index
            }
            if (tags[index] == "path:StrokePath") {
                strokeIndex = index
            }
        }
        @Assert(fillIndex == 0)
        @Assert(strokeIndex == tags.size - 1)
        var markerBetween = false
        for (index in 1..tags.size - 1) {
            if (tags[index].startsWith("circle")) {
                markerBetween = true
            }
        }
        @Assert(markerBetween)
    }

    /** 未声明 paint-order 时输出与 M4 逐字节一致。 */
    @TestCase
    public func defaultOutputMatchesM4(): Unit {
        m5RenderAndCompare("m3-marker")
        m5RenderAndCompare("basic")
        m5RenderAndCompare("m4-text")
    }

    /** README 示例可直接渲染，重叠处显示填充色。 */
    @TestCase
    public func readmeExampleRenders(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<rect x=\"10\" y=\"10\" width=\"40\" height=\"40\" " +
            "fill=\"orange\" stroke=\"navy\" stroke-width=\"6\" " +
            "style=\"paint-order: stroke fill\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(bitmap.pixel(30, 10).toString() == "#ffa500")
    }

    /** 非法值回退默认顺序并告警。 */
    @TestCase
    public func invalidOrderFallsBack(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"40\">" +
            "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"red\" stroke=\"blue\" " +
            "stroke-width=\"2\" style=\"paint-order: shadow fill\"/></svg>"
        )
        let builder = SvgRenderTreeBuilder()
        let list = builder.build(document)
        let tags = m5CommandTags(list)
        @Assert(tags == ["rect:FillPath", "rect:StrokePath"])
        var sawWarning = false
        for (warning in builder.warnings) {
            if (warning.contains("paint-order")) {
                sawWarning = true
            }
        }
        @Assert(sawWarning)
    }
}
