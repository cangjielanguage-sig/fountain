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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

internal func m5Opaque(red: Float64, green: Float64, blue: Float64): SvgRgba {
    SvgRgba(red, green, blue, 1.0)
}

internal func m5Near(actual: Float64, expected: Float64): Bool {
    abs(actual - expected) <= 1.0 / 255.0
}

internal func m5AssertRgba(actual: SvgRgba, red: Float64, green: Float64, blue: Float64, alpha: Float64): Unit {
    @Assert(m5Near(actual.red, red))
    @Assert(m5Near(actual.green, green))
    @Assert(m5Near(actual.blue, blue))
    @Assert(m5Near(actual.alpha, alpha))
}

@Test
public class SvgBlendPixelsM5_test {
    /** normal 等价 source-over。 */
    @TestCase
    public func normalEqualsSourceOver(): Unit {
        let backdrop = SvgRgba(0.2, 0.4, 0.6, 0.8)
        let source = SvgRgba(0.5, 0.1, 0.0, 0.5)
        let blended = blendSvgRgba(backdrop, source, SvgMixBlendMode.Normal)
        let expected = source.over(backdrop)
        m5AssertRgba(blended, expected.red, expected.green, expected.blue, expected.alpha)
    }

    /** multiply：白底红源保持红；中灰压白底约一半亮度。 */
    @TestCase
    public func multiply(): Unit {
        let white = m5Opaque(1.0, 1.0, 1.0)
        let red = m5Opaque(1.0, 0.0, 0.0)
        let result = blendSvgRgba(white, red, SvgMixBlendMode.Multiply)
        m5AssertRgba(result, 1.0, 0.0, 0.0, 1.0)

        let gray = m5Opaque(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        let half = blendSvgRgba(white, gray, SvgMixBlendMode.Multiply)
        @Assert(m5Near(half.red, 128.0 / 255.0))
        @Assert(m5Near(half.green, 128.0 / 255.0))
        @Assert(m5Near(half.blue, 128.0 / 255.0))
    }

    /** screen：红 + 蓝 = 洋红。 */
    @TestCase
    public func screen(): Unit {
        let red = m5Opaque(1.0, 0.0, 0.0)
        let blue = m5Opaque(0.0, 0.0, 1.0)
        m5AssertRgba(blendSvgRgba(red, blue, SvgMixBlendMode.Screen), 1.0, 0.0, 1.0, 1.0)
    }

    /** difference：白底白源为黑。 */
    @TestCase
    public func difference(): Unit {
        let white = m5Opaque(1.0, 1.0, 1.0)
        m5AssertRgba(blendSvgRgba(white, white, SvgMixBlendMode.Difference), 0.0, 0.0, 0.0, 1.0)
    }

    /** 背景全透明时直接取源。 */
    @TestCase
    public func transparentBackdrop(): Unit {
        let backdrop = SvgRgba.transparent
        let source = SvgRgba(0.5, 0.0, 0.0, 0.5)
        let result = blendSvgRgba(backdrop, source, SvgMixBlendMode.Multiply)
        m5AssertRgba(result, 0.5, 0.0, 0.0, 0.5)
    }

    /** 源全透明时保持背景。 */
    @TestCase
    public func transparentSource(): Unit {
        let backdrop = m5Opaque(0.25, 0.5, 0.75)
        let result = blendSvgRgba(backdrop, SvgRgba.transparent, SvgMixBlendMode.Screen)
        m5AssertRgba(result, 0.25, 0.5, 0.75, 1.0)
    }

    /** 通道结果钳制到 0..1。 */
    @TestCase
    public func channelsAreClamped(): Unit {
        let backdrop = m5Opaque(0.9, 0.9, 0.9)
        let source = m5Opaque(0.9, 0.9, 0.9)
        let dodge = blendSvgRgba(backdrop, source, SvgMixBlendMode.ColorDodge)
        m5AssertRgba(dodge, 1.0, 1.0, 1.0, 1.0)
        let burn = blendSvgRgba(backdrop, source, SvgMixBlendMode.ColorBurn)
        @Assert(burn.red >= 0.0 && burn.red <= 1.0)
    }

    /** 单通道函数覆盖其余模式的关键点。 */
    @TestCase
    public func channelModes(): Unit {
        @Assert(m5Near(blendCssChannel(0.2, 0.6, SvgMixBlendMode.Darken), 0.2))
        @Assert(m5Near(blendCssChannel(0.2, 0.6, SvgMixBlendMode.Lighten), 0.6))
        @Assert(m5Near(blendCssChannel(0.4, 0.6, SvgMixBlendMode.Difference), 0.2))
        @Assert(m5Near(blendCssChannel(0.4, 0.6, SvgMixBlendMode.Exclusion), 0.52))
        @Assert(m5Near(blendCssChannel(0.2, 0.3, SvgMixBlendMode.Overlay), 0.12))
        @Assert(m5Near(blendCssChannel(0.3, 0.2, SvgMixBlendMode.HardLight), 0.12))
        @Assert(m5Near(blendCssChannel(0.5, 0.25, SvgMixBlendMode.SoftLight), 0.375))
    }
}
