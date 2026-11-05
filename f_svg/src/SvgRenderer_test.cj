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

        let fractional = SvgRenderer(
            options: SvgRenderOptions(width: 101, height: 101, devicePixelRatio: 1.1, samplesPerPixel: 1)
        ).render(document)
        @Assert(fractional.width == 112 && fractional.height == 112)

        let hidden = svgDoc(
            '<g visibility="hidden"><rect width="10" height="10" visibility="visible" fill="red"/></g>',
            width: 10,
            height: 10
        )
        let hiddenBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(hidden)
        @Assert(colorNear(hiddenBitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
    }

    /** 渲染入口的 maxPixels、外部图片与定义容器端到端行为。 */
    @TestCase
    public func renderSecurityAndDefinitionContainers(): Unit {
        let big = svgDoc('<rect width="1000" height="1000" fill="red"/>', width: 1000, height: 1000)
        let pixelsError = expectSvgException({=>
            SvgRenderer(options: SvgRenderOptions(maxPixels: 100)).render(big)
        })
        @Assert(pixelsError.kind == SvgErrorKind.Limit)

        let externalImage = svgDoc(
            '<image href="file:///etc/passwd" x="2" y="2" width="6" height="6"/>',
            width: 10,
            height: 10
        )
        let imageRenderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let imageBitmap = imageRenderer.render(externalImage)
        @Assert(imageBitmap.pixel(5, 5).alpha == 0.0)
        var imageWarning = false
        for (warning in imageRenderer.warnings) {
            if (warning.contains("image")) {
                imageWarning = true
            }
        }
        @Assert(imageWarning)

        let defsOnly = svgDoc(
            '<defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient>' +
            '<clipPath id="c"><rect width="10" height="10"/></clipPath>' +
            '<symbol id="s"><rect width="10" height="10"/></symbol></defs>',
            width: 10,
            height: 10
        )
        let defsBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(defsOnly)
        for (y in 0..defsBitmap.height) {
            for (x in 0..defsBitmap.width) {
                @Assert(defsBitmap.pixel(x, y).alpha == 0.0)
            }
        }
    }

    /** 单元素渲染不继承真实祖先样式。 */
    @TestCase
    public func renderElementDoesNotInheritAncestors(): Unit {
        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">' +
            '<g fill="red"><rect id="r" width="10" height="10"/></g></svg>'
        )
        let rect = document.elementsByTag("rect")[0]
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            rect,
            width: 20,
            height: 20
        )
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.Black))
    }

    /** 不同 samplesPerPixel 下各自重复渲染一致。 */
    @TestCase
    public func sampleCountDeterminism(): Unit {
        let document = svgDoc(
            '<rect width="8" height="8" fill="#123456"/>' +
            '<circle cx="6" cy="6" r="2" fill="red" opacity="0.5"/>',
            width: 10,
            height: 10
        )
        for (samples in [1, 2, 4]) {
            let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: samples))
            let first = renderer.render(document)
            let second = renderer.render(document)
            @Assert(first.pixels.size == second.pixels.size)
            for (index in 0..first.pixels.size) {
                @Assert(first.pixels[index] == second.pixels[index])
            }
        }
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

