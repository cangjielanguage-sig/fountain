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

@Test
public class SvgGradientColorSpaceM6_test {
    private let stops = '<stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/>'

    private func render(defs: String): SvgBitmap {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">" +
            "<defs>" + defs + "</defs>" +
            "<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#s)\"/>" +
            "<rect x=\"20\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#l)\"/></svg>"
        )
        SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
    }

    /** 渐变元素自身的 linearRGB 生效：两段中点颜色不同。 */
    @TestCase
    public func gradientOwnInterpolation(): Unit {
        let bitmap = render(
            "<linearGradient id=\"s\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">" + this.stops +
            "</linearGradient>" +
            "<linearGradient id=\"l\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\" " +
            "color-interpolation=\"linearRGB\">" + this.stops + "</linearGradient>"
        )
        let srgb = bitmap.pixel(10, 10)
        let linear = bitmap.pixel(30, 10)
        @Assert(srgb != linear)
        @Assert(linear.red >= 175 && linear.blue >= 180)
        @Assert(srgb.red <= 130 && srgb.blue <= 140)
    }

    /** 渐变祖先声明 color-interpolation 时按线性光插值。 */
    @TestCase
    public func inheritedFromGradientAncestor(): Unit {
        let bitmap = render(
            "<linearGradient id=\"s\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">" + this.stops +
            "</linearGradient>" +
            "<g color-interpolation=\"linearRGB\">" +
            "<linearGradient id=\"l\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">" + this.stops +
            "</linearGradient></g>"
        )
        let srgb = bitmap.pixel(10, 10)
        let linear = bitmap.pixel(30, 10)
        @Assert(srgb != linear)
        @Assert(linear.red >= 175 && linear.blue >= 180)
    }

    /** 渐变元素上的非 sRGB color-profile 回退 sRGB 并 warning。 */
    @TestCase
    public func gradientColorProfileWarns(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<defs><linearGradient id=\"l\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\" " +
            "color-profile=\"custom\">" + this.stops + "</linearGradient></defs>" +
            "<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#l)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        renderer.render(document)
        var warned = false
        for (warning in renderer.warnings) {
            if (warning.contains("color-profile")) {
                warned = true
            }
        }
        @Assert(warned)
    }
}
