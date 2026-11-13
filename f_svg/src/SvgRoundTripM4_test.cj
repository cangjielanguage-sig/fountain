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

private let M4_FILTER_ROUND_TRIP =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">" +
    "<filter id=\"f\">" +
    "<feComponentTransfer><feFuncR type=\"gamma\" amplitude=\"2\" exponent=\"0.5\"/>" +
    "<feFuncG type=\"table\" tableValues=\"0 0.5 1\"/></feComponentTransfer>" +
    "<feMorphology operator=\"dilate\" radius=\"1 2\"/>" +
    "<feConvolveMatrix order=\"3\" kernelMatrix=\"0 -1 0 -1 5 -1 0 -1 0\" divisor=\"1\" " +
    "edgeMode=\"wrap\" preserveAlpha=\"true\"/>" +
    "<feTurbulence type=\"fractalNoise\" baseFrequency=\"0.05 0.1\" numOctaves=\"3\" " +
    "seed=\"7\" stitchTiles=\"stitch\"/>" +
    "<feDisplacementMap in2=\"noise\" scale=\"4\" xChannelSelector=\"R\" " +
    "yChannelSelector=\"G\"/>" +
    "<feImage href=\"#tex\" preserveAspectRatio=\"xMidYMid slice\"/>" +
    "<feDiffuseLighting surfaceScale=\"2\" diffuseConstant=\"0.8\" lighting-color=\"#ff0000\">" +
    "<feSpotLight x=\"1\" y=\"2\" z=\"3\" pointsAtX=\"4\" pointsAtY=\"5\" pointsAtZ=\"6\" " +
    "specularExponent=\"8\" limitingConeAngle=\"20\"/></feDiffuseLighting>" +
    "<feSpecularLighting surfaceScale=\"1\" specularConstant=\"0.5\" " +
    "specularExponent=\"20\" lighting-color=\"#00ff00\">" +
    "<feDistantLight azimuth=\"45\" elevation=\"60\"/></feSpecularLighting>" +
    "</filter>" +
    "<rect width=\"40\" height=\"40\" filter=\"url(#f)\"/>" +
    "</svg>"

@Test
public class SvgRoundTripM4_test {
    /** 新标签、新属性、光源子元素顺序：解析 → 生成 → 解析。 */
    @TestCase
    public func filterRoundTrip(): Unit {
        let document = SvgParser.parse(M4_FILTER_ROUND_TRIP)
        let serialized = document.toString()
        let reparsed = SvgParser.parse(serialized)
        @Assert(reparsed.root.child("filter").isSome())
        let filter = (reparsed.root.child("filter").getOrThrow() as SvgFilter).getOrThrow()
        @Assert(filter.primitives.size == 8)

        let transfer = (filter.primitives[0] as SvgFeComponentTransfer).getOrThrow()
        @Assert(transfer.children.size == 2)
        let funcR = (transfer.childrenOf("feFuncR")[0] as SvgFeFuncR).getOrThrow()
        @Assert(funcR.functionType == SvgTransferFunctionType.Gamma)
        @Assert(funcR.amplitude == 2.0)
        @Assert(funcR.exponent == 0.5)
        let funcG = (transfer.childrenOf("feFuncG")[0] as SvgFeFuncG).getOrThrow()
        @Assert(funcG.functionType == SvgTransferFunctionType.Table)
        @Assert(funcG.tableValues == [0.0, 0.5, 1.0])

        let morphology = (filter.primitives[1] as SvgFeMorphology).getOrThrow()
        @Assert(morphology.operatorKind == SvgMorphologyOperator.Dilate)
        @Assert(morphology.radius.values == [1.0, 2.0])

        let convolve = (filter.primitives[2] as SvgFeConvolveMatrix).getOrThrow()
        @Assert(convolve.order.values == [3.0])
        @Assert(convolve.kernelMatrix.size == 9)
        @Assert(convolve.divisor == Some(1.0))
        @Assert(convolve.edgeMode == SvgEdgeMode.Wrap)
        @Assert(convolve.preserveAlpha)

        let turbulence = (filter.primitives[3] as SvgFeTurbulence).getOrThrow()
        @Assert(turbulence.turbulenceType == SvgTurbulenceType.FractalNoise)
        @Assert(turbulence.baseFrequency.values == [0.05, 0.1])
        @Assert(turbulence.numOctaves == 3)
        @Assert(turbulence.seed == 7.0)
        @Assert(turbulence.stitchTiles)

        let displacement = (filter.primitives[4] as SvgFeDisplacementMap).getOrThrow()
        @Assert(displacement.in2 == Some("noise"))
        @Assert(displacement.scale == 4.0)
        @Assert(displacement.xChannelSelector == SvgChannelSelector.R)
        @Assert(displacement.yChannelSelector == SvgChannelSelector.G)

        let image = (filter.primitives[5] as SvgFeImage).getOrThrow()
        @Assert(image.href == Some("#tex"))
        @Assert(image.preserveAspectRatio.slice)

        let diffuse = (filter.primitives[6] as SvgFeDiffuseLighting).getOrThrow()
        @Assert(diffuse.surfaceScale == 2.0)
        @Assert(diffuse.diffuseConstant == 0.8)
        let spot = (diffuse.lightSource().getOrThrow() as SvgFeSpotLight).getOrThrow()
        @Assert(spot.x == 1.0 && spot.y == 2.0 && spot.z == 3.0)
        @Assert(spot.pointsAtX == 4.0 && spot.pointsAtY == 5.0 && spot.pointsAtZ == 6.0)
        @Assert(spot.limitingConeAngle == Some(20.0))

        let specular = (filter.primitives[7] as SvgFeSpecularLighting).getOrThrow()
        @Assert(specular.specularExponent == 20.0)
        let distant = (specular.lightSource().getOrThrow() as SvgFeDistantLight).getOrThrow()
        @Assert(distant.azimuth == 45.0)
        @Assert(distant.elevation == 60.0)

        @Assert(reparsed.toString() == serialized)
    }

    /** 非法结构：多光源、feComponentTransfer 混入非 feFunc、feImage 缺 href 均 warning。 */
    @TestCase
    public func invalidStructures(): Unit {
        let document = SvgParser.parse(
            "<svg><filter id=\"f\">" +
            "<feDiffuseLighting><feDistantLight/><fePointLight/></feDiffuseLighting>" +
            "<feComponentTransfer><feFuncR/><feGaussianBlur/></feComponentTransfer>" +
            "<feImage/>" +
            "</filter></svg>"
        )
        let filter = (document.root.child("filter").getOrThrow() as SvgFilter).getOrThrow()
        let diffuse = (filter.primitives[0] as SvgFeDiffuseLighting).getOrThrow()
        // 多光源保留第一个，求值时只使用第一个。
        @Assert(diffuse.lightSource().getOrThrow() is SvgFeDistantLight)
        var multipleLightWarning = false
        var nonFuncWarning = false
        var missingHrefWarning = false
        for (warning in document.warnings) {
            if (warning.contains("光源")) {
                multipleLightWarning = true
            }
            if (warning.contains("feFunc")) {
                nonFuncWarning = true
            }
            if (warning.contains("feImage") && warning.contains("href")) {
                missingHrefWarning = true
            }
        }
        @Assert(multipleLightWarning)
        @Assert(nonFuncWarning)
        @Assert(missingHrefWarning)
    }
}
