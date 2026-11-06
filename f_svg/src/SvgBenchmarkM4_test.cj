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
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgBenchmarkM4_test {
    /** 512×512 卷积、湍流、20 万次 TTF 字形解析、1000 段路径长度（参考，非门禁）。 */
    @TestCase
    public func m4Benchmarks(): Unit {
        let input = SvgFilterBuffer(512, 512)
        var index = 0
        while (index < input.pixels.size) {
            input.pixels[index] = 200
            input.pixels[index + 1] = 120
            input.pixels[index + 2] = 60
            input.pixels[index + 3] = 255
            index += 4
        }
        let warnings = ArrayList<String>()

        let convolve = SvgFeConvolveMatrix()
        convolve.kernelMatrix = [0.0, -1.0, 0.0, -1.0, 5.0, -1.0, 0.0, -1.0, 0.0]
        convolve.divisor = Some(1.0)
        let convolveStart = MonoTime.now()
        let convolved = convolveFilterBuffer(input, convolve, warnings)
        let convolveElapsed = MonoTime.now() - convolveStart
        @Assert(convolved.width == 512)
        println("512×512 卷积: ${convolveElapsed.toNanoseconds() / 1000000} ms")

        let turbulence = SvgFeTurbulence()
        turbulence.baseFrequency = SvgNumberList([0.02, 0.03])
        turbulence.numOctaves = 2
        let turbulenceStart = MonoTime.now()
        let noise = turbulenceFilterBuffer(input, turbulence, 1.0, 1.0, warnings)
        let turbulenceElapsed = MonoTime.now() - turbulenceStart
        @Assert(noise.width == 512)
        println("512×512 湍流: ${turbulenceElapsed.toNanoseconds() / 1000000} ms")

        let font = SvgTrueTypeFont.parse(m4BuildTtf())
        let glyphStart = MonoTime.now()
        var glyphCount = 0
        while (glyphCount < 200000) {
            let path = font.glyphPath(65, 20.0)
            if (path.isNone()) {
                @Fail("TTF 字形解析失败")
            }
            glyphCount++
        }
        let glyphElapsed = MonoTime.now() - glyphStart
        println("20 万次 TTF 字形解析: ${glyphElapsed.toNanoseconds() / 1000000} ms")

        let builder = StringBuilder("M0 0")
        for (segment in 0..1000) {
            builder.append(" L${segment + 1} ${segment % 17}")
        }
        let path = SvgPathData.parse(builder.toString())
        let lengthStart = MonoTime.now()
        let total = path.totalLength()
        let lengthElapsed = MonoTime.now() - lengthStart
        @Assert(total > 1000.0)
        println("1000 段路径长度: ${lengthElapsed.toNanoseconds() / 1000000} ms")
    }
}
