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

internal let M5_MEDIA_SVG =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"100\">" +
    "<style>@media screen and (min-width: 600px) { rect { fill: red } }" +
    "@media screen and (max-width: 400px) { rect { fill: blue } }</style>" +
    "<rect x=\"0\" y=\"0\" width=\"400\" height=\"100\" fill=\"green\"/></svg>"

/** 取位图中心偏左的像素颜色，避免边界抗锯齿。 */
internal func m5CenterColor(bitmap: SvgBitmap): String {
    bitmap.pixel(bitmap.width / 4, bitmap.height / 2).toString()
}

@Test
public class CssMediaWidthM5_test {
    private func rectStyle(width: Float64): SvgComputedStyle {
        let document = SvgParser.parse(M5_MEDIA_SVG)
        let tree = SvgStyleResolver().compute(document.root, mediaWidth: width)
        let rect = document.elementsByTag("rect")[0]
        tree.get(rect) ?? throw invalidValue("缺少矩形样式")
    }

    /** compute 的宽度参数直接决定媒体查询。 */
    @TestCase
    public func computeWidthSelectsRule(): Unit {
        @Assert(rectStyle(800.0).fill().toString() == "#ff0000")
        @Assert(rectStyle(400.0).fill().toString() == "#0000ff")
        @Assert(rectStyle(500.0).fill().toString() == "#008000")
    }

    /** 未提供宽度时按 300 求值。 */
    @TestCase
    public func defaultWidthIs300(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "@media (min-width: 400px) { rect { fill: red } }</style>" +
            "<rect/></svg>"
        )
        let tree = SvgStyleResolver().compute(document.root)
        let rect = document.elementsByTag("rect")[0]
        let style = tree.get(rect) ?? throw invalidValue("缺少矩形样式")
        @Assert(style.fill().toString() != "#ff0000")
    }

    /** 文档渲染使用 SvgRenderOptions.width。 */
    @TestCase
    public func documentRenderUsesOptionsWidth(): Unit {
        let document = SvgParser.parse(M5_MEDIA_SVG)
        let wide = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1, width: 800, height: 100))
            .render(document)
        @Assert(m5CenterColor(wide) == "#ff0000")
        let narrow = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1, width: 400, height: 100))
            .render(document)
        @Assert(m5CenterColor(narrow) == "#0000ff")
    }

    /** 根元素宽度作为回退来源。 */
    @TestCase
    public func rootWidthIsFallback(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"500\" height=\"100\"><style>" +
            "@media (min-width: 400px) { rect { fill: red } }</style>" +
            "<rect width=\"500\" height=\"100\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m5CenterColor(bitmap) == "#ff0000")
    }

    /** 根与选项都缺省时用 300：400px 查询不命中，输出仍为 300×150。 */
    @TestCase
    public func defaultRenderWidth(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "@media (min-width: 400px) { rect { fill: red } }</style>" +
            "<rect width=\"300\" height=\"150\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(bitmap.width == 300)
        @Assert(bitmap.height == 150)
        @Assert(m5CenterColor(bitmap) != "#ff0000")
    }

    /** 单元素渲染直接使用传入宽度。 */
    @TestCase
    public func elementRenderUsesWidth(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>" +
            "@media (max-width: 250px) { rect { fill: red } }</style>" +
            "<rect width=\"200\" height=\"100\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(document.root, width: 200, height: 100)
        @Assert(m5CenterColor(bitmap) == "#ff0000")
        let wider = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(document.root, width: 300, height: 100)
        @Assert(m5CenterColor(wider) != "#ff0000")
    }
}
