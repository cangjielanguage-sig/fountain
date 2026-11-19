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

@Test
public class SvgFilterTileChainM3_test {
    /** feTile 在真实滤镜链中把完整输入缓冲平铺到滤镜区域。 */
    @TestCase
    public func tileRepeatsAcrossRegion(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"0\" y=\"0\" width=\"6\" height=\"6\"><feTile/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let source = SvgBitmap(6, 6)
        for (y in 0..6) {
            for (x in 0..6) {
                source.setPixel(x, y, SvgColor.fromRgb(255, 0, 0))
            }
        }
        let output = SvgFilterRenderer().apply(
            filter,
            source,
            SvgBounds(0.0, 0.0, 2.0, 2.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        )
        for (y in 0..6) {
            for (x in 0..6) {
                @Assert(colorNear(output.pixel(x, y), SvgColor.fromRgb(255, 0, 0)))
            }
        }
    }

    /** 输入缓冲含透明 padding 时，tile 周期仍为完整缓冲尺寸。 */
    @TestCase
    public func fullBufferIsTilePeriod(): Unit {
        let input = SvgFilterBuffer(4, 4)
        for (y in 0..2) {
            for (x in 0..2) {
                let base = (y * input.width + x) * 4
                input.pixels[base] = 255
                input.pixels[base + 3] = 255
            }
        }
        let output = tileFilterBuffer(input, 9, 9)
        @Assert(output.pixels[(0 * 9 + 0) * 4 + 3] > 0)
        @Assert(output.pixels[(2 * 9 + 2) * 4 + 3] == 0)
        @Assert(output.pixels[(4 * 9 + 4) * 4 + 3] > 0)
        @Assert(output.pixels[(6 * 9 + 6) * 4 + 3] == 0)
    }

    /** 输入全透明时 feTile 输出透明并记 warning。 */
    @TestCase
    public func emptyTileWarns(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\" filterUnits=\"userSpaceOnUse\" " +
            "x=\"0\" y=\"0\" width=\"4\" height=\"4\"><feTile/></filter></defs></svg>"
        )
        let filter = filterOf(document)
        let renderer = SvgFilterRenderer()
        let output = renderer.apply(
            filter,
            SvgBitmap(4, 4),
            SvgBounds(0.0, 0.0, 4.0, 4.0),
            SvgMatrix.identity,
            SvgRenderOptions()
        )
        @Assert(output.pixel(2, 2).alpha == 0.0)
        var found = false
        for (warning in renderer.warnings) {
            if (warning.contains("feTile")) {
                found = true
            }
        }
        @Assert(found)
    }
}
