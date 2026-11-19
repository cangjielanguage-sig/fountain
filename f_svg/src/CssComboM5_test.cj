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

internal let M5_COMBO_SVG =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"100\"><style>" +
    ":root { --brand: red }" +
    "@media screen and (min-width: 600px) {" +
    "rect[data-k]:first-child { fill: var(--brand); stroke-width: calc(2px * 2) }" +
    "}</style>" +
    "<g><rect data-k=\"1\" width=\"20\" height=\"20\"/>" +
    "<rect data-k=\"1\" x=\"40\" width=\"20\" height=\"20\"/></g></svg>"

@Test
public class CssComboM5_test {
    /** @media + 变量 + calc + 属性/结构选择器同时生效。 */
    @TestCase
    public func combinedFeatures(): Unit {
        let document = SvgParser.parse(M5_COMBO_SVG)
        let tree = SvgStyleResolver().compute(document.root, mediaWidth: 800.0)
        let first = document.elementsByTag("rect")[0]
        let second = document.elementsByTag("rect")[1]
        let firstStyle = tree.get(first) ?? throw invalidValue("缺少样式")
        let secondStyle = tree.get(second) ?? throw invalidValue("缺少样式")
        @Assert(firstStyle.fill().toString() == "#ff0000")
        @Assert(firstStyle.strokeWidth().value == 4.0)
        @Assert(secondStyle.fill().toString() != "#ff0000")
    }

    /** 窄视口下媒体块整体不生效。 */
    @TestCase
    public func narrowViewportDisablesBlock(): Unit {
        let document = SvgParser.parse(M5_COMBO_SVG)
        let tree = SvgStyleResolver().compute(document.root, mediaWidth: 400.0)
        let first = document.elementsByTag("rect")[0]
        let style = tree.get(first) ?? throw invalidValue("缺少样式")
        @Assert(style.fill().toString() == "#000000")
        @Assert(style.strokeWidth().value == 1.0)
    }

    /** 渲染入口同样应用组合特性，且重复渲染逐字节一致。 */
    @TestCase
    public func renderIsDeterministic(): Unit {
        let document = SvgParser.parse(M5_COMBO_SVG)
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1, width: 800, height: 100))
        let first = renderer.render(document)
        let second = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1, width: 800, height: 100))
            .render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(first.pixel(10, 10).toString() == "#ff0000")
    }

    /** 不含新特性的对照文档输出与 M4 基线逐字节一致。 */
    @TestCase
    public func controlDocumentUnchanged(): Unit {
        m5RenderAndCompare("basic")
    }
}
