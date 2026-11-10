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

internal func colorNear(actual: SvgColor, expected: SvgColor, tolerance!: Int64 = 1): Bool {
    let da = Int64(actual.red) - Int64(expected.red)
    let dg = Int64(actual.green) - Int64(expected.green)
    let db = Int64(actual.blue) - Int64(expected.blue)
    let daA = actual.alpha - expected.alpha
    (if (da < 0) { -da } else { da }) <= tolerance &&
    (if (dg < 0) { -dg } else { dg }) <= tolerance &&
    (if (db < 0) { -db } else { db }) <= tolerance &&
    (if (daA < 0.0) { -daA } else { daA }) <= 0.01
}

@Test
public class SvgBitmap_test {
    /** 尺寸、像素数组、初始透明度、越界访问。 */
    @TestCase
    public func bitmapBasics(): Unit {
        let bitmap = SvgBitmap(2, 3)
        @Assert(bitmap.width == 2)
        @Assert(bitmap.height == 3)
        @Assert(bitmap.pixels.size == 24)
        for (index in 0..bitmap.pixels.size) {
            @Assert(bitmap.pixels[index] == 0)
        }
        @Assert(bitmap.pixel(0, 0) == SvgColor.Transparent)
        @Assert(bitmap.pixel(1, 2) == SvgColor.Transparent)
        let error = expectSvgException({=> bitmap.pixel(-1, 0)})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
        let error2 = expectSvgException({=> bitmap.pixel(0, 3)})
        @Assert(error2.kind == SvgErrorKind.InvalidValue)
    }

    /** 背景填充与预乘 over 合成。 */
    @TestCase
    public func fillAndBlend(): Unit {
        let bitmap = SvgBitmap(1, 1)
        bitmap.fill(SvgColor.fromRgb(128, 128, 128))
        @Assert(colorNear(bitmap.pixel(0, 0), SvgColor.fromRgb(128, 128, 128)))

        bitmap.blend(0, 0, SvgRgba.fromColor(SvgColor.fromRgb(255, 0, 0), 0.5))
        @Assert(colorNear(bitmap.pixel(0, 0), SvgColor.fromRgb(191, 64, 64)))

        let transparent = SvgBitmap(2, 1)
        transparent.blend(0, 0, SvgRgba.fromColor(SvgColor.fromRgb(255, 0, 0), 0.5))
        let red = transparent.pixel(0, 0)
        @Assert(red.red == 255)
        @Assert(abs(red.alpha - 0.5) < 0.01)
        transparent.blend(1, 0, SvgRgba.fromColor(SvgColor.fromRgb(0, 0, 255), 0.5))
        @Assert(colorNear(transparent.pixel(1, 0), SvgColor(0, 0, 255, alpha: 0.5), tolerance: 2))
    }

    /** 渲染选项默认值、采样数与安全上限。 */
    @TestCase
    public func renderOptions(): Unit {
        let options = SvgRenderOptions()
        @Assert(options.width == 0)
        @Assert(options.height == 0)
        @Assert(options.samplesPerPixel == 4)
        @Assert(options.maxPixels == 64 * 1024 * 1024)
        @Assert(options.devicePixelRatio == 1.0)
        @Assert(options.background.isNone())
        @Assert(options.fonts.isNone())
        options.validatePixels(1000, 1000)

        let badSamples = expectSvgException({=> SvgRenderOptions(samplesPerPixel: 3)})
        @Assert(badSamples.kind == SvgErrorKind.InvalidValue)
        let negativeWidth = expectSvgException({=> SvgRenderOptions(width: -1)})
        @Assert(negativeWidth.kind == SvgErrorKind.InvalidValue)
        let badRatio = expectSvgException({=> SvgRenderOptions(devicePixelRatio: 0.0)})
        @Assert(badRatio.kind == SvgErrorKind.InvalidValue)

        let limited = SvgRenderOptions(maxPixels: 100)
        let limitError = expectSvgException({=> limited.validatePixels(11, 10)})
        @Assert(limitError.kind == SvgErrorKind.Limit)
        @Assert(SvgRenderOptions(samplesPerPixel: 1).samplesPerPixel == 1)
        @Assert(SvgRenderOptions(samplesPerPixel: 2).samplesPerPixel == 2)
    }
}
