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

internal func m5ColorNear(actual: SvgColor, red: Int64, green: Int64, blue: Int64): Bool {
    let dr = Int64(actual.red) - red
    let dg = Int64(actual.green) - green
    let db = Int64(actual.blue) - blue
    let absR = if (dr < 0) { -dr } else { dr }
    let absG = if (dg < 0) { -dg } else { dg }
    let absB = if (db < 0) { -db } else { db }
    absR <= 2 && absG <= 2 && absB <= 2
}

@Test
public class SvgBlendLayerM5_test {
    /** 显示命令携带混合模式。 */
    @TestCase
    public func commandsCarryBlendMode(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<rect width=\"20\" height=\"20\" fill=\"red\" style=\"mix-blend-mode: multiply\"/></svg>"
        )
        let list = SvgRenderTreeBuilder().build(document)
        @Assert(list.commands.size == 1)
        @Assert(list.commands[0].blendMode == SvgMixBlendMode.Multiply)
        let plain = SvgRenderTreeBuilder().build(
            SvgParser.parse(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
                "<rect width=\"20\" height=\"20\" fill=\"red\"/></svg>"
            )
        )
        @Assert(plain.commands[0].blendMode == SvgMixBlendMode.Normal)
    }

    /** 非 normal 的元素先建层再混合：像素结果等于 multiply。 */
    @TestCase
    public func multiplyAppliesOnce(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"40\" height=\"40\" fill=\"#c86432\"/>" +
            "<rect width=\"40\" height=\"40\" fill=\"#808080\" style=\"mix-blend-mode: multiply\"/>" +
            "</svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m5ColorNear(bitmap.pixel(20, 20), 100, 50, 25))
    }

    /** normal + auto 不建立额外层，输出与 M4 快照一致。 */
    @TestCase
    public func normalDoesNotLayer(): Unit {
        m5RenderAndCompare("basic")
        m5RenderAndCompare("m4-filter")
    }

    /** isolation: isolate 使子元素只与组内内容混合。 */
    @TestCase
    public func isolationKeepsChildInsideGroup(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"40\" height=\"40\" fill=\"white\"/>" +
            "<g style=\"isolation: isolate\">" +
            "<rect width=\"40\" height=\"40\" fill=\"red\" style=\"mix-blend-mode: screen\"/></g></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m5ColorNear(bitmap.pixel(20, 20), 255, 0, 0))
    }

    /** 未隔离时子元素与组外白色混合，screen 结果为白色。 */
    @TestCase
    public func withoutIsolationChildBlendsOutside(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<rect width=\"40\" height=\"40\" fill=\"white\"/>" +
            "<g><rect width=\"40\" height=\"40\" fill=\"red\" style=\"mix-blend-mode: screen\"/></g></svg>"
        )
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(m5ColorNear(bitmap.pixel(20, 20), 255, 255, 255))
    }

    /** 滤镜 + 裁剪 + 混合顺序固定，重复渲染逐字节一致，M4 效果顺序不变。 */
    @TestCase
    public func filterClipBlendOrderIsStable(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
            "<defs><filter id=\"f\"><feGaussianBlur stdDeviation=\"1\"/></filter>" +
            "<clipPath id=\"c\"><rect width=\"20\" height=\"40\"/></clipPath></defs>" +
            "<rect width=\"40\" height=\"40\" fill=\"#336699\"/>" +
            "<rect width=\"40\" height=\"40\" fill=\"#ff6600\" filter=\"url(#f)\" " +
            "clip-path=\"url(#c)\" style=\"mix-blend-mode: multiply\"/></svg>"
        )
        let first = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let second = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(first.pixels == second.pixels)
        m5RenderAndCompare("m4-filter")
        m5RenderAndCompare("m4-clip")
    }

    /** 重复渲染逐字节一致。 */
    @TestCase
    public func repeatedRenderIsIdentical(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"30\">" +
            "<rect width=\"30\" height=\"30\" fill=\"#336699\"/>" +
            "<rect width=\"30\" height=\"30\" fill=\"#99ccff\" style=\"mix-blend-mode: overlay\"/></svg>"
        )
        let first = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let second = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        @Assert(first.pixels == second.pixels)
    }
}
