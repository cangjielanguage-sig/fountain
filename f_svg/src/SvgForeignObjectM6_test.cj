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

class M6ForeignSolidRenderer <: SvgForeignObjectRenderer {
    let bitmap: ?SvgBitmap
    var calls: Int64 = 0
    var lastWidth: Float64 = 0.0
    var lastHeight: Float64 = 0.0

    init(bitmap!: ?SvgBitmap = None) {
        this.bitmap = bitmap
    }

    public func render(
        element: SvgElement,
        width: Float64,
        height: Float64,
        options: SvgRenderOptions
    ): ?SvgBitmap {
        this.calls++
        this.lastWidth = width
        this.lastHeight = height
        this.bitmap
    }
}

@Test
public class SvgForeignObjectM6_test {
    private func solid(width: Int64, height: Int64, color: SvgColor): SvgBitmap {
        let bitmap = SvgBitmap(width, height)
        bitmap.fill(color)
        bitmap
    }

    private func documentOf(inner: String): SvgDocument {
        SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<foreignObject x=\"0\" y=\"0\" width=\"10\" height=\"10\">" + inner + "</foreignObject></svg>"
        )
    }

    /** 注入位图按 x/y/width/height 绘制。 */
    @TestCase
    public func injectedBitmapRenders(): Unit {
        let renderer = M6ForeignSolidRenderer(bitmap: Some(solid(2, 2, SvgColor(255, 0, 0))))
        let document = documentOf("<div xmlns=\"http://www.w3.org/1999/xhtml\">x</div>")
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, foreignObjectRenderer: renderer)
        ).render(document)
        @Assert(renderer.calls == 1)
        @Assert(renderer.lastWidth == 10.0)
        @Assert(renderer.lastHeight == 10.0)
        @Assert(bitmap.pixel(5, 5).toString() == "#ff0000")
        @Assert(bitmap.pixel(15, 15).toString() == "#00000000")
    }

    /** 未提供 renderer：透明占位 + warning。 */
    @TestCase
    public func missingRendererIsTransparent(): Unit {
        let document = documentOf("")
        let renderer = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20))
        let bitmap = renderer.render(document)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("foreignObject")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** renderer 返回 None：透明占位 + warning。 */
    @TestCase
    public func noneResultIsTransparent(): Unit {
        let renderer = M6ForeignSolidRenderer(bitmap: Option<SvgBitmap>.None)
        let document = documentOf("")
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, foreignObjectRenderer: renderer)
        )
        let bitmap = rendered.render(document)
        @Assert(renderer.calls == 1)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("foreignObject")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 缺尺寸时不调用 renderer，透明 + warning。 */
    @TestCase
    public func missingSizeIsTransparent(): Unit {
        let renderer = M6ForeignSolidRenderer(bitmap: Some(solid(1, 1, SvgColor(255, 0, 0))))
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<foreignObject x=\"0\" y=\"0\" width=\"0\" height=\"10\"/></svg>"
        )
        let rendered = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, foreignObjectRenderer: renderer)
        )
        let bitmap = rendered.render(document)
        @Assert(renderer.calls == 0)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
        var warned = false
        for (warning in rendered.warnings) {
            if (warning.contains("foreignObject")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 不遍历 XHTML 子节点。 */
    @TestCase
    public func xhtmlChildrenNotTraversed(): Unit {
        let document = documentOf("<rect width=\"10\" height=\"10\" fill=\"red\"/>")
        let bitmap = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20)).render(document)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
    }
}
