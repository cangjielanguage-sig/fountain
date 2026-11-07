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
import std.math.*

@Test
public class SvgSvg2M6_test {
    /** vector-effect 三个新值与旧值。 */
    @TestCase
    public func vectorEffectValues(): Unit {
        @Assert(SvgVectorEffect.fromName("none") == SvgVectorEffect.NoEffect)
        @Assert(SvgVectorEffect.fromName("non-scaling-stroke") == SvgVectorEffect.NonScalingStroke)
        @Assert(SvgVectorEffect.fromName("non-scaling-size") == SvgVectorEffect.NonScalingSize)
        @Assert(SvgVectorEffect.fromName("non-rotation") == SvgVectorEffect.NonRotation)
        @Assert(SvgVectorEffect.fromName("fixed-position") == SvgVectorEffect.FixedPosition)
        @Assert(SvgVectorEffect.fromName("bogus").isNone())
        @Assert(SvgVectorEffect.NonScalingSize.toString() == "non-scaling-size")
        @Assert(SvgVectorEffect.NonRotation.toString() == "non-rotation")
        @Assert(SvgVectorEffect.FixedPosition.toString() == "fixed-position")
    }

    /** 去缩放 / 去旋转 / 固定位置与组合。 */
    @TestCase
    public func vectorEffectMatrix(): Unit {
        let matrix = SvgMatrix.translate(10.0, 20.0)
            .multiply(SvgMatrix.rotate(30.0))
            .multiply(SvgMatrix.scale(2.0, 2.0))
        let noScale = SvgVectorEffect2.apply(matrix, [SvgVectorEffect.NonScalingSize])
        @Assert(abs(sqrt(noScale.a * noScale.a + noScale.b * noScale.b) - 1.0) < 1e-9)
        @Assert(abs(noScale.e - 10.0) < 1e-9)
        @Assert(abs(noScale.f - 20.0) < 1e-9)

        let noRotation = SvgVectorEffect2.apply(matrix, [SvgVectorEffect.NonRotation])
        @Assert(abs(noRotation.b) < 1e-9)
        @Assert(abs(sqrt(noRotation.a * noRotation.a + noRotation.b * noRotation.b) - 2.0) < 1e-9)

        let fixed = SvgVectorEffect2.apply(
            matrix,
            [SvgVectorEffect.FixedPosition],
            local: SvgMatrix.translate(5.0, 0.0)
        )
        @Assert(fixed == SvgMatrix.translate(5.0, 0.0))

        let combined = SvgVectorEffect2.apply(
            matrix,
            [SvgVectorEffect.NonScalingSize, SvgVectorEffect.NonRotation]
        )
        @Assert(abs(combined.b) < 1e-9)
        @Assert(abs(sqrt(combined.a * combined.a + combined.b * combined.b) - 1.0) < 1e-9)
    }

    /** non-scaling-stroke 不受新函数影响。 */
    @TestCase
    public func nonScalingStrokeUnaffected(): Unit {
        let matrix = SvgMatrix.scale(2.0, 2.0)
        let result = SvgVectorEffect2.apply(matrix, [SvgVectorEffect.NoEffect])
        @Assert(result == matrix)
        @Assert(SvgVectorEffect.strokeScale(matrix) == 0.5)
        let withStroke = SvgVectorEffect2.apply(matrix, [SvgVectorEffect.NonScalingStroke])
        @Assert(withStroke == matrix)
    }

    /** miter-clip / arcs 解析与渲染不崩溃。 */
    @TestCase
    public func lineJoinValues(): Unit {
        @Assert(SvgLineJoin.fromName("miter-clip") == Some(SvgLineJoin.MiterClip))
        @Assert(SvgLineJoin.fromName("arcs") == Some(SvgLineJoin.Arcs))
        @Assert(SvgLineJoin.fromName("unknown").isNone())
        @Assert(SvgLineJoin.MiterClip.toString() == "miter-clip")
        @Assert(SvgLineJoin.Arcs.toString() == "arcs")
        @Assert(SvgLineJoin.MiterClip.attrName() == "miter-clip")
        @Assert(SvgLineJoin.Arcs.attrName() == "arcs")

        let path = SvgPathData.parse("M0 0 L10 10 L20 0")
        let style = SvgStrokeStyle(
            4.0,
            lineJoin: SvgLineJoin.MiterClip,
            miterLimit: 2.0
        )
        @Assert(SvgStrokeOutliner.outlineContours(
            [ [
                SvgPoint(0.0, 0.0),
                SvgPoint(10.0, 10.0),
                SvgPoint(20.0, 0.0)
            ] ],
            style
        ).size > 0)
    }

    /** 根 auto：按内容包围盒与 viewBox 比例推导。 */
    @TestCase
    public func autoSize(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"auto\" height=\"auto\" " +
            "viewBox=\"0 0 10 20\"><rect x=\"0\" y=\"0\" width=\"10\" height=\"20\"/></svg>"
        )
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(document.root)
        let size = SvgAutoSize.rootSize(document.root, styles, 100.0, 100.0)
        @Assert(size.width > 0.0 && size.height > 0.0)
        @Assert(abs(size.width / size.height - 0.5) < 1e-6)
    }

    /** 未声明 auto 时保持 M5 推导。 */
    @TestCase
    public func explicitSizeUnchanged(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\"/></svg>"
        )
        let viewport = SvgViewport.from(document.root, 300.0, 150.0)
        @Assert(viewport.width == 40.0)
        @Assert(viewport.height == 20.0)
        let resolver = SvgStyleResolver()
        let styles = resolver.compute(document.root)
        let auto = SvgAutoSize.rootSize(document.root, styles, 300.0, 150.0)
        @Assert(auto.width == 40.0)
        @Assert(auto.height == 20.0)
    }
}
