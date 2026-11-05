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
public class SvgFilterModelM4_test {
    /** 15 个新元素都映射为独立类型，primitives 只含滤镜原语。 */
    @TestCase
    public func newPrimitiveTypes(): Unit {
        let document = SvgParser.parse(
            "<svg><filter id=\"f\">" +
            "<feComponentTransfer><feFuncR type=\"linear\"/><feFuncG/><feFuncB/>" +
            "<feFuncA type=\"gamma\"/></feComponentTransfer>" +
            "<feMorphology operator=\"dilate\" radius=\"2\"/>" +
            "<feConvolveMatrix order=\"3\" kernelMatrix=\"0 0 0 0 1 0 0 0 0\"/>" +
            "<feTurbulence type=\"fractalNoise\" baseFrequency=\"0.05 0.1\" numOctaves=\"3\"/>" +
            "<feDisplacementMap scale=\"5\" xChannelSelector=\"R\" yChannelSelector=\"G\"/>" +
            "<feImage href=\"mem://tex\"/>" +
            "<feDiffuseLighting><feDistantLight azimuth=\"45\" elevation=\"60\"/>" +
            "</feDiffuseLighting>" +
            "<feSpecularLighting><fePointLight x=\"1\" y=\"2\" z=\"3\"/></feSpecularLighting>" +
            "<feFlood/>" +
            "</filter></svg>"
        )
        let filter = (document.root.child("filter").getOrThrow() as SvgFilter).getOrThrow()
        @Assert(filter.primitives.size == 9)
        @Assert(filter.primitives[0] is SvgFeComponentTransfer)
        @Assert(filter.primitives[1] is SvgFeMorphology)
        @Assert(filter.primitives[2] is SvgFeConvolveMatrix)
        @Assert(filter.primitives[3] is SvgFeTurbulence)
        @Assert(filter.primitives[4] is SvgFeDisplacementMap)
        @Assert(filter.primitives[5] is SvgFeImage)
        @Assert(filter.primitives[6] is SvgFeDiffuseLighting)
        @Assert(filter.primitives[7] is SvgFeSpecularLighting)

        let transfer = (filter.primitives[0] as SvgFeComponentTransfer).getOrThrow()
        @Assert(transfer.children.size == 4)
        @Assert(transfer.childrenOf("feFuncR").size == 1)
        let funcR = (transfer.childrenOf("feFuncR")[0] as SvgFeFuncR).getOrThrow()
        @Assert(funcR.functionType == SvgTransferFunctionType.Linear)

        let diffuse = (filter.primitives[6] as SvgFeDiffuseLighting).getOrThrow()
        @Assert(diffuse.lightSource().isSome())
        @Assert(diffuse.lightSource().getOrThrow() is SvgFeDistantLight)

        let specular = (filter.primitives[7] as SvgFeSpecularLighting).getOrThrow()
        @Assert(specular.lightSource().getOrThrow() is SvgFePointLight)
    }

    /** 属性默认值。 */
    @TestCase
    public func defaults(): Unit {
        let fn = SvgFeFuncR()
        @Assert(fn.functionType == SvgTransferFunctionType.Identity)
        @Assert(fn.tableValues.size == 0)
        @Assert(fn.slope == 1.0)
        @Assert(fn.intercept == 0.0)
        @Assert(fn.amplitude == 1.0)
        @Assert(fn.exponent == 1.0)
        @Assert(fn.offset == 0.0)

        let morphology = SvgFeMorphology()
        @Assert(morphology.operatorKind == SvgMorphologyOperator.Erode)
        @Assert(morphology.radius.values.size == 0)

        let convolve = SvgFeConvolveMatrix()
        @Assert(convolve.order.values == [3.0])
        @Assert(convolve.kernelMatrix.size == 0)
        @Assert(convolve.divisor.isNone())
        @Assert(convolve.bias == 0.0)
        @Assert(convolve.targetX.isNone())
        @Assert(convolve.targetY.isNone())
        @Assert(convolve.edgeMode == SvgEdgeMode.Duplicate)
        @Assert(!convolve.preserveAlpha)

        let turbulence = SvgFeTurbulence()
        @Assert(turbulence.turbulenceType == SvgTurbulenceType.Turbulence)
        @Assert(turbulence.baseFrequency.values.size == 0)
        @Assert(turbulence.numOctaves == 1)
        @Assert(turbulence.seed == 0.0)
        @Assert(!turbulence.stitchTiles)

        let displacement = SvgFeDisplacementMap()
        @Assert(displacement.scale == 0.0)
        @Assert(displacement.xChannelSelector == SvgChannelSelector.A)
        @Assert(displacement.yChannelSelector == SvgChannelSelector.A)

        let image = SvgFeImage()
        @Assert(image.href.isNone())
        @Assert(image.preserveAspectRatio == SvgPreserveAspectRatio.Default)

        let diffuse = SvgFeDiffuseLighting()
        @Assert(diffuse.surfaceScale == 1.0)
        @Assert(diffuse.diffuseConstant == 1.0)
        @Assert(diffuse.lightingColor.color.isSome())
        @Assert(diffuse.lightingColor.color.getOrThrow() == SvgColor.White)
        @Assert(diffuse.lightSource().isNone())

        let specular = SvgFeSpecularLighting()
        @Assert(specular.surfaceScale == 1.0)
        @Assert(specular.specularConstant == 1.0)
        @Assert(specular.specularExponent == 1.0)
        @Assert(specular.lightingColor.color.getOrThrow() == SvgColor.White)

        let distant = SvgFeDistantLight()
        @Assert(distant.azimuth == 0.0)
        @Assert(distant.elevation == 0.0)
        let point = SvgFePointLight()
        @Assert(point.x == 0.0 && point.y == 0.0 && point.z == 0.0)
        let spot = SvgFeSpotLight()
        @Assert(spot.pointsAtX == 0.0 && spot.pointsAtY == 0.0 && spot.pointsAtZ == 0.0)
        @Assert(spot.specularExponent == 1.0)
        @Assert(spot.limitingConeAngle.isNone())
    }

