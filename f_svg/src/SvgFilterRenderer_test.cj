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

internal func filterOf(document: SvgDocument): SvgFilter {
    (document.root.child("defs").getOrThrow().child("filter").getOrThrow() as SvgFilter).getOrThrow()
}

internal func filledBitmap(width: Int64, height: Int64, color: SvgColor): SvgBitmap {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(color)
    bitmap
}

@Test
public class SvgFilterBuffer_test {
    /** 尺寸、索引与透明初值。 */
    @TestCase
    public func bufferLayout(): Unit {
        let buffer = SvgFilterBuffer(2, 3)
        @Assert(buffer.width == 2 && buffer.height == 3)
        @Assert(buffer.pixels.size == 2 * 3 * 4)
        for (byte in buffer.pixels) {
            @Assert(byte == 0)
        }
        buffer.pixels[0] = 1
        buffer.pixels[1] = 2
        buffer.pixels[2] = 3
        buffer.pixels[3] = 4
        @Assert(buffer.pixels[1] == 2)
    }

    /** 从位图裁剪区域，区域外透明。 */
    @TestCase
    public func extractRegion(): Unit {
        let bitmap = filledBitmap(4, 4, SvgColor.fromRgb(10, 20, 30))
        let buffer = SvgFilterBuffer.fromBitmap(bitmap, 1, 1, 2, 2)
        @Assert(buffer.width == 2 && buffer.height == 2)
        @Assert(buffer.pixels[0] == 10 && buffer.pixels[1] == 20 && buffer.pixels[2] == 30)
        @Assert(buffer.pixels[3] == 255)

        let outside = SvgFilterBuffer.fromBitmap(bitmap, -1, -1, 2, 2)
        @Assert(outside.pixels[0] == 0 && outside.pixels[3] == 0)
        @Assert(outside.pixels[12] == 10 && outside.pixels[15] == 255)
    }
}

