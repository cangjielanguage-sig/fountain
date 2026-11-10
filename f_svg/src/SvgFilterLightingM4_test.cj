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

private func m4Luminance(buffer: SvgFilterBuffer, x: Int64, y: Int64): Float64 {
    Float64(m4ChannelAt(buffer, x, y, 0)) * 0.2126 +
        Float64(m4ChannelAt(buffer, x, y, 1)) * 0.7152 +
        Float64(m4ChannelAt(buffer, x, y, 2)) * 0.0722
}

@Test
public class SvgFilterLightingM4_test {
    /** 平行光漫反射：elevation=90 时均匀照亮。 */
    @TestCase
    public func distantDiffuse(): Unit {
        let input = m4Buffer(4, 4, SvgColor.White)
        let lighting = SvgFeDiffuseLighting()
        lighting.diffuseConstant = 0.5
        lighting.lightingColor = SvgPaint.of(SvgColor.fromRgb(255, 0, 0))
        let light = SvgFeDistantLight()
        light.azimuth = 0.0
        light.elevation = 90.0
        lighting.appendElement(light)
        let warnings = ArrayList<String>()
        let result = lightingFilterBuffer(input, lighting, false, 1.0, 1.0, warnings)
        @Assert(m4ChannelAt(result, 2, 2, 0) >= 126 && m4ChannelAt(result, 2, 2, 0) <= 128)
        @Assert(m4ChannelAt(result, 2, 2, 1) == 0)
        @Assert(m4AlphaAt(result, 2, 2) == 255)
    }

    /** 点光源：近处更亮。 */
    @TestCase
    public func pointFalloff(): Unit {
        let input = m4Buffer(6, 6, SvgColor.White)
        let lighting = SvgFeDiffuseLighting()
        lighting.diffuseConstant = 1.0
        lighting.lightingColor = SvgPaint.of(SvgColor.White)
        let light = SvgFePointLight()
        light.x = 0.5
        light.y = 2.5
        light.z = 1.0
        lighting.appendElement(light)
        let warnings = ArrayList<String>()
        let result = lightingFilterBuffer(input, lighting, false, 1.0, 1.0, warnings)
        @Assert(m4Luminance(result, 0, 2) > m4Luminance(result, 5, 2) + 5.0)
    }

    /** 聚光灯锥角：中心亮、锥外暗。 */
    @TestCase
    public func spotCone(): Unit {
        let input = m4Buffer(6, 6, SvgColor.White)
        let lighting = SvgFeDiffuseLighting()
        lighting.diffuseConstant = 1.0
        lighting.lightingColor = SvgPaint.of(SvgColor.White)
        let light = SvgFeSpotLight()
        light.x = 2.5
        light.y = 2.5
        light.z = 5.0
        light.pointsAtX = 2.5
        light.pointsAtY = 2.5
        light.pointsAtZ = 0.0
        light.limitingConeAngle = Some(5.0)
        lighting.appendElement(light)
        let warnings = ArrayList<String>()
        let result = lightingFilterBuffer(input, lighting, false, 1.0, 1.0, warnings)
        @Assert(m4Luminance(result, 2, 2) > 100.0)
        @Assert(m4Luminance(result, 0, 0) == 0.0)
    }

    /** 高光峰值不超过 255，alpha 与输入一致。 */
    @TestCase
    public func specular(): Unit {
        let input = m4Buffer(4, 4, SvgColor.White)
        let lighting = SvgFeSpecularLighting()
        lighting.specularConstant = 1.0
        lighting.specularExponent = 20.0
        lighting.lightingColor = SvgPaint.of(SvgColor.White)
        let light = SvgFeDistantLight()
        light.elevation = 90.0
        lighting.appendElement(light)
        let warnings = ArrayList<String>()
        let result = lightingFilterBuffer(input, lighting, true, 1.0, 1.0, warnings)
        var maximum = 0
        for (index in 0..result.pixels.size) {
            if (index % 4 != 3 && Int64(result.pixels[index]) > maximum) {
                maximum = Int64(result.pixels[index])
            }
        }
        @Assert(maximum > 0)
        @Assert(maximum <= 255)
        @Assert(m4AlphaAt(result, 2, 2) == 255)
    }

    /** 缺光源与非法 surfaceScale 降级为透明 + warning。 */
    @TestCase
    public func lightingFallbacks(): Unit {
        let input = m4Buffer(3, 3, SvgColor.White)
        let noLight = SvgFeDiffuseLighting()
        let warnings = ArrayList<String>()
        let transparent = lightingFilterBuffer(input, noLight, false, 1.0, 1.0, warnings)
        @Assert(m4AlphaAt(transparent, 1, 1) == 0)
        @Assert(warnings.size > 0)
        @Assert(warnings[0].contains("光源"))

        let badScale = SvgFeDiffuseLighting()
        badScale.setAttr("surfaceScale", "nan")
        badScale.appendElement(SvgFeDistantLight())
        let badWarnings = ArrayList<String>()
        let bad = lightingFilterBuffer(input, badScale, false, 1.0, 1.0, badWarnings)
        @Assert(m4AlphaAt(bad, 1, 1) == 0)
        @Assert(badWarnings.size > 0)
    }

    /** 光照 + feComposite + feBlend 链式输出确定。 */
    @TestCase
    public func lightingChain(): Unit {
        let document = SvgParser.parse(
            "<svg width=\"16\" height=\"16\">" +
            "<filter id=\"f\"><feDiffuseLighting result=\"lit\" diffuseConstant=\"1\" " +
            "lighting-color=\"white\"><feDistantLight elevation=\"60\"/></feDiffuseLighting>" +
            "<feComposite in=\"lit\" in2=\"SourceGraphic\" operator=\"in\" result=\"c\"/>" +
            "<feBlend in=\"c\" in2=\"SourceGraphic\" mode=\"multiply\"/></filter>" +
            "<rect width=\"12\" height=\"12\" fill=\"red\" filter=\"url(#f)\"/></svg>"
        )
        let renderer = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
        let first = renderer.render(document)
        let second = renderer.render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(first.pixel(5, 5).alpha > 0.5)
    }
}
