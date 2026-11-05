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

internal func svgDoc(body: String, width!: Int64 = 100, height!: Int64 = 100): SvgDocument {
    SvgParser.parse(
        '<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${body}</svg>'
    )
}

internal func fillCommands(list: SvgDisplayList): ArrayList<SvgDisplayCommand> {
    let result = ArrayList<SvgDisplayCommand>()
    for (command in list.commands) {
        if (command.kind == SvgDisplayCommandKind.FillPath) {
            result.add(command)
        }
    }
    result
}

@Test
public class SvgRenderTree_test {
    /** display:none 跳过、文档顺序保持、渲染不修改文档。 */
    @TestCase
    public func displayNoneAndOrder(): Unit {
        let document = svgDoc(
            '<rect id="hidden" width="10" height="10" display="none"/>' +
            '<circle id="first" cx="5" cy="5" r="3"/>' +
            '<g><rect id="second" width="4" height="4"/></g>'
        )
        let before = document.toString()
        let list = SvgRenderTreeBuilder().build(document)
        let fills = fillCommands(list)
        @Assert(fills.size == 2)
        @Assert(fills[0].tag == "circle")
        @Assert(fills[1].tag == "rect")
        @Assert(document.toString() == before)
        @Assert(document.root.children.size == 3)
    }

    /** use 复用、x/y 平移、symbol 视口、缺失引用与循环。 */
    @TestCase
    public func useExpansion(): Unit {
        let document = svgDoc(
            '<defs><rect id="r" width="10" height="10"/></defs><use href="#r" x="10" y="20"/>'
        )
        let list = SvgRenderTreeBuilder().build(document)
        let fills = fillCommands(list)
        @Assert(fills.size == 1)
        @Assert(pointNear(fills[0].matrix.apply(SvgPoint(0.0, 0.0)), SvgPoint(10.0, 20.0)))
        @Assert(pointNear(fills[0].matrix.apply(SvgPoint(10.0, 10.0)), SvgPoint(20.0, 30.0)))

        let symbolDocument = svgDoc(
            '<defs><symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol></defs>' +
            '<use href="#s" width="20" height="20"/>'
        )
        let symbolList = SvgRenderTreeBuilder().build(symbolDocument)
        let symbolFills = fillCommands(symbolList)
        @Assert(symbolFills.size == 1)
        @Assert(pointNear(symbolFills[0].matrix.apply(SvgPoint(10.0, 10.0)), SvgPoint(20.0, 20.0)))

        let missing = svgDoc('<use href="#none"/>')
        let missingBuilder = SvgRenderTreeBuilder()
        let missingList = missingBuilder.build(missing)
        @Assert(fillCommands(missingList).size == 0)
        @Assert(missingBuilder.warnings.size >= 1)

        let cycle = svgDoc(
            '<defs><g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g></defs>' +
            '<use href="#a"/>'
        )
        let cycleBuilder = SvgRenderTreeBuilder()
        cycleBuilder.build(cycle)
        @Assert(cycleBuilder.warnings.size >= 1)

        let deepUse = StringBuilder()
        deepUse.append("<defs>")
        for (index in 0..=65) {
            deepUse.append('<g id="u${index}">')
            if (index < 65) {
                deepUse.append('<use href="#u${index + 1}"/>')
            }
            deepUse.append("</g>")
        }
        deepUse.append("</defs><use href=\"#u0\"/>")
        let deepUseError = expectSvgException({=>
            SvgRenderTreeBuilder().build(svgDoc(deepUse.toString()))
        })
        @Assert(deepUseError.kind == SvgErrorKind.Limit)

        let deepSvg = StringBuilder()
        for (_ in 0..=65) {
            deepSvg.append('<svg width="10" height="10">')
        }
        for (_ in 0..=65) {
            deepSvg.append("</svg>")
        }
        let deepSvgError = expectSvgException({=>
            SvgRenderTreeBuilder().build(svgDoc(deepSvg.toString()))
        })
        @Assert(deepSvgError.kind == SvgErrorKind.Limit)
    }

    /** 嵌套 svg：视口缩放、x/y 偏移与裁剪区域。 */
    @TestCase
    public func nestedSvg(): Unit {
        let document = svgDoc(
            '<svg x="10" y="10" width="50" height="50" viewBox="0 0 25 25">' +
            '<rect width="25" height="25"/></svg>'
        )
        let list = SvgRenderTreeBuilder().build(document)
        let fills = fillCommands(list)
        @Assert(fills.size == 1)
        @Assert(pointNear(fills[0].matrix.apply(SvgPoint(0.0, 0.0)), SvgPoint(10.0, 10.0)))
        @Assert(pointNear(fills[0].matrix.apply(SvgPoint(25.0, 25.0)), SvgPoint(60.0, 60.0)))
        match (fills[0].clipRect) {
            case Some(rect) =>
                @Assert(near(rect.x, 10.0) && near(rect.y, 10.0))
                @Assert(near(rect.width, 50.0) && near(rect.height, 50.0))
            case None => @Fail("嵌套 svg 应有裁剪区域")
        }
    }

    /** image 只产生占位指令并写 warning，不发起请求。 */
    @TestCase
    public func imagePlaceholder(): Unit {
        let document = svgDoc('<image x="2" y="2" width="6" height="6" href="#img"/>')
        let builder = SvgRenderTreeBuilder()
        let list = builder.build(document)
        var images = 0
        for (command in list.commands) {
            if (command.kind == SvgDisplayCommandKind.Image) {
                images++
            }
        }
        @Assert(images == 1)
        @Assert(builder.warnings.size >= 1)
        match (list.commands[0].bounds) {
            case Some(box) => @Assert(near(box.width, 6.0) && near(box.height, 6.0))
            case None => @Fail("image 应有占位边界")
        }
    }
}
