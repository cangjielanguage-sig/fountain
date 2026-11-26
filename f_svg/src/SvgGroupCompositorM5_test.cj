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

internal func m5SolidBitmap(width: Int64, height: Int64, color: SvgColor): SvgBitmap {
    let bitmap = SvgBitmap(width, height)
    bitmap.fill(color)
    bitmap
}

@Test
public class SvgGroupCompositorM5_test {
    /** 旧三参数调用与新重载在 normal 下逐字节一致。 */
    @TestCase
    public func legacyCallUnchanged(): Unit {
        let backdropA = m5SolidBitmap(2, 2, SvgColor.fromRgb(10, 20, 30, alpha: 0.8))
        let backdropB = m5SolidBitmap(2, 2, SvgColor.fromRgb(10, 20, 30, alpha: 0.8))
        let layer = m5SolidBitmap(2, 2, SvgColor.fromRgb(200, 100, 50, alpha: 0.6))
        SvgGroupCompositor.composite(backdropA, layer, 0.5)
        SvgGroupCompositor.composite(backdropB, layer, 0.5, mode: SvgMixBlendMode.Normal)
        @Assert(backdropA.pixels == backdropB.pixels)
    }

    /** multiply 与 normal 在同一输入上产生不同结果。 */
    @TestCase
    public func multiplyDiffers(): Unit {
        let normalTarget = m5SolidBitmap(1, 1, SvgColor.fromRgb(200, 100, 50))
        let multiplyTarget = m5SolidBitmap(1, 1, SvgColor.fromRgb(200, 100, 50))
        let layer = m5SolidBitmap(1, 1, SvgColor.fromRgb(128, 128, 128))
        SvgGroupCompositor.composite(normalTarget, layer, 1.0)
        SvgGroupCompositor.composite(multiplyTarget, layer, 1.0, mode: SvgMixBlendMode.Multiply)
        @Assert(normalTarget.pixel(0, 0).toString() != multiplyTarget.pixel(0, 0).toString())
        @Assert(multiplyTarget.pixel(0, 0).red >= 99 && multiplyTarget.pixel(0, 0).red <= 101)
    }

    /** 透明源像素不影响目标。 */
    @TestCase
    public func transparentSourceSkipped(): Unit {
        let target = m5SolidBitmap(1, 1, SvgColor.fromRgb(1, 2, 3))
        let layer = SvgBitmap(1, 1)
        SvgGroupCompositor.composite(target, layer, 1.0, mode: SvgMixBlendMode.Screen)
        @Assert(target.pixel(0, 0).toString() == "#010203")
    }

    /** opacity 为 0 时整层跳过。 */
    @TestCase
    public func zeroOpacitySkips(): Unit {
        let target = m5SolidBitmap(1, 1, SvgColor.fromRgb(1, 2, 3))
        let layer = m5SolidBitmap(1, 1, SvgColor.fromRgb(200, 200, 200))
        SvgGroupCompositor.composite(target, layer, 0.0, mode: SvgMixBlendMode.Multiply)
        @Assert(target.pixel(0, 0).toString() == "#010203")
    }

    /** screen：红底蓝层得到洋红。 */
    @TestCase
    public func screenComposite(): Unit {
        let target = m5SolidBitmap(1, 1, SvgColor.fromRgb(255, 0, 0))
        let layer = m5SolidBitmap(1, 1, SvgColor.fromRgb(0, 0, 255))
        SvgGroupCompositor.composite(target, layer, 1.0, mode: SvgMixBlendMode.Screen)
        @Assert(target.pixel(0, 0).toString() == "#ff00ff")
    }
}
