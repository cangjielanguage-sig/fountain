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
import stdx.encoding.base64.*

private class M4MemoryProvider <: SvgImageResourceProvider {
    let bytes: Array<Byte>
    var calls: Int64 = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func resolve(href: String): ?Array<Byte> {
        this.calls++
        Some(this.bytes)
    }
}

private func m4SamplePng(width: Int64, height: Int64, color: SvgColor): Array<Byte> {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(color)
    bitmap.toPngBytes()
}

private func m4MeanChannel(buffer: SvgFilterBuffer, channel: Int64): Float64 {
    var total: Int64 = 0
    var count: Int64 = 0
    var index = 0
    while (index < buffer.pixels.size) {
        total += Int64(buffer.pixels[index + channel])
        count++
        index += 4
    }
    Float64(total) / Float64(count)
}

@Test
public class SvgFilterNoiseM4_test {
    /** 湍流确定性、两类噪声差异、seed 影响、倍频上限。 */
    @TestCase
    public func turbulence(): Unit {
        let input = m4Buffer(8, 8, SvgColor.Black)
        let warnings = ArrayList<String>()

        let turbulence = SvgFeTurbulence()
        turbulence.baseFrequency = SvgNumberList([0.1, 0.1])
        turbulence.numOctaves = 3
        turbulence.seed = 3.0
        let first = turbulenceFilterBuffer(input, turbulence, 1.0, 1.0, warnings)
        let second = turbulenceFilterBuffer(input, turbulence, 1.0, 1.0, warnings)
        @Assert(m4BuffersEqual(first, second))
        @Assert(m4AlphaAt(first, 0, 0) == 255)

        let fractal = SvgFeTurbulence()
        fractal.turbulenceType = SvgTurbulenceType.FractalNoise
        fractal.baseFrequency = SvgNumberList([0.1])
        fractal.numOctaves = 3
        fractal.seed = 3.0
        let fractalResult = turbulenceFilterBuffer(input, fractal, 1.0, 1.0, warnings)
        @Assert(!m4BuffersEqual(first, fractalResult))
        @Assert(m4MeanChannel(first, 0) < m4MeanChannel(fractalResult, 0))

        let seeded = SvgFeTurbulence()
        seeded.baseFrequency = SvgNumberList([0.1])
        seeded.numOctaves = 3
        seeded.seed = 99.0
        @Assert(!m4BuffersEqual(first, turbulenceFilterBuffer(input, seeded, 1.0, 1.0, warnings)))

        let tooMany = SvgFeTurbulence()
        tooMany.numOctaves = 9
        let error = expectSvgException({=> turbulenceFilterBuffer(input, tooMany, 1.0, 1.0, warnings)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 位移：scale=0 直通、通道位移、越界透明。 */
    @TestCase
    public func displacement(): Unit {
        let input = m4TransparentBuffer(9, 3)
        m4FillRect(input, 2, 0, 3, 3, SvgColor.fromRgb(0, 255, 0))
        let warnings = ArrayList<String>()

        let zero = SvgFeDisplacementMap()
        @Assert(m4BuffersEqual(input, displacementFilterBuffer(input, input, zero, 1.0, 1.0, warnings)))

        let shifted = SvgFeDisplacementMap()
        shifted.scale = 10.0
        shifted.xChannelSelector = SvgChannelSelector.R
        shifted.yChannelSelector = SvgChannelSelector.G
        let map = m4TransparentBuffer(9, 3)
        m4FillRect(map, 0, 0, 9, 3, SvgColor.fromRgb(255, 128, 0))
        let result = displacementFilterBuffer(input, map, shifted, 1.0, 1.0, warnings)
        @Assert(m4AlphaAt(result, 0, 1) == 0)
        @Assert(m4AlphaAt(result, 7, 1) > 0)
        @Assert(m4AlphaAt(result, 8, 1) > 0)

        let nonFinite = SvgFeDisplacementMap()
        nonFinite.setAttr("scale", "nan")
        let nanWarnings = ArrayList<String>()
        @Assert(m4BuffersEqual(
            input,
            displacementFilterBuffer(input, map, nonFinite, 1.0, 1.0, nanWarnings)
        ))
        @Assert(nanWarnings.size > 0)
        @Assert(nanWarnings[0].contains("scale"))
    }

    /** feImage：provider、data URI、不可用、缺 href、单次解码、映射。 */
    @TestCase
    public func feImage(): Unit {
        let png = m4SamplePng(2, 1, SvgColor.fromRgb(255, 0, 0))
        let provider = M4MemoryProvider(png)
        let images = SvgImageResource(
            provider: Some(provider),
            budget: SvgDecodeBudget(1024 * 1024)
        )
        let warnings = ArrayList<String>()
        let input = m4TransparentBuffer(10, 10)

        let image = SvgFeImage()
        image.href = "mem://tex"
        let mapped = feImageFilterBuffer(input, image, images, warnings)
        @Assert(m4AlphaAt(mapped, 5, 5) > 0)
        @Assert(m4ChannelAt(mapped, 5, 5, 0) > 200)
        @Assert(m4AlphaAt(mapped, 0, 0) == 0)

        // 同一 href 只解码一次。
        let again = feImageFilterBuffer(input, image, images, warnings)
        @Assert(m4BuffersEqual(mapped, again))
        @Assert(provider.calls == 1)

        let stretch = SvgFeImage()
        stretch.href = "mem://tex"
        stretch.preserveAspectRatio = tryParseSvgPreserveAspectRatio("none").getOrThrow()
        let stretched = feImageFilterBuffer(input, stretch, images, warnings)
        @Assert(m4AlphaAt(stretched, 0, 0) > 0)
        @Assert(m4ChannelAt(stretched, 0, 0, 0) > 200)

        let meet = SvgFeImage()
        meet.href = "mem://tex"
        meet.preserveAspectRatio = tryParseSvgPreserveAspectRatio("xMidYMid meet").getOrThrow()
        let met = feImageFilterBuffer(input, meet, images, warnings)
        @Assert(m4AlphaAt(met, 0, 0) == 0)
        @Assert(m4AlphaAt(met, 5, 5) > 0)

        let slice = SvgFeImage()
        slice.href = "mem://tex"
        slice.preserveAspectRatio = tryParseSvgPreserveAspectRatio("xMidYMid slice").getOrThrow()
        let sliced = feImageFilterBuffer(input, slice, images, warnings)
        @Assert(m4AlphaAt(sliced, 0, 0) > 0)
        @Assert(m4AlphaAt(sliced, 0, 5) > 0)

        let missing = SvgFeImage()
        let missingWarnings = ArrayList<String>()
        @Assert(m4AlphaAt(feImageFilterBuffer(input, missing, images, missingWarnings), 5, 5) == 0)
        @Assert(missingWarnings.size > 0)
        @Assert(missingWarnings[0].contains("href"))

        let unavailable = SvgFeImage()
        unavailable.href = "mem://missing"
        let emptyImages = SvgImageResource(budget: SvgDecodeBudget(1024 * 1024))
        let unavailableWarnings = ArrayList<String>()
        @Assert(m4AlphaAt(
            feImageFilterBuffer(input, unavailable, emptyImages, unavailableWarnings), 5, 5) == 0)
        @Assert(unavailableWarnings.size > 0)
    }

    /** data URI 与共享解码预算超限。 */
    @TestCase
    public func feImageDataAndBudget(): Unit {
        let png = m4SamplePng(2, 2, SvgColor.fromRgb(0, 0, 255))
        let data = "data:image/png;base64," + toBase64String(png)
        let images = SvgImageResource(budget: SvgDecodeBudget(1024 * 1024))
        let warnings = ArrayList<String>()
        let input = m4TransparentBuffer(4, 4)
        let image = SvgFeImage()
        image.href = data
        let result = feImageFilterBuffer(input, image, images, warnings)
        @Assert(m4AlphaAt(result, 2, 2) > 0)
        @Assert(m4ChannelAt(result, 2, 2, 2) > 200)

        let tinyBudget = SvgImageResource(budget: SvgDecodeBudget(1))
        let budgetImage = SvgFeImage()
        budgetImage.href = data
        let error = expectSvgException({=>
            feImageFilterBuffer(input, budgetImage, tinyBudget, ArrayList<String>())
        })
        @Assert(error.kind == SvgErrorKind.Limit)

        // <image> 与 feImage 共用同一个 SvgImageResource：先解码 4 像素，
        // 再用不同 href 解码 4 像素时累计超限。
        let sharedData = "data:image/png;base64," + toBase64String(png)
        let otherPng = m4SamplePng(2, 2, SvgColor.fromRgb(255, 0, 0))
        let otherData = "data:image/png;base64," + toBase64String(otherPng)
        let shared = SvgImageResource(budget: SvgDecodeBudget(4))
        @Assert(shared.load(sharedData).isSome())
        let sharedImage = SvgFeImage()
        sharedImage.href = otherData
        let sharedError = expectSvgException({=>
            feImageFilterBuffer(input, sharedImage, shared, ArrayList<String>())
        })
        @Assert(sharedError.kind == SvgErrorKind.Limit)

        let oversized = expectSvgException({=>
            images.loadDataUri(data, maxBase64Length: 4)
        })
        @Assert(oversized.kind == SvgErrorKind.Limit)
    }

    /** 单次渲染内 `<image>` 与 `feImage` 共用同一个解码预算。 */
    @TestCase
    public func sharedBudgetWithinSingleRender(): Unit {
        let firstData = "data:image/png;base64," + toBase64String(
            m4SamplePng(2, 2, SvgColor.fromRgb(0, 0, 255))
        )
        let secondData = "data:image/png;base64," + toBase64String(
            m4SamplePng(2, 2, SvgColor.fromRgb(255, 0, 0))
        )
        let document = svgDoc(
            '<image x="0" y="0" width="4" height="4" href="${firstData}"/>' +
            '<filter id="f"><feImage href="${secondData}"/></filter>' +
            '<rect x="0" y="0" width="4" height="4" fill="red" filter="url(#f)"/>',
            width: 8,
            height: 8
        )
        let images = SvgImageResource(budget: SvgDecodeBudget(4))
        let renderer = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1),
            sessionImages: images,
            sessionGuard: SvgRenderGuard()
        )
        let error = expectSvgException({=> renderer.render(document)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}