@Test
public class SvgFilterRenderer_test {
    /** 区域换算：objectBoundingBox 默认扩 10%。 */
    @TestCase
    public func defaultRegion(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\"/></defs></svg>"
        )
        let filter = filterOf(document)
        let renderer = SvgFilterRenderer()
        let region = renderer.region(
            filter,
            SvgBounds(100.0, 100.0, 200.0, 100.0),
            SvgMatrix.identity,
            SvgBitmap(400, 400)
        )
        @Assert(near(region.x, 80.0) && near(region.y, 90.0))
        @Assert(near(region.width, 240.0) && near(region.height, 120.0))
    }

    /** userSpaceOnUse 区域不随包围盒缩放。 */
    @TestCase
    public func userSpaceRegion(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"0\" y=\"0\" width=\"50\" height=\"50\"/></defs></svg>"
        )
        let filter = filterOf(document)
        let renderer = SvgFilterRenderer()
        let region = renderer.region(
            filter,
            SvgBounds(100.0, 100.0, 200.0, 100.0),
            SvgMatrix.identity,
            SvgBitmap(400, 400)
        )
        @Assert(near(region.x, 0.0) && near(region.y, 0.0))
        @Assert(near(region.width, 50.0) && near(region.height, 50.0))
    }

    /** 区域裁剪到画布。 */
    @TestCase
    public func regionClippedToCanvas(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"-20\" y=\"-20\" width=\"100\" height=\"100\"/></defs></svg>"
        )
        let filter = filterOf(document)
        let region = SvgFilterRenderer().region(
            filter,
            SvgBounds(0.0, 0.0, 10.0, 10.0),
            SvgMatrix.identity,
            SvgBitmap(50, 50)
        )
        @Assert(near(region.x, 0.0) && near(region.y, 0.0))
        @Assert(near(region.width, 50.0) && near(region.height, 50.0))
    }

    /** 区域像素超 maxPixels 抛 Limit。 */
    @TestCase
    public func regionLimit(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"0\" y=\"0\" width=\"100\" height=\"100\">" +
            "<feOffset dx=\"0\" dy=\"0\"/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let error = expectSvgException(
            {=>
                SvgFilterRenderer().apply(
                    filter,
                    SvgBitmap(100, 100),
                    SvgBounds(0.0, 0.0, 100.0, 100.0),
                    SvgMatrix.identity,
                    SvgRenderOptions(maxPixels: 10)
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 空滤镜链直通，输出与输入一致。 */
    @TestCase
    public func emptyChainPassthrough(): Unit {
        let document = SvgParser.parse("<svg><defs><filter id=\"f\"/></defs></svg>")
        let filter = filterOf(document)
        let source = filledBitmap(8, 8, SvgColor.fromRgb(12, 34, 56))
        let output = SvgFilterRenderer().apply(
            filter,
            source,
            SvgBounds(0.0, 0.0, 8.0, 8.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        )
        @Assert(output.width == 8 && output.height == 8)
        for (index in 0..source.pixels.size) {
            @Assert(output.pixels[index] == source.pixels[index])
        }
    }

    /** 未定义输入引用：输出透明并记 warning。 */
    @TestCase
    public func undefinedReference(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" x=\"0\" y=\"0\" width=\"8\" height=\"8\" " +
            "filterUnits=\"userSpaceOnUse\"><feOffset in=\"missing\" dx=\"1\"/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let renderer = SvgFilterRenderer()
        let output = renderer.apply(
            filter,
            filledBitmap(8, 8, SvgColor.fromRgb(255, 0, 0)),
            SvgBounds(0.0, 0.0, 8.0, 8.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        )
        @Assert(output.pixel(4, 4).alpha == 0.0)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("missing")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 同一输入多次调用逐字节一致。 */
    @TestCase
    public func deterministic(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\"><feFlood flood-color=\"red\" result=\"a\"/>" +
            "<feOffset in=\"a\" dx=\"1\"/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let source = filledBitmap(8, 8, SvgColor.fromRgb(0, 255, 0))
        let renderer = SvgFilterRenderer()
        let first = renderer.apply(
            filter, source, SvgBounds(0.0, 0.0, 8.0, 8.0), SvgMatrix.identity, SvgRenderOptions()
        )
        let second = renderer.apply(
            filter, source, SvgBounds(0.0, 0.0, 8.0, 8.0), SvgMatrix.identity, SvgRenderOptions()
        )
        @Assert(first.pixels == second.pixels)
        @Assert(source.pixels[0] == 0 && source.pixels[1] == 255)
    }

    /** linearRGB 往返误差不超过 1/255。 */
    @TestCase
    public func linearRgbRoundTrip(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" color-interpolation-filters=\"linearRGB\">" +
            "<feOffset dx=\"0\" dy=\"0\"/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let source = filledBitmap(4, 4, SvgColor.fromRgb(200, 100, 50))
        let output = SvgFilterRenderer().apply(
            filter,
            source,
            SvgBounds(0.0, 0.0, 4.0, 4.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        )
        for (index in 0..source.pixels.size) {
            let difference = Int64(output.pixels[index]) - Int64(source.pixels[index])
            @Assert(difference <= 1 && difference >= -1)
        }
    }
}

@Test
public class SvgFilterRegionOrderM3_test {
    /** 区域超限在分配区域缓冲前抛出。 */
    @TestCase
    public func limitBeforeAllocation(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"0\" y=\"0\" width=\"64\" height=\"64\"><feOffset dx=\"1\"/></filter></defs></svg>"
        )
        let error = expectSvgException(
            {=>
                SvgFilterRenderer().apply(
                    filterOf(document),
                    SvgBitmap(64, 64),
                    SvgBounds(0.0, 0.0, 1.0, 1.0),
                    SvgMatrix.identity,
                    SvgRenderOptions(maxPixels: 4095)
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}

@Test
public class SvgFilterAttributeM3_test {
    /** 空 filter 属性跳过并记 warning。 */
    @TestCase
    public func emptyFilterWarns(): Unit {
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let bitmap = renderer.render(
            SvgParser.parse(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
                "<rect width=\"10\" height=\"10\" fill=\"red\" filter=\"\"/></svg>"
            )
        )
        @Assert(colorNear(bitmap.pixel(5, 5), SvgColor.fromRgb(255, 0, 0)))
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("filter")) {
                found = true
            }
        }
        @Assert(found)
    }

    /** 非 url() 的 filter 值同样跳过并记 warning。 */
    @TestCase
    public func nonUrlFilterWarns(): Unit {
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        renderer.render(
            SvgParser.parse(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
                "<rect width=\"10\" height=\"10\" fill=\"red\" filter=\"blur\"/></svg>"
            )
        )
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("filter")) {
                found = true
            }
        }
        @Assert(found)
    }
}
