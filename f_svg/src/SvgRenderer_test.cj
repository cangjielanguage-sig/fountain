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
public class SvgRenderer_test {
    /** render(document) 与背景填充。 */
    @TestCase
    public func renderDocument(): Unit {
        let document = svgDoc('<rect width="10" height="10" fill="red"/>', width: 10, height: 10)
        let bitmap = SvgRenderer().render(document)
        @Assert(bitmap.width == 10 && bitmap.height == 10)
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))

        let partial = svgDoc('<rect width="5" height="5" fill="blue"/>', width: 10, height: 10)
        let withBackground = SvgRenderer(
            options: SvgRenderOptions(background: SvgColor.fromRgb(0, 255, 0))
        ).render(partial)
        @Assert(colorNear(withBackground.pixel(2, 2), SvgColor.fromRgb(0, 0, 255)))
        @Assert(colorNear(withBackground.pixel(8, 8), SvgColor.fromRgb(0, 255, 0)))
    }

    /** render(element, width, height) 以元素自身为根。 */
    @TestCase
    public func renderElement(): Unit {
        let document = svgDoc('<rect width="5" height="5" fill="blue"/>', width: 20, height: 20)
        let rect = document.elementsByTag("rect")[0]
        let bitmap = SvgRenderer().render(rect, width: 10, height: 10)
        @Assert(bitmap.width == 10 && bitmap.height == 10)
        @Assert(colorNear(bitmap.pixel(0, 0), SvgColor.fromRgb(0, 0, 255)))
        @Assert(bitmap.pixel(8, 8).alpha == 0.0)
    }

    /** 同文档连续两次渲染逐字节一致。 */
    @TestCase
    public func deterministicRendering(): Unit {
        let document = svgDoc(
            '<rect width="8" height="8" fill="#123456"/>' +
            '<circle cx="6" cy="6" r="2" fill="red" opacity="0.5"/>',
            width: 10,
            height: 10
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 2))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels.size == second.pixels.size)
        for (index in 0..first.pixels.size) {
            @Assert(first.pixels[index] == second.pixels[index])
        }
    }

    /** renderToPng 输出合法 PNG 签名，方法入口与顶层入口一致。 */
    @TestCase
    public func renderToPngEntry(): Unit {
        let document = svgDoc('<rect width="10" height="10" fill="red"/>', width: 10, height: 10)
        let bytes = SvgRenderer().renderToPng(document)
        @Assert(bytes.size > 8)
        @Assert(bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47)
        let topLevel = renderToPng(document)
        @Assert(bytes == topLevel)
    }

    /** 高 DPI、无尺寸根元素与 visibility 覆盖。 */
    @TestCase
    public func viewportAndVisibility(): Unit {
        let document = svgDoc('<rect width="5" height="5" fill="blue"/>', width: 10, height: 10)
        let highDpi = SvgRenderer(
            options: SvgRenderOptions(width: 10, height: 10, devicePixelRatio: 2.0)
        ).render(document)
        @Assert(highDpi.width == 20 && highDpi.height == 20)
        @Assert(colorNear(highDpi.pixel(9, 9), SvgColor.fromRgb(0, 0, 255)))
        @Assert(highDpi.pixel(12, 12).alpha == 0.0)

        let noSize = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10" fill="red"/></svg>'
        )
        let defaultBitmap = SvgRenderer().render(noSize)
        @Assert(defaultBitmap.width == 300 && defaultBitmap.height == 150)

        let hidden = svgDoc(
            '<g visibility="hidden"><rect width="10" height="10" visibility="visible" fill="red"/></g>',
            width: 10,
            height: 10
        )
        let hiddenBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(hidden)
        @Assert(colorNear(hiddenBitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
    }

    /** 渐变、裁剪与文本在渲染管线中生效。 */
    @TestCase
    public func paintAndClipPipeline(): Unit {
        let gradientDoc = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">' +
            '<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="10" y2="0">' +
            '<stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/>' +
            '</linearGradient></defs>' +
            '<rect width="10" height="10" fill="url(#g)"/></svg>'
        )
        let gradientBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(gradientDoc)
        let left = gradientBitmap.pixel(0, 5)
        let right = gradientBitmap.pixel(9, 5)
        @Assert(left.red > 240 && left.blue < 20)
        @Assert(right.blue > 240 && right.red < 20)

        let clipDoc = svgDoc(
            '<defs><clipPath id="c"><rect x="5" y="5" width="5" height="5"/></clipPath></defs>' +
            '<rect width="10" height="10" fill="red" clip-path="url(#c)"/>',
            width: 10,
            height: 10
        )
        let clipBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(clipDoc)
        @Assert(clipBitmap.pixel(2, 2).alpha == 0.0)
        @Assert(colorNear(clipBitmap.pixel(7, 7), SvgColor.fromRgb(255, 0, 0)))

        let styledClipDoc = svgDoc(
            '<defs><clipPath id="c"><rect x="5" y="5" width="5" height="5"/></clipPath></defs>' +
            '<rect width="10" height="10" fill="red" style="clip-path: url(#c)"/>',
            width: 10,
            height: 10
        )
        let styledClip = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(styledClipDoc)
        @Assert(styledClip.pixel(2, 2).alpha == 0.0)
        @Assert(colorNear(styledClip.pixel(7, 7), SvgColor.fromRgb(255, 0, 0)))

        let textDoc = svgDoc(
            '<text x="2" y="10" font-family="Hershey" font-size="10" fill="black">AB</text>',
            width: 30,
            height: 20
        )
        let textBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(textDoc)
        var textPixels = 0
        for (y in 0..textBitmap.height) {
            for (x in 0..textBitmap.width) {
                if (textBitmap.pixel(x, y).alpha > 0.0) {
                    textPixels++
                }
            }
        }
        @Assert(textPixels > 5)
    }
}
