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

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgBenchmark_test {
    /** 512×512 / 50 形状、1024 渐变 + 裁剪、1024 PNG 编码（参考，非门禁）。 */
    @TestCase
    public func renderBenchmarks(): Unit {
        let shapes = StringBuilder()
        for (index in 0..50) {
            let x = (index * 37) % 480
            let y = (index * 53) % 480
            if (index % 2 == 0) {
                shapes.append('<rect x="${x}" y="${y}" width="24" height="18" fill="#3366cc" opacity="0.7"/>')
            } else {
                shapes.append('<circle cx="${x + 12}" cy="${y + 9}" r="10" fill="#cc3333" opacity="0.7"/>')
            }
        }
        let basic = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512">${shapes.toString()}</svg>'
        )
        let basicStart = MonoTime.now()
        let basicBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 2)).render(basic)
        let basicElapsed = MonoTime.now() - basicStart
        @Assert(basicBitmap.width == 512)
        println("512×512 / 50 形状: ${basicElapsed.toNanoseconds() / 1000000} ms")

        let gradientDocument = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">' +
            '<defs><linearGradient id="g" gradientUnits="objectBoundingBox" x1="0" y1="0" x2="1" y2="1">' +
            '<stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>' +
            '</linearGradient><clipPath id="c"><circle cx="512" cy="512" r="400"/></clipPath></defs>' +
            '<rect width="1024" height="1024" fill="url(#g)" clip-path="url(#c)"/></svg>'
        )
        let gradientStart = MonoTime.now()
        let gradientBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(gradientDocument)
        let gradientElapsed = MonoTime.now() - gradientStart
        @Assert(gradientBitmap.width == 1024)
        println("1024×1024 渐变 + 裁剪: ${gradientElapsed.toNanoseconds() / 1000000} ms")

        let pngStart = MonoTime.now()
        let png = gradientBitmap.toPngBytes()
        let pngElapsed = MonoTime.now() - pngStart
        @Assert(png.size > 8)
        println("1024×1024 PNG 编码: ${pngElapsed.toNanoseconds() / 1000000} ms")
    }

    /** 1000 段路径 bbox 基准（参考，非门禁）。 */
    @TestCase
    public func geometryBenchmark(): Unit {
        let builder = StringBuilder("M0 0")
        for (index in 0..1000) {
            if (index % 2 == 0) {
                builder.append(" L${index + 1} ${index % 37}")
            } else {
                builder.append(" C${index} 10 ${index + 1} 20 ${index + 2} 0")
            }
        }
        let path = SvgPath(d: SvgPathData.parse(builder.toString()))
        let style = styleOf(computeTree(path), path)
        let start = MonoTime.now()
        let box = SvgGeometry.bounds(path, style: style)
        let elapsed = MonoTime.now() - start
        @Assert(box.isSome())
        println("1000 段路径 bounds: ${elapsed.toNanoseconds() / 1000000} ms")
    }
}

@Test
public class SvgBenchmarkM3Blur_test {
    @TestCase
    public func blur(): Unit {
        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512">' +
            '<defs><filter id="f"><feGaussianBlur stdDeviation="8"/></filter></defs>' +
            '<rect width="512" height="512" fill="#3366cc" filter="url(#f)"/></svg>'
        )
        let start = MonoTime.now()
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let elapsed = MonoTime.now() - start
        @Assert(bitmap.width == 512)
        println("512×512 高斯模糊 σ=8: ${elapsed.toNanoseconds() / 1000000} ms")
    }
}

@Test
public class SvgBenchmarkM3Pattern_test {
    @TestCase
    public func pattern(): Unit {
        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512">' +
            '<defs><pattern id="p" width="32" height="32" patternUnits="userSpaceOnUse">' +
            '<rect width="32" height="32" fill="#f2e6c8"/>' +
            '<rect width="12" height="12" fill="#c84b31"/></pattern></defs>' +
            '<rect width="512" height="512" fill="url(#p)"/></svg>'
        )
        let start = MonoTime.now()
        let bitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(document)
        let elapsed = MonoTime.now() - start
        @Assert(bitmap.width == 512)
        println("512×512 图案平铺: ${elapsed.toNanoseconds() / 1000000} ms")
    }
}

@Test
public class SvgBenchmarkM3Analytic_test {
    @TestCase
    public func analyticCircle(): Unit {
        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">' +
            '<circle cx="512" cy="512" r="480" fill="#2d6a4f"/></svg>'
        )
        let start = MonoTime.now()
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, antiAlias: SvgAntiAliasMode.Analytic)
        ).render(document)
        let elapsed = MonoTime.now() - start
        @Assert(bitmap.width == 1024)
        println("1024×1024 解析 AA 圆: ${elapsed.toNanoseconds() / 1000000} ms")
    }
}
