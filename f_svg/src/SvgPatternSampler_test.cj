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

private func patternSamplerOf(document: SvgDocument): SvgPatternSampler {
    SvgPatternSampler(root: Some(document.root))
}

private func patternTransformDoc(transform: String): SvgDocument {
    SvgParser.parse(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"20\">" +
        "<defs><pattern id=\"p\" width=\"20\" height=\"20\" patternUnits=\"userSpaceOnUse\" " +
        transform + ">" +
        "<rect width=\"10\" height=\"20\" fill=\"red\"/>" +
        "<rect x=\"10\" width=\"10\" height=\"20\" fill=\"blue\"/>" +
        "</pattern></defs><rect width=\"80\" height=\"20\" fill=\"url(#p)\"/></svg>"
    )
}

@Test
public class SvgPatternSampler_test {
    /** 20×20 tile 平铺 100×100，周期正确。 */
    @TestCase
    public func tilePeriod(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"20\" height=\"20\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"20\" height=\"20\" fill=\"#FF0000\"/>" +
            "<rect width=\"10\" height=\"10\" fill=\"#0000FF\"/>" +
            "</pattern></defs>" +
            "<rect width=\"100\" height=\"100\" fill=\"url(#p)\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(0, 0, 255)))
        @Assert(colorNear(bitmap.pixel(15, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(bitmap.pixel(5, 15), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(bitmap.pixel(25, 25), SvgColor.fromRgb(0, 0, 255)))
        @Assert(colorNear(bitmap.pixel(95, 95), SvgColor.fromRgb(255, 0, 0)))
    }

    /** patternUnits 与 patternContentUnits 的尺寸换算。 */
    @TestCase
    public func unitsConversion(): Unit {
        let objectDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"0.5\" height=\"0.5\">" +
            "<rect width=\"1\" height=\"1\" fill=\"red\"/></pattern></defs></svg>"
        )
        let objectPattern = objectDocument.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern
        let objectTile = patternSamplerOf(objectDocument).sample(
            objectPattern.getOrThrow(),
            SvgBounds(0.0, 0.0, 100.0, 100.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        ).getOrThrow()
        @Assert(objectTile.width == 50 && objectTile.height == 50)

        let userDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"20\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"20\" height=\"10\" fill=\"red\"/></pattern></defs></svg>"
        )
        let userPattern = userDocument.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern
        let userTile = patternSamplerOf(userDocument).sample(
            userPattern.getOrThrow(),
            SvgBounds(0.0, 0.0, 100.0, 100.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        ).getOrThrow()
        @Assert(userTile.width == 20 && userTile.height == 10)

        let contentObjectDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"0.5\" height=\"0.5\" " +
            "patternContentUnits=\"objectBoundingBox\">" +
            "<rect width=\"1\" height=\"1\" fill=\"red\"/></pattern></defs>" +
            "<rect width=\"100\" height=\"100\" fill=\"url(#p)\"/></svg>"
        )
        let contentObjectBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(contentObjectDocument)
        @Assert(colorNear(contentObjectBitmap.pixel(25, 25), SvgColor.fromRgb(255, 0, 0)))

        let contentUserDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"0.5\" height=\"0.5\" " +
            "patternContentUnits=\"userSpaceOnUse\">" +
            "<rect width=\"1\" height=\"1\" fill=\"red\"/></pattern></defs>" +
            "<rect width=\"100\" height=\"100\" fill=\"url(#p)\"/></svg>"
        )
        let contentUserBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(contentUserDocument)
        @Assert(contentUserBitmap.pixel(25, 25).alpha == 0.0)
    }

    /** patternTransform 缩放改变周期，旋转改变方向。 */
    @TestCase
    public func patternTransform(): Unit {
        let plain = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(patternTransformDoc(""))
        @Assert(colorNear(plain.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(plain.pixel(25, 5), SvgColor.fromRgb(255, 0, 0)))

        let scaled = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(patternTransformDoc("patternTransform=\"scale(2)\""))
        @Assert(colorNear(scaled.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        @Assert(colorNear(scaled.pixel(25, 5), SvgColor.fromRgb(0, 0, 255)))

        let rotated = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(patternTransformDoc("patternTransform=\"rotate(45)\""))
        var differs = false
        for (x in 0..80) {
            for (y in 0..20) {
                if (!colorNear(rotated.pixel(x, y), plain.pixel(x, y))) {
                    differs = true
                }
            }
        }
        @Assert(differs)
    }

    /** href 继承、自身优先与循环引用。 */
    @TestCase
    public func hrefInheritance(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs>" +
            "<pattern id=\"a\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\"/></pattern>" +
            "<pattern id=\"b\" href=\"#a\" height=\"20\"/>" +
            "<pattern id=\"c\" href=\"#a\" width=\"30\"/>" +
            "</defs></svg>"
        )
        let defs = document.root.child("defs").getOrThrow()
        let sampler = patternSamplerOf(document)
        let inherited = sampler.sample(
            (defs.childrenOf("pattern")[1] as SvgPattern).getOrThrow(),
            SvgBounds(0.0, 0.0, 100.0, 100.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        ).getOrThrow()
        @Assert(inherited.width == 10 && inherited.height == 20)

        let own = sampler.sample(
            (defs.childrenOf("pattern")[2] as SvgPattern).getOrThrow(),
            SvgBounds(0.0, 0.0, 100.0, 100.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        ).getOrThrow()
        @Assert(own.width == 30 && own.height == 10)

        let cyclic = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><pattern id=\"a\" href=\"#b\" width=\"10\" height=\"10\"/>" +
            "<pattern id=\"b\" href=\"#a\" width=\"10\" height=\"10\"/></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#a)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        renderer.render(cyclic)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("循环")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 空 tile / 负尺寸 / 超大 tile。 */
    @TestCase
    public func tileLimits(): Unit {
        let emptyDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<defs><pattern id=\"p\" width=\"0\" height=\"10\"/></defs>" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#p)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let empty = renderer.render(emptyDocument)
        @Assert(empty.pixel(5, 5).alpha == 0.0)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("pattern")) {
                found = true
            }
        }
        @Assert(found)

        let negativeDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<defs><pattern id=\"p\" width=\"-5\" height=\"10\" patternUnits=\"userSpaceOnUse\"/></defs>" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#p)\"/></svg>"
        )
        let negative = (negativeDocument.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        @Assert(
            patternSamplerOf(negativeDocument).sample(
                negative,
                SvgBounds(0.0, 0.0, 10.0, 10.0),
                SvgMatrix.identity,
                SvgRenderOptions()
            ).isNone()
        )

        let hugeDocument = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<defs><pattern id=\"p\" width=\"3000\" height=\"3000\" patternUnits=\"userSpaceOnUse\"/></defs>" +
            "<rect width=\"10\" height=\"10\" fill=\"url(#p)\"/></svg>"
        )
        let huge = (hugeDocument.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        let error = expectSvgException(
            {=>
                patternSamplerOf(hugeDocument).sample(
                    huge,
                    SvgBounds(0.0, 0.0, 10.0, 10.0),
                    SvgMatrix.identity,
                    SvgRenderOptions()
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 图案裁剪到填充区域。 */
    @TestCase
    public func clippedToFillRegion(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"#FF0000\"/></pattern></defs>" +
            "<circle cx=\"20\" cy=\"20\" r=\"10\" fill=\"url(#p)\"/></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(bitmap.pixel(1, 1).alpha == 0.0)
        @Assert(colorNear(bitmap.pixel(20, 20), SvgColor.fromRgb(255, 0, 0)))
    }

    /** 图案子内容渲染失败降级。 */
    @TestCase
    public func contentFailureFallsBack(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">" +
            "<rect width=\"10\" height=\"10\" fill=\"red\" clip-path=\"url(#missing)\"/>" +
            "</pattern></defs>" +
            "<rect width=\"20\" height=\"20\" fill=\"url(#p)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(document)
        @Assert(bitmap.pixel(5, 5).alpha == 0.0)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("pattern") || warning.contains("引用")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 同一 sampler 连续两次 sample：每次按本次 options.images 解析资源。 */
    @TestCase
    public func sampleUsesEachCallProvider(): Unit {
        let document = m3KeepDoc(
            "<defs><pattern id=\"p\" width=\"2\" height=\"2\" patternUnits=\"userSpaceOnUse\">" +
            "<image href=\"mem://img\" width=\"2\" height=\"2\"/></pattern></defs>",
            width: 10,
            height: 10
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern").getOrThrow() as
            SvgPattern).getOrThrow()
        let blue = SvgBitmap(2, 2)
        blue.fill(SvgColor.fromRgb(0, 0, 255))
        let redProvider = M3CountingProvider(m3RedPng(2, 2))
        let blueProvider = M3CountingProvider(blue.toPngBytes())
        let sampler = SvgPatternSampler(root: Some(document.root))
        let bounds = SvgBounds(0.0, 0.0, 10.0, 10.0)
        let first = sampler.sample(
            pattern,
            bounds,
            SvgMatrix.identity,
            SvgRenderOptions(samplesPerPixel: 1, images: Some(redProvider))
        ).getOrThrow()
        @Assert(colorNear(first.pixel(0, 0), SvgColor.fromRgb(255, 0, 0)))
        let second = sampler.sample(
            pattern,
            bounds,
            SvgMatrix.identity,
            SvgRenderOptions(samplesPerPixel: 1, images: Some(blueProvider))
        ).getOrThrow()
        @Assert(colorNear(second.pixel(0, 0), SvgColor.fromRgb(0, 0, 255)))
    }

    /** 同一 provider 的同一 href 在一次 sample 内只解析一次。 */
    @TestCase
    public func sameProviderResolvesHrefOnce(): Unit {
        let document = m3KeepDoc(
            "<defs><pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\">" +
            "<image href=\"mem://img\" x=\"0\" y=\"0\" width=\"2\" height=\"2\"/>" +
            "<image href=\"mem://img\" x=\"2\" y=\"2\" width=\"2\" height=\"2\"/>" +
            "</pattern></defs>",
            width: 10,
            height: 10
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern").getOrThrow() as
            SvgPattern).getOrThrow()
        let provider = M3CountingProvider(m3RedPng(2, 2))
        let tile = SvgPatternSampler(root: Some(document.root)).sample(
            pattern,
            SvgBounds(0.0, 0.0, 10.0, 10.0),
            SvgMatrix.identity,
            SvgRenderOptions(samplesPerPixel: 1, images: Some(provider))
        ).getOrThrow()
        @Assert(colorNear(tile.pixel(0, 0), SvgColor.fromRgb(255, 0, 0)))
        @Assert(provider.calls == 1)
    }
}

@Test
public class SvgPatternUnitsM3_test {
    /** patternContentUnits=objectBoundingBox 时内容平移到包围盒原点。 */
    @TestCase
    public func contentOriginShifted(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">" +
            "<defs><pattern id=\"p\" x=\"0.25\" y=\"0\" width=\"0.5\" height=\"0.5\" " +
            "patternContentUnits=\"objectBoundingBox\">" +
            "<rect x=\"0.25\" y=\"0\" width=\"0.5\" height=\"1\" fill=\"red\"/>" +
            "</pattern></defs></svg>"
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        let tile = SvgPatternSampler(root: Some(document.root))
            .sampleTile(pattern, SvgBounds(10.0, 5.0, 20.0, 10.0), SvgRenderOptions())
            .getOrThrow()
        @Assert(colorNear(tile.bitmap.pixel(2, 2), SvgColor.fromRgb(255, 0, 0)))
    }

    /** userSpaceOnUse 的百分比按视口尺寸解释。 */
    @TestCase
    public func userSpacePercentUsesViewport(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\">" +
            "<defs><pattern id=\"p\" width=\"10%\" height=\"10%\" " +
            "patternUnits=\"userSpaceOnUse\"/></defs></svg>"
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        let tile = SvgPatternSampler(root: Some(document.root))
            .sampleTile(pattern, SvgBounds(0.0, 0.0, 100.0, 100.0), SvgRenderOptions())
            .getOrThrow()
        @Assert(tile.tileWidth == 20.0 && tile.tileHeight == 10.0)
    }
}