@Test
public class SvgImageRenderM3_test {
    /** data URI 直接绘制，且不再产生占位 warning。 */
    @TestCase
    public func dataUriDrawn(): Unit {
        let uri = m3PngDataUri(m3RedPng(1, 1))
        let document = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>",
            width: 10,
            height: 10
        )
        let renderer = SvgRenderer()
        let bitmap = renderer.render(document)
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        for (warning in renderer.warnings) {
            @Assert(!warning.contains("<image>"))
        }
    }

    /** provider 绘制，同一 render 内按 href 只解码一次，跨 render 不共享。 */
    @TestCase
    public func providerDrawnAndCached(): Unit {
        let provider = M3CountingProvider(m3RedPng(4, 4))
        let document = m3KeepDoc(
            "<image href=\"mem://red\" x=\"0\" y=\"0\" width=\"5\" height=\"5\"/>" +
            "<image href=\"mem://red\" x=\"5\" y=\"0\" width=\"5\" height=\"5\"/>",
            width: 10,
            height: 5
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(images: Some(provider)))
        let bitmap = renderer.render(document)
        @Assert(colorNear(bitmap.pixel(2, 2), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(bitmap.pixel(7, 2), SvgColor.fromRgb(255, 0, 0)))
        @Assert(provider.calls == 1)
        renderer.render(document)
        @Assert(provider.calls == 2)
    }

    /** 未注入 provider：透明占位 + warning。 */
    @TestCase
    public func missingProviderPlaceholder(): Unit {
        let document = m3KeepDoc(
            "<image href=\"mem://red\" x=\"0\" y=\"0\" width=\"10\" height=\"10\"/>",
            width: 10,
            height: 10
        )
        let renderer = SvgRenderer()
        let bitmap = renderer.render(document)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("image")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** preserveAspectRatio 三档映射。 */
    @TestCase
    public func preserveAspectRatioModes(): Unit {
        let uri = m3PngDataUri(m3RedPng(100, 50))

        let meet = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"50\" height=\"50\" " +
            "preserveAspectRatio=\"xMidYMid meet\"/>",
            width: 50,
            height: 50
        )
        let meetBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(meet)
        @Assert(meetBitmap.pixel(25, 0).alpha == 0.0)
        @Assert(colorNear(meetBitmap.pixel(25, 25), SvgColor.fromRgb(255, 0, 0)))
        @Assert(meetBitmap.pixel(25, 49).alpha == 0.0)

        let slice = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"50\" height=\"50\" " +
            "preserveAspectRatio=\"xMidYMid slice\"/>",
            width: 50,
            height: 50
        )
        let sliceBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(slice)
        @Assert(colorNear(sliceBitmap.pixel(0, 25), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sliceBitmap.pixel(49, 25), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(sliceBitmap.pixel(25, 0), SvgColor.fromRgb(255, 0, 0)))
    }

    /** image-rendering：pixelated 走最近邻，auto 走双线性。 */
    @TestCase
    public func imageRenderingModes(): Unit {
        let bitmap = SvgBitmap(2, 1)
        bitmap.setPixel(0, 0, SvgColor.fromRgb(255, 0, 0))
        bitmap.setPixel(1, 0, SvgColor.fromRgb(0, 0, 255))
        let uri = m3PngDataUri(bitmap.toPngBytes())

        let nearest = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"40\" height=\"10\" " +
            "preserveAspectRatio=\"none\" image-rendering=\"pixelated\"/>",
            width: 40,
            height: 10
        )
        let nearestBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(nearest)
        @Assert(colorNear(nearestBitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(nearestBitmap.pixel(35, 5), SvgColor.fromRgb(0, 0, 255)))

        let smooth = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"40\" height=\"10\" " +
            "preserveAspectRatio=\"none\"/>",
            width: 40,
            height: 10
        )
        let smoothBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(smooth)
        let mixed = smoothBitmap.pixel(19, 5)
        @Assert(mixed.red > 0 && mixed.blue > 0)
    }

    /** opacity 与 clipPath 对 image 生效。 */
    @TestCase
    public func opacityAndClip(): Unit {
        let uri = m3PngDataUri(m3RedPng(4, 4))
        let translucent = svgDoc(
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"10\" height=\"10\" opacity=\"0.5\"/>",
            width: 10,
            height: 10
        )
        let faded = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(translucent)
        let pixel = faded.pixel(5, 5)
        @Assert(pixel.alpha > 0.4 && pixel.alpha < 0.6)

        let clipped = svgDoc(
            "<defs><clipPath id=\"c\"><rect x=\"0\" y=\"0\" width=\"5\" height=\"10\"/></clipPath></defs>" +
            "<image href=\"${uri}\" x=\"0\" y=\"0\" width=\"10\" height=\"10\" clip-path=\"url(#c)\"/>",
            width: 10,
            height: 10
        )
        let clippedBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(clipped)
        @Assert(colorNear(clippedBitmap.pixel(2, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(clippedBitmap.pixel(8, 5).alpha == 0.0)
    }
}

@Test
public class SvgFilterRenderM3_test {
    /** 缺失 filter 引用：按无滤镜渲染并 warning。 */
    @TestCase
    public func missingFilterReference(): Unit {
        let document = svgDoc(
            "<rect width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#none)\"/>",
            width: 10,
            height: 10
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("filter") || warning.contains("none")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 空滤镜链输出与无滤镜逐字节一致。 */
    @TestCase
    public func emptyFilterMatchesUnfiltered(): Unit {
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc("<rect width=\"10\" height=\"10\" fill=\"red\"/>", width: 10, height: 10)
        )
        let filtered = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(
            svgDoc(
                "<defs><filter id=\"f\"/></defs>" +
                "<rect width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#f)\"/>",
                width: 10,
                height: 10
            )
        )
        @Assert(plain.pixels == filtered.pixels)
    }
}


@Test
public class SvgRenderReadOnlyM3_test {
    /** 渲染 pattern / marker / filter 两次不修改文档。 */
    @TestCase
    public func documentReadOnly(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><pattern id=\"p\" width=\"6\" height=\"6\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"6\" height=\"6\" fill=\"red\"/></pattern>" +
            "<filter id=\"f\"><feOffset dx=\"1\" dy=\"1\"/></filter>" +
            "<marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<rect width=\"4\" height=\"4\" fill=\"blue\"/></marker></defs>" +
            "<line x1=\"2\" y1=\"2\" x2=\"20\" y2=\"2\" stroke=\"url(#p)\" " +
            "marker-end=\"url(#m)\" filter=\"url(#f)\"/></svg>"
        )
        let before = documentSnapshot(document)
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        renderer.render(document)
        renderer.render(document)
        @Assert(documentSnapshot(document) == before)
    }
}
