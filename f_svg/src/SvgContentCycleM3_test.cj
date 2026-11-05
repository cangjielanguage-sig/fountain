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
public class SvgContentCycleM3_test {
    /** pattern 内容引用自身：渲染完成并记循环 warning。 */
    @TestCase
    public func patternContentCycle(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#p)\"/></pattern></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#p)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(bitmap.width == 20 && bitmap.height == 20)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** marker 内容再次引用同一 marker：停止展开并 warning。 */
    @TestCase
    public func markerContentCycle(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<line x1=\"0\" y1=\"0\" x2=\"4\" y2=\"0\" stroke=\"red\" marker-end=\"url(#m)\"/>" +
            "</marker></defs>" +
            "<line x1=\"5\" y1=\"5\" x2=\"25\" y2=\"5\" stroke=\"black\" marker-end=\"url(#m)\"/>" +
            "</svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(bitmap.width == 30 && bitmap.height == 30)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 直接调用公开 sampler 渲染自引用 pattern：完成 + warning，不无限递归。 */
    @TestCase
    public func publicSamplerContentCycle(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#p)\"/></pattern></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#p)\"/></svg>"
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern").getOrThrow() as
            SvgPattern).getOrThrow()
        let sampler = SvgPatternSampler(root: Some(document.root))
        let tile = sampler.sample(
            pattern,
            SvgBounds(0.0, 0.0, 20.0, 20.0),
            SvgMatrix.identity,
            SvgRenderOptions(samplesPerPixel: 1)
        )
        @Assert(tile.isNone())
        var found = false
        for (warning in sampler.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 直接调用公开 sampler 的 65 层合法链仍抛 Limit。 */
    @TestCase
    public func publicSamplerDepthLimit(): Unit {
        let document = SvgParser.parse(patternChainSvg(70))
        let pattern = (document.root.child("defs").getOrThrow().child("pattern").getOrThrow() as
            SvgPattern).getOrThrow()
        let sampler = SvgPatternSampler(root: Some(document.root))
        let error = expectSvgException(
            {
                => sampler.sample(
                    pattern,
                    SvgBounds(0.0, 0.0, 20.0, 20.0),
                    SvgMatrix.identity,
                    SvgRenderOptions(samplesPerPixel: 1)
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 直接调用公开 builder 渲染自引用 marker：完成 + warning。 */
    @TestCase
    public func publicBuilderContentCycle(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<defs><marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<line x1=\"0\" y1=\"0\" x2=\"4\" y2=\"0\" stroke=\"red\" marker-end=\"url(#m)\"/>" +
            "</marker></defs>" +
            "<line x1=\"5\" y1=\"5\" x2=\"25\" y2=\"5\" stroke=\"black\" marker-end=\"url(#m)\"/>" +
            "</svg>"
        )
        let builder = SvgRenderTreeBuilder()
        let list = builder.build(document)
        @Assert(list.commands.size > 0)
        var found = false
        for (warning in builder.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 直接调用公开 builder 的 65 层 marker 链抛 Limit。 */
    @TestCase
    public func publicBuilderDepthLimit(): Unit {
        let document = SvgParser.parse(markerChainSvg(70))
        let builder = SvgRenderTreeBuilder()
        let error = expectSvgException({=> builder.build(document)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 一次 Limit 之后复用同一 renderer：不残留引用栈、不误报循环或深度上限。 */
    @TestCase
    public func guardRecoversAfterLimit(): Unit {
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let deep = SvgParser.parse(patternChainSvg(70))
        let error = expectSvgException({=> renderer.render(deep)})
        @Assert(error.kind == SvgErrorKind.Limit)

        let normal = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><pattern id=\"p\" width=\"5\" height=\"5\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"5\" height=\"5\" fill=\"red\"/></pattern></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#p)\"/></svg>"
        )
        let bitmap = renderer.render(normal)
        @Assert(bitmap.width == 20 && bitmap.height == 20)
        @Assert(colorNear(bitmap.pixel(10, 10), SvgColor.fromRgb(255, 0, 0)))
        var cycleWarning = false
        for (warning in renderer.warnings) {
            if (warning.contains("循环")) {
                cycleWarning = true
            }
        }
        @Assert(!cycleWarning)
    }

    /** 非循环的内容嵌套超过 64 层抛 Limit。 */
    @TestCase
    public func contentDepthLimit(): Unit {
        let defs = StringBuilder("<defs>")
        for (index in 0..70) {
            defs.append(
                "<pattern id=\"p${index}\" width=\"4\" height=\"4\" " +
                "patternUnits=\"userSpaceOnUse\"><rect width=\"4\" height=\"4\" " +
                "fill=\"url(#p${index + 1})\"/></pattern>"
            )
        }
        defs.append(
            "<pattern id=\"p70\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"4\" height=\"4\" fill=\"red\"/></pattern></defs>"
        )
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            defs.toString() + "<rect width=\"20\" height=\"20\" fill=\"url(#p0)\"/></svg>"
        )
        let error = expectSvgException(
            {=> SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)}
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}

/** 构造 `depth` 层 pattern 链：p0 → p1 → ... → p{depth}，末层为实心。 */
private func patternChainSvg(depth: Int64): String {
    let defs = StringBuilder("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><defs>")
    for (index in 0..depth) {
        defs.append(
            "<pattern id=\"p${index}\" width=\"4\" height=\"4\" " +
            "patternUnits=\"userSpaceOnUse\"><rect width=\"4\" height=\"4\" " +
            "fill=\"url(#p${index + 1})\"/></pattern>"
        )
    }
    defs.append(
        "<pattern id=\"p${depth}\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\">" +
        "<rect width=\"4\" height=\"4\" fill=\"red\"/></pattern></defs>" +
        "<rect width=\"20\" height=\"20\" fill=\"url(#p0)\"/></svg>"
    )
    defs.toString()
}

/** 构造 `depth` 层 marker 链：m0 → m1 → ... → m{depth}，末层无 marker-end。 */
private func markerChainSvg(depth: Int64): String {
    let defs = StringBuilder("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\"><defs>")
    for (index in 0..depth) {
        defs.append(
            "<marker id=\"m${index}\" markerWidth=\"4\" markerHeight=\"4\">" +
            "<line x1=\"0\" y1=\"0\" x2=\"4\" y2=\"0\" stroke=\"red\" " +
            "marker-end=\"url(#m${index + 1})\"/></marker>"
        )
    }
    defs.append(
        "<marker id=\"m${depth}\" markerWidth=\"4\" markerHeight=\"4\">" +
        "<line x1=\"0\" y1=\"0\" x2=\"4\" y2=\"0\" stroke=\"red\"/></marker></defs>" +
        "<line x1=\"5\" y1=\"5\" x2=\"25\" y2=\"5\" stroke=\"black\" " +
        "marker-end=\"url(#m0)\"/></svg>"
    )
    defs.toString()
}
