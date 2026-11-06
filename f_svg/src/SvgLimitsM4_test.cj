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
import stdx.encoding.base64.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgLimitsM4_test {
    /** M4 上限：卷积、湍流、TTF、feImage 均抛 Limit。 */
    @TestCase
    public func limits(): Unit {
        let buffer = m4Buffer(2, 2, SvgColor.White)
        let warnings = ArrayList<String>()

        let convolve = SvgFeConvolveMatrix()
        convolve.order = SvgNumberList([9.0, 10.0])
        @Assert(expectSvgException({=> convolveFilterBuffer(buffer, convolve, warnings)}).kind ==
            SvgErrorKind.Limit)

        let turbulence = SvgFeTurbulence()
        turbulence.numOctaves = 9
        @Assert(expectSvgException({=> turbulenceFilterBuffer(buffer, turbulence, 1.0, 1.0, warnings)}).kind ==
            SvgErrorKind.Limit)

        let tooManyTables = m4BuildTtf()
        tooManyTables[4] = 0
        tooManyTables[5] = 65
        @Assert(expectSvgException({=> SvgTtfTableDirectory.parse(tooManyTables)}).kind ==
            SvgErrorKind.Limit)

        let points = m4BuildTtf()
        let directory = SvgTtfTableDirectory.parse(points)
        let glyf = directory.table("glyf").getOrThrow()
        points[glyf.offset + 10] = 0x27
        points[glyf.offset + 11] = 0x10
        let font = SvgTrueTypeFont.parse(points)
        @Assert(expectSvgException({=> font.glyphPath(65, 1000.0)}).kind == SvgErrorKind.Limit)

        let budgetImage = SvgFeImage()
        budgetImage.href = "data:image/png;base64," + toBase64String(
            m4SamplePngForLimits(2, 2)
        )
        let resource = SvgImageResource(budget: SvgDecodeBudget(1))
        @Assert(expectSvgException({=>
            feImageFilterBuffer(buffer, budgetImage, resource, warnings)
        }).kind == SvgErrorKind.Limit)
    }

    /** M4 warning 含属性名或元素路径，且 Renderer / Document 均累积。 */
    @TestCase
    public func warningAudit(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<rect width=\"5\" height=\"5\" clip=\"rect(1,2)\" vector-effect=\"scaling-stroke\"/>" +
            "<filter id=\"f\"><feImage/></filter></svg>"
        )
        var missingHref = false
        for (warning in document.warnings) {
            if (warning.contains("feImage") && warning.contains("href")) {
                missingHref = true
            }
        }
        @Assert(missingHref)

        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        renderer.render(document)
        var clipWarning = false
        var vectorWarning = false
        for (warning in renderer.warnings) {
            if (warning.contains("clip")) {
                clipWarning = true
            }
            if (warning.contains("vector-effect")) {
                vectorWarning = true
            }
        }
        @Assert(clipWarning)
        @Assert(vectorWarning)

        let before = renderer.warnings.size
        renderer.render(document)
        @Assert(renderer.warnings.size >= before)
    }
}

private func m4SamplePngForLimits(width: Int64, height: Int64): Array<Byte> {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(SvgColor.White)
    bitmap.toPngBytes()
}