    /** 属性读写与序列化回写。 */
    @TestCase
    public func readWrite(): Unit {
        let fn = SvgFeFuncG()
        fn.functionType = SvgTransferFunctionType.Table
        fn.tableValues = [0.0, 0.25, 1.0]
        fn.slope = 2.0
        fn.intercept = 0.1
        fn.amplitude = 3.0
        fn.exponent = 0.5
        fn.offset = 0.2
        @Assert(fn.attr("type") == Some("table"))
        @Assert(fn.tableValues.size == 3)
        @Assert(fn.attr("slope") == Some("2"))

        let morphology = SvgFeMorphology()
        morphology.operatorKind = SvgMorphologyOperator.Dilate
        morphology.radius = SvgNumberList([2.0, 3.0])
        @Assert(morphology.attr("operator") == Some("dilate"))
        @Assert(morphology.attr("radius") == Some("2,3"))

        let convolve = SvgFeConvolveMatrix()
        convolve.order = SvgNumberList([3.0, 5.0])
        convolve.kernelMatrix = [1.0, 0.0, -1.0]
        convolve.divisor = Some(2.0)
        convolve.bias = 0.5
        convolve.targetX = Some(1)
        convolve.edgeMode = SvgEdgeMode.Wrap
        convolve.preserveAlpha = true
        @Assert(convolve.attr("order") == Some("3,5"))
        @Assert(convolve.attr("divisor") == Some("2"))
        @Assert(convolve.attr("edgeMode") == Some("wrap"))
        @Assert(convolve.preserveAlpha)

        let turbulence = SvgFeTurbulence()
        turbulence.turbulenceType = SvgTurbulenceType.FractalNoise
        turbulence.baseFrequency = SvgNumberList([0.05, 0.1])
        turbulence.numOctaves = 4
        turbulence.seed = 7.0
        turbulence.stitchTiles = true
        @Assert(turbulence.attr("type") == Some("fractalNoise"))
        @Assert(turbulence.attr("baseFrequency") == Some("0.05,0.1"))
        @Assert(turbulence.attr("numOctaves") == Some("4"))
        @Assert(turbulence.attr("stitchTiles") == Some("stitch"))

        let image = SvgFeImage()
        image.href = "mem://tex"
        @Assert(image.href == Some("mem://tex"))
        @Assert(image.attr(SvgNamespaces.XLINK, "href") == Some("mem://tex"))

        let diffuse = SvgFeDiffuseLighting()
        diffuse.surfaceScale = 2.0
        diffuse.diffuseConstant = 0.5
        diffuse.lightingColor = SvgPaint.of(SvgColor.fromRgb(255, 0, 0))
        @Assert(diffuse.attr("lighting-color") == Some("#ff0000"))

        let distant = SvgFeDistantLight()
        distant.azimuth = 30.0
        distant.elevation = 60.0
        @Assert(distant.attr("azimuth") == Some("30"))

        let spot = SvgFeSpotLight()
        spot.limitingConeAngle = Some(20.0)
        @Assert(spot.attr("limitingConeAngle") == Some("20"))
    }

    /** 新标签全部通过 SvgTag 识别。 */
    @TestCase
    public func tagMapping(): Unit {
        for (tag in [
            "feComponentTransfer", "feFuncR", "feFuncG", "feFuncB", "feFuncA",
            "feMorphology", "feConvolveMatrix", "feTurbulence", "feDisplacementMap",
            "feImage", "feDiffuseLighting", "feSpecularLighting", "feDistantLight",
            "fePointLight", "feSpotLight"
        ]) {
            @Assert(SvgTag.isKnown(tag))
            @Assert(SvgTag.create(tag).isSome())
        }
    }
}
