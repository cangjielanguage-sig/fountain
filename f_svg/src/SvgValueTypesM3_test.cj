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

class M3TestImageProvider <: SvgImageResourceProvider {
    public func resolve(href: String): ?Array<Byte> {
        None
    }
}

@Test
public class SvgValueTypesM3_test {
    /** 混合模式与合成算子的解析与字符串形式。 */
    @TestCase
    public func blendAndComposite(): Unit {
        @Assert(SvgBlendMode.fromName("normal") == Some(SvgBlendMode.Normal))
        @Assert(SvgBlendMode.fromName("multiply") == Some(SvgBlendMode.Multiply))
        @Assert(SvgBlendMode.fromName("screen") == Some(SvgBlendMode.Screen))
        @Assert(SvgBlendMode.fromName("darken") == Some(SvgBlendMode.Darken))
        @Assert(SvgBlendMode.fromName("lighten") == Some(SvgBlendMode.Lighten))
        @Assert(SvgBlendMode.Multiply.toString() == "multiply")
        @Assert(SvgBlendMode.fromName("unknown").isNone())

        @Assert(SvgCompositeOperator.fromName("over") == Some(SvgCompositeOperator.Over))
        @Assert(SvgCompositeOperator.fromName("in") == Some(SvgCompositeOperator.In))
        @Assert(SvgCompositeOperator.fromName("out") == Some(SvgCompositeOperator.Out))
        @Assert(SvgCompositeOperator.fromName("atop") == Some(SvgCompositeOperator.Atop))
        @Assert(SvgCompositeOperator.fromName("xor") == Some(SvgCompositeOperator.Xor))
        @Assert(SvgCompositeOperator.fromName("arithmetic") == Some(SvgCompositeOperator.Arithmetic))
        @Assert(SvgCompositeOperator.Arithmetic.toString() == "arithmetic")
        @Assert(SvgCompositeOperator.fromName("nope").isNone())
    }

    /** 颜色矩阵类型。 */
    @TestCase
    public func colorMatrixType(): Unit {
        @Assert(SvgColorMatrixType.fromName("matrix") == Some(SvgColorMatrixType.Matrix))
        @Assert(SvgColorMatrixType.fromName("saturate") == Some(SvgColorMatrixType.Saturate))
        @Assert(SvgColorMatrixType.fromName("hueRotate") == Some(SvgColorMatrixType.HueRotate))
        @Assert(
            SvgColorMatrixType.fromName("luminanceToAlpha") == Some(SvgColorMatrixType.LuminanceToAlpha)
        )
        @Assert(SvgColorMatrixType.HueRotate.toString() == "hueRotate")
        @Assert(SvgColorMatrixType.fromName("bogus").isNone())
    }

    /** marker 单位与朝向。 */
    @TestCase
    public func markerEnums(): Unit {
        @Assert(SvgMarkerUnits.fromName("strokeWidth") == Some(SvgMarkerUnits.StrokeWidth))
        @Assert(SvgMarkerUnits.fromName("userSpaceOnUse") == Some(SvgMarkerUnits.UserSpaceOnUse))
        @Assert(SvgMarkerUnits.StrokeWidth.toString() == "strokeWidth")

        @Assert(SvgMarkerOrient.fromName("auto") == Some(SvgMarkerOrient.Auto))
        @Assert(SvgMarkerOrient.fromName("auto-start-reverse") == Some(SvgMarkerOrient.AutoStartReverse))
        @Assert(SvgMarkerOrient.fromName("45") == Some(SvgMarkerOrient.Angle(45.0)))
        @Assert(SvgMarkerOrient.Angle(45.0).toString() == "45")
        @Assert(SvgMarkerOrient.Auto.toString() == "auto")
        @Assert(SvgMarkerOrient.AutoStartReverse.toString() == "auto-start-reverse")
        @Assert(SvgMarkerOrient.fromName("spin").isNone())
    }

