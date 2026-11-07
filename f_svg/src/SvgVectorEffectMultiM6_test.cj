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
public class SvgVectorEffectMultiM6_test {
    private func styleOf(attributes: String): (SvgComputedStyle, SvgStyleResolver) {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect id=\"r\" " + attributes + "/></svg>"
        )
        let resolver = SvgStyleResolver()
        let tree = resolver.compute(document.root)
        (m5StyleOf(tree, document.elementById("r")), resolver)
    }

    /** 空格分隔多值进入计算样式；未知值被跳过并 warning。 */
    @TestCase
    public func multiValueParsing(): Unit {
        let (style, resolver) = styleOf(
            "vector-effect=\"fixed-position non-scaling-size non-rotation\""
        )
        let effects = style.vectorEffects()
        @Assert(effects.size == 3)
        @Assert(effects[0] == SvgVectorEffect.FixedPosition)
        @Assert(effects[1] == SvgVectorEffect.NonScalingSize)
        @Assert(effects[2] == SvgVectorEffect.NonRotation)
        @Assert(style.vectorEffect() == SvgVectorEffect.FixedPosition)
        @Assert(resolver.warnings.size == 0)

        let (partial, partialResolver) = styleOf(
            "vector-effect=\"non-rotation bogus fixed-position\""
        )
        let partialEffects = partial.vectorEffects()
        @Assert(partialEffects.size == 2)
        var warned = false
        for (warning in partialResolver.warnings) {
            if (warning.contains("vector-effect")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 应用顺序固定，与声明顺序无关。 */
    @TestCase
    public func fixedApplicationOrder(): Unit {
        let matrix = SvgMatrix.translate(10.0, 20.0)
            .multiply(SvgMatrix.rotate(30.0))
            .multiply(SvgMatrix.scale(2.0, 2.0))
        let local = SvgMatrix.translate(3.0, 4.0)
        let first = SvgVectorEffect2.apply(
            matrix,
            [SvgVectorEffect.FixedPosition, SvgVectorEffect.NonScalingSize, SvgVectorEffect.NonRotation],
            local: local
        )
        let second = SvgVectorEffect2.apply(
            matrix,
            [SvgVectorEffect.NonRotation, SvgVectorEffect.FixedPosition, SvgVectorEffect.NonScalingSize],
            local: local
        )
        @Assert(first == second)
    }

    private func rectMatrix(attributes: String): SvgMatrix {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<g transform=\"translate(10,20) rotate(30) scale(2)\">" +
            "<rect id=\"r\" x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\" " +
            attributes + "/></g></svg>"
        )
        for (command in SvgRenderTreeBuilder().build(document).commands) {
            if (command.tag == "rect") {
                return command.matrix
            }
        }
        throw invalidValue("缺少 rect 指令")
    }

    /** 渲染树按完整数组接线，两种声明顺序得到相同矩阵。 */
    @TestCase
    public func renderTreeWiring(): Unit {
        let first = rectMatrix(
            "vector-effect=\"fixed-position non-scaling-size non-rotation\""
        )
        let second = rectMatrix(
            "vector-effect=\"non-rotation fixed-position non-scaling-size\""
        )
        @Assert(first == second)
        @Assert(first != rectMatrix("vector-effect=\"none\""))
    }
}
