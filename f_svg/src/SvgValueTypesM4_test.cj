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
public class SvgValueTypesM4_test {
    /** 文本排版枚举的解析、字符串形式与别名。 */
    @TestCase
    public func textEnums(): Unit {
        @Assert(SvgWritingMode.fromName("lr-tb") == Some(SvgWritingMode.LrTb))
        @Assert(SvgWritingMode.fromName("lr") == Some(SvgWritingMode.Lr))
        @Assert(SvgWritingMode.fromName("tb") == Some(SvgWritingMode.Tb))
        @Assert(SvgWritingMode.fromName("tb-rl") == Some(SvgWritingMode.TbRl))
        @Assert(SvgWritingMode.fromName("TB-RL") == Some(SvgWritingMode.TbRl))
        @Assert(SvgWritingMode.fromName("bogus").isNone())
        @Assert(SvgWritingMode.TbRl.toString() == "tb-rl")
        @Assert(SvgWritingMode.Lr.toString() == "lr")

        @Assert(SvgDominantBaseline.fromName("auto") == Some(SvgDominantBaseline.Auto))
        @Assert(SvgDominantBaseline.fromName("alphabetic") == Some(SvgDominantBaseline.Alphabetic))
        @Assert(SvgDominantBaseline.fromName("ideographic") == Some(SvgDominantBaseline.Ideographic))
        @Assert(SvgDominantBaseline.fromName("middle") == Some(SvgDominantBaseline.Middle))
        @Assert(SvgDominantBaseline.fromName("central") == Some(SvgDominantBaseline.Central))
        @Assert(SvgDominantBaseline.fromName("hanging") == Some(SvgDominantBaseline.Hanging))
        @Assert(SvgDominantBaseline.fromName("mathematical") == Some(SvgDominantBaseline.Mathematical))
        @Assert(SvgDominantBaseline.fromName("text-before-edge") == Some(SvgDominantBaseline.TextBeforeEdge))
        @Assert(SvgDominantBaseline.fromName("text-after-edge") == Some(SvgDominantBaseline.TextAfterEdge))
        @Assert(SvgDominantBaseline.TextBeforeEdge.toString() == "text-before-edge")
        @Assert(SvgDominantBaseline.fromName("top").isNone())

        @Assert(SvgAlignmentBaseline.fromName("baseline") == Some(SvgAlignmentBaseline.Baseline))
        @Assert(SvgAlignmentBaseline.fromName("before-edge") == Some(SvgAlignmentBaseline.BeforeEdge))
        @Assert(SvgAlignmentBaseline.fromName("after-edge") == Some(SvgAlignmentBaseline.AfterEdge))
        @Assert(SvgAlignmentBaseline.fromName("middle") == Some(SvgAlignmentBaseline.Middle))
        @Assert(SvgAlignmentBaseline.Auto.toString() == "auto")
        @Assert(SvgAlignmentBaseline.fromName("top").isNone())
    }

    /** 基线偏移值：关键字与长度。 */
    @TestCase
    public func baselineShift(): Unit {
        @Assert(SvgBaselineShift.fromName("baseline") == Some(SvgBaselineShift.Baseline))
        @Assert(SvgBaselineShift.fromName("sub") == Some(SvgBaselineShift.Sub))
        @Assert(SvgBaselineShift.fromName("super") == Some(SvgBaselineShift.Super))
        @Assert(SvgBaselineShift.fromName("10%") == Some(SvgBaselineShift.Length(SvgLength(10.0, unit: SvgLengthUnit.Percent))))
        @Assert(SvgBaselineShift.fromName("2px") == Some(SvgBaselineShift.Length(SvgLength(2.0, unit: SvgLengthUnit.Px))))
        @Assert(SvgBaselineShift.fromName("wat").isNone())
        @Assert(SvgBaselineShift.Baseline.toString() == "baseline")
        @Assert(SvgBaselineShift.Length(SvgLength(10.0, unit: SvgLengthUnit.Percent)).toString() == "10%")
    }

    /** 装饰线解析：组合、去重、none 优先。 */
    @TestCase
    public func textDecoration(): Unit {
        let combined = SvgTextDecoration.tryParse("line-through underline")
        @Assert(combined.isSome())
        @Assert(combined.getOrThrow().underline)
        @Assert(combined.getOrThrow().lineThrough)
        @Assert(!combined.getOrThrow().overline)
        @Assert(combined.getOrThrow().toString() == "underline line-through")

        let deduped = SvgTextDecoration.tryParse("overline underline overline")
        @Assert(deduped.getOrThrow().toString() == "underline overline")

        @Assert(SvgTextDecoration.tryParse("none").getOrThrow().isNone())
        @Assert(SvgTextDecoration.tryParse("").isNone())
        @Assert(SvgTextDecoration.tryParse("blink").isNone())
        @Assert(SvgTextDecoration.none.toString() == "none")
    }