    /** 图像取样模式。 */
    @TestCase
    public func imageRendering(): Unit {
        @Assert(SvgImageRendering.fromName("auto") == Some(SvgImageRendering.Auto))
        @Assert(SvgImageRendering.fromName("optimizeQuality") == Some(SvgImageRendering.OptimizeQuality))
        @Assert(SvgImageRendering.fromName("pixelated") == Some(SvgImageRendering.Pixelated))
        @Assert(SvgImageRendering.fromName("optimizeSpeed") == Some(SvgImageRendering.OptimizeSpeed))
        @Assert(SvgImageRendering.fromName("OPTIMIZEQUALITY") == Some(SvgImageRendering.OptimizeQuality))
        @Assert(SvgImageRendering.Pixelated.toString() == "pixelated")
        @Assert(SvgImageRendering.fromName("nearest").isNone())
    }

    /** 抗锯齿档位。 */
    @TestCase
    public func antiAliasMode(): Unit {
        @Assert(SvgAntiAliasMode.Supersample.toString() == "Supersample")
        @Assert(SvgAntiAliasMode.Analytic.toString() == "Analytic")
        @Assert(SvgAntiAliasMode.Supersample == SvgAntiAliasMode.Supersample)
        @Assert(!(SvgAntiAliasMode.Supersample == SvgAntiAliasMode.Analytic))
    }

    /** 未知枚举字符串回退到缺省值并记 warning。 */
    @TestCase
    public func unknownEnumFallsBackWithWarning(): Unit {
        let warnings = ArrayList<String>()
        @Assert(
            SvgBlendMode.fromNameOrWarn(Some("unknown"), warnings, "feBlend@mode") == SvgBlendMode.Normal
        )
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("unknown"))

        let valid = ArrayList<String>()
        @Assert(
            SvgBlendMode.fromNameOrWarn(Some("screen"), valid, "feBlend@mode") == SvgBlendMode.Screen
        )
        @Assert(valid.size == 0)

        let empty = ArrayList<String>()
        @Assert(
            SvgCompositeOperator.fromNameOrWarn(None, empty, "feComposite@operator") ==
                SvgCompositeOperator.Over
        )
        @Assert(empty.size == 0)

        let marker = ArrayList<String>()
        @Assert(
            SvgMarkerOrient.fromNameOrWarn(Some("spin"), marker, "marker@orient") ==
                SvgMarkerOrient.Angle(0.0)
        )
        @Assert(marker.size == 1)
    }

    /** 渲染选项新增字段及既有默认值不变。 */
    @TestCase
    public func renderOptionsDefaults(): Unit {
        let options = SvgRenderOptions()
        @Assert(options.images.isNone())
        @Assert(options.antiAlias == SvgAntiAliasMode.Supersample)
        @Assert(options.width == 0)
        @Assert(options.height == 0)
        @Assert(options.samplesPerPixel == 4)
        @Assert(options.maxPixels == 64 * 1024 * 1024)
        @Assert(options.devicePixelRatio == 1.0)
        @Assert(options.background.isNone())
        @Assert(options.fonts.isNone())

        let provider = M3TestImageProvider()
        let custom = SvgRenderOptions(
            width: 10,
            height: 20,
            images: Some(provider),
            antiAlias: SvgAntiAliasMode.Analytic
        )
        @Assert(custom.images.isSome())
        @Assert(custom.antiAlias == SvgAntiAliasMode.Analytic)
        @Assert(custom.samplesPerPixel == 4)
    }

    /** 安全选项的解压上限。 */
    @TestCase
    public func securityDecompressedLimit(): Unit {
        @Assert(SvgSecurityOptions().maxDecompressedBytes == 64 * 1024 * 1024)
        let custom = SvgSecurityOptions(maxDecompressedBytes: 128)
        @Assert(custom.maxDecompressedBytes == 128)
        let error = expectSvgException({=> SvgSecurityOptions(maxDecompressedBytes: -1)})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
        let zero = expectSvgException({=> SvgSecurityOptions(maxDecompressedBytes: 0)})
        @Assert(zero.kind == SvgErrorKind.InvalidValue)
    }
}
