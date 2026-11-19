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

private func m5BlendCommands(svg: String): Array<SvgDisplayCommand> {
    SvgRenderTreeBuilder().build(SvgParser.parse(svg)).commands
}

@Test
public class SvgElementBlendM5_test {
    /** 填充 + 描边携带 blend 时，混合落在元素级 GroupBegin 上。 */
    @TestCase
    public func shapeBlendIsGrouped(): Unit {
        let commands = m5BlendCommands(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\" stroke=\"blue\" " +
            "style=\"mix-blend-mode: multiply\"/></svg>"
        )
        var groupCount = 0
        var fillCount = 0
        var strokeCount = 0
        var groupBlend = SvgMixBlendMode.Normal
        for (command in commands) {
            match (command.kind) {
                case GroupBegin =>
                    groupCount++
                    groupBlend = command.blendMode
                case FillPath =>
                    fillCount++
                    @Assert(command.blendMode == SvgMixBlendMode.Normal)
                case StrokePath =>
                    strokeCount++
                    @Assert(command.blendMode == SvgMixBlendMode.Normal)
                case _ => ()
            }
        }
        @Assert(groupCount == 1)
        @Assert(groupBlend == SvgMixBlendMode.Multiply)
        @Assert(fillCount == 1)
        @Assert(strokeCount == 1)
    }

    /** 未过滤文本的 mix-blend-mode 同样落在元素级组上。 */
    @TestCase
    public func textBlendIsGrouped(): Unit {
        let commands = m5BlendCommands(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">" +
            "<text x=\"2\" y=\"12\" font-family=\"Hershey\" font-size=\"10\" " +
            "style=\"mix-blend-mode: screen\">AB</text></svg>"
        )
        var groupBlend = SvgMixBlendMode.Normal
        var sawText = false
        for (command in commands) {
            match (command.kind) {
                case GroupBegin => groupBlend = command.blendMode
                case Text =>
                    sawText = true
                    @Assert(command.blendMode == SvgMixBlendMode.Normal)
                case _ => ()
            }
        }
        @Assert(sawText)
        @Assert(groupBlend == SvgMixBlendMode.Screen)
    }

    /** paint-order 与 blend 同时存在时仍只有一个混合组。 */
    @TestCase
    public func paintOrderBlendsOnce(): Unit {
        let commands = m5BlendCommands(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\" stroke=\"blue\" " +
            "paint-order=\"stroke fill\" style=\"mix-blend-mode: multiply\"/></svg>"
        )
        var groupCount = 0
        let kinds = ArrayList<SvgDisplayCommandKind>()
        for (command in commands) {
            match (command.kind) {
                case GroupBegin => groupCount++
                case FillPath | StrokePath => kinds.add(command.kind)
                case _ => ()
            }
        }
        @Assert(groupCount == 1)
        @Assert(kinds.size == 2)
        @Assert(kinds[0] == SvgDisplayCommandKind.StrokePath)
        @Assert(kinds[1] == SvgDisplayCommandKind.FillPath)
    }

    /** 多命令形状与显式混合组的像素结果一致（整组一次混合）。 */
    @TestCase
    public func multiCommandShapeMatchesGroupReference(): Unit {
        let direct = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"40\" height=\"40\" fill=\"#c86432\"/>" +
            "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"#808080\" stroke=\"#3366cc\" " +
            "stroke-width=\"4\" style=\"mix-blend-mode: multiply\"/></svg>"
        )
        let reference = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"40\" height=\"40\" fill=\"#c86432\"/>" +
            "<g style=\"mix-blend-mode: multiply\">" +
            "<rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"#808080\" stroke=\"#3366cc\" " +
            "stroke-width=\"4\"/></g></svg>"
        )
        @Assert(direct.pixels == reference.pixels)
    }

    /** 未过滤文本与显式混合组的像素结果一致。 */
    @TestCase
    public func textMatchesGroupReference(): Unit {
        let direct = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"24\">" +
            "<rect width=\"48\" height=\"24\" fill=\"#c86432\"/>" +
            "<text x=\"4\" y=\"16\" font-family=\"Hershey\" font-size=\"14\" fill=\"#3366cc\" " +
            "style=\"mix-blend-mode: multiply\">AB</text></svg>"
        )
        let reference = m5RenderSvg(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"24\">" +
            "<rect width=\"48\" height=\"24\" fill=\"#c86432\"/>" +
            "<g style=\"mix-blend-mode: multiply\">" +
            "<text x=\"4\" y=\"16\" font-family=\"Hershey\" font-size=\"14\" fill=\"#3366cc\">AB</text>" +
            "</g></svg>"
        )
        @Assert(direct.pixels == reference.pixels)
    }
}
