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
public class SvgDiscardM6_test {
    /** 标签注册与属性往返。 */
    @TestCase
    public func tagModel(): Unit {
        @Assert(SvgTag.isKnown("discard"))
        let created = match (SvgTag.create("discard")) {
            case Some(value) => value
            case None => throw invalidValue("discard 未注册")
        }
        @Assert(created.tag == "discard")
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><discard id=\"d\" begin=\"1s\" " +
            "beginEvent=\"click\"/></svg>"
        )
        let discard = document.elementById("d") ?? throw invalidValue("discard 丢失")
        @Assert(discard.attr("begin") == Some("1s"))
        @Assert(discard.attr("beginEvent") == Some("click"))
        @Assert(discard.toString().contains("<discard"))
    }

    /** 不产生绘制指令。 */
    @TestCase
    public func noDrawCommands(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<discard begin=\"1s\"/><rect width=\"10\" height=\"10\" fill=\"red\"/></svg>"
        )
        let list = SvgRenderTreeBuilder().build(document)
        @Assert(list.commands.size == 1)
        @Assert(list.commands[0].kind == SvgDisplayCommandKind.FillPath)
    }

    /** 缺少 begin warning。 */
    @TestCase
    public func missingBeginWarns(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<discard/></svg>"
        )
        let builder = SvgRenderTreeBuilder()
        let list = builder.build(document)
        @Assert(list.commands.size == 0)
        var warned = false
        for (warning in builder.warnings) {
            if (warning.contains("discard") && warning.contains("begin")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}