    /** 渲染枚举的解析、字符串形式与大小写。 */
    @TestCase
    public func renderEnums(): Unit {
        @Assert(SvgVectorEffect.fromName("none") == Some(SvgVectorEffect.NoEffect))
        @Assert(SvgVectorEffect.fromName("non-scaling-stroke") == Some(SvgVectorEffect.NonScalingStroke))
        @Assert(SvgVectorEffect.NonScalingStroke.toString() == "non-scaling-stroke")
        @Assert(SvgVectorEffect.NoEffect.toString() == "none")
        @Assert(SvgVectorEffect.fromName("scaling-stroke").isNone())

        @Assert(SvgOverflow.fromName("visible") == Some(SvgOverflow.Visible))
        @Assert(SvgOverflow.fromName("hidden") == Some(SvgOverflow.Hidden))
        @Assert(SvgOverflow.fromName("scroll") == Some(SvgOverflow.Scroll))
        @Assert(SvgOverflow.fromName("auto") == Some(SvgOverflow.Auto))
        @Assert(SvgOverflow.Hidden.toString() == "hidden")
        @Assert(SvgOverflow.fromName("clip").isNone())
        @Assert(!SvgOverflow.Visible.clips())
        @Assert(SvgOverflow.Hidden.clips())
    }

    /** 滤镜枚举的字符串形式与非法值回退。 */
    @TestCase
    public func filterEnums(): Unit {
        @Assert(SvgTransferFunctionType.fromName("identity") == Some(SvgTransferFunctionType.Identity))
        @Assert(SvgTransferFunctionType.fromName("table") == Some(SvgTransferFunctionType.Table))
        @Assert(SvgTransferFunctionType.fromName("discrete") == Some(SvgTransferFunctionType.Discrete))
        @Assert(SvgTransferFunctionType.fromName("linear") == Some(SvgTransferFunctionType.Linear))
        @Assert(SvgTransferFunctionType.fromName("gamma") == Some(SvgTransferFunctionType.Gamma))
        @Assert(SvgTransferFunctionType.Gamma.toString() == "gamma")

        @Assert(SvgMorphologyOperator.fromName("erode") == Some(SvgMorphologyOperator.Erode))
        @Assert(SvgMorphologyOperator.fromName("dilate") == Some(SvgMorphologyOperator.Dilate))
        @Assert(SvgMorphologyOperator.Erode.toString() == "erode")

        @Assert(SvgEdgeMode.fromName("duplicate") == Some(SvgEdgeMode.Duplicate))
        @Assert(SvgEdgeMode.fromName("wrap") == Some(SvgEdgeMode.Wrap))
        @Assert(SvgEdgeMode.fromName("none") == Some(SvgEdgeMode.NoEdge))
        @Assert(SvgEdgeMode.Wrap.toString() == "wrap")

        @Assert(SvgChannelSelector.fromName("R") == Some(SvgChannelSelector.R))
        @Assert(SvgChannelSelector.fromName("r") == Some(SvgChannelSelector.R))
        @Assert(SvgChannelSelector.fromName("G") == Some(SvgChannelSelector.G))
        @Assert(SvgChannelSelector.fromName("B") == Some(SvgChannelSelector.B))
        @Assert(SvgChannelSelector.fromName("A") == Some(SvgChannelSelector.A))
        @Assert(SvgChannelSelector.A.toString() == "A")

        @Assert(SvgTurbulenceType.fromName("fractalNoise") == Some(SvgTurbulenceType.FractalNoise))
        @Assert(SvgTurbulenceType.fromName("turbulence") == Some(SvgTurbulenceType.Turbulence))
        @Assert(SvgTurbulenceType.FractalNoise.toString() == "fractalNoise")
    }

    /** 非法值回退到规范缺省并追加 warning。 */
    @TestCase
    public func enumFallbacks(): Unit {
        let warnings = ArrayList<String>()
        @Assert(SvgVectorEffect.fromNameOrWarn(Some("scaling-stroke"), warnings, "vector-effect") ==
            SvgVectorEffect.NoEffect)
        @Assert(warnings.size == 1)
        @Assert(warnings[0].contains("vector-effect"))

        let overflowWarnings = ArrayList<String>()
        @Assert(SvgOverflow.fromNameOrWarn(Some("clip"), overflowWarnings, "overflow") ==
            SvgOverflow.Hidden)

        let channelWarnings = ArrayList<String>()
        @Assert(SvgChannelSelector.fromNameOrWarn(Some("Z"), channelWarnings, "yChannelSelector") ==
            SvgChannelSelector.A)
        @Assert(channelWarnings.size == 1)

        let baselineWarnings = ArrayList<String>()
        @Assert(SvgDominantBaseline.fromNameOrWarn(Some("top"), baselineWarnings, "dominant-baseline") ==
            SvgDominantBaseline.Auto)
        @Assert(baselineWarnings.size == 1)

        let transferWarnings = ArrayList<String>()
        @Assert(SvgTransferFunctionType.fromNameOrWarn(Some("wat"), transferWarnings, "type") ==
            SvgTransferFunctionType.Identity)

        let morphologyWarnings = ArrayList<String>()
        @Assert(SvgMorphologyOperator.fromNameOrWarn(Some("wat"), morphologyWarnings, "operator") ==
            SvgMorphologyOperator.Erode)

        let edgeWarnings = ArrayList<String>()
        @Assert(SvgEdgeMode.fromNameOrWarn(Some("wat"), edgeWarnings, "edgeMode") == SvgEdgeMode.Duplicate)

        let turbulenceWarnings = ArrayList<String>()
        @Assert(SvgTurbulenceType.fromNameOrWarn(Some("wat"), turbulenceWarnings, "type") ==
            SvgTurbulenceType.Turbulence)

        let writingWarnings = ArrayList<String>()
        @Assert(SvgWritingMode.fromNameOrWarn(Some("sideways"), writingWarnings, "writing-mode") ==
            SvgWritingMode.LrTb)
    }
}
