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

@Test
public class SvgAnimateM7_test {
    /** 属性名逐项按 SVG 拼写落盘，值原样保留。 */
    @TestCase
    public func attributeMapping(): Unit {
        let animate = SvgAnimate()
        animate.attributeName = "x"
        animate.from = "10"
        animate.to = "150"
        animate.by = "5"
        animate.values = "0;50;100"
        animate.dur = "2s"
        animate.repeatCount = "indefinite"
        animate.repeatDur = "10s"
        animate.fill = SvgAnimationFill.Freeze
        animate.calcMode = SvgCalcMode.Spline
        animate.keyTimes = "0;0.5;1"
        animate.keySplines = "0 0 1 1;0 0 1 1"
        animate.additive = "sum"
        animate.accumulate = "sum"
        animate.restart = SvgRestart.WhenNotActive

        @Assert(animate.tag == "animate")
        @Assert(animate.attributeName == Some("x"))
        @Assert(animate.from == Some("10"))
        @Assert(animate.to == Some("150"))
        @Assert(animate.by == Some("5"))
        @Assert(animate.values == Some("0;50;100"))
        @Assert(animate.dur == Some("2s"))
        @Assert(animate.repeatCount == Some("indefinite"))
        @Assert(animate.repeatDur == Some("10s"))
        @Assert(animate.fill == Some(SvgAnimationFill.Freeze))
        @Assert(animate.calcMode == Some(SvgCalcMode.Spline))
        @Assert(animate.keyTimes == Some("0;0.5;1"))
        @Assert(animate.keySplines == Some("0 0 1 1;0 0 1 1"))
        @Assert(animate.additive == Some("sum"))
        @Assert(animate.accumulate == Some("sum"))
        @Assert(animate.restart == Some(SvgRestart.WhenNotActive))

        let text = animate.toString()
        @Assert(text.startsWith("<animate "))
        @Assert(text.contains("attributeName=\"x\""))
        @Assert(text.contains("from=\"10\""))
        @Assert(text.contains("to=\"150\""))
        @Assert(text.contains("by=\"5\""))
        @Assert(text.contains("values=\"0;50;100\""))
        @Assert(text.contains("dur=\"2s\""))
        @Assert(text.contains("repeatCount=\"indefinite\""))
        @Assert(text.contains("repeatDur=\"10s\""))
        @Assert(text.contains("fill=\"freeze\""))
        @Assert(text.contains("calcMode=\"spline\""))
        @Assert(text.contains("keyTimes=\"0;0.5;1\""))
        @Assert(text.contains("keySplines=\"0 0 1 1;0 0 1 1\""))
        @Assert(text.contains("additive=\"sum\""))
        @Assert(text.contains("accumulate=\"sum\""))
        @Assert(text.contains("restart=\"whenNotActive\""))
    }

    /** 未知 `calcMode` 等取值走原始属性时原样输出。 */
    @TestCase
    public func unknownValuesPassThrough(): Unit {
        let animate = SvgAnimate()
        animate.setAttr("calcMode", "custom-mode")
        animate.setAttr("dur", "1.25s")
        @Assert(animate.calcMode == Option<SvgCalcMode>.None)
        @Assert(animate.dur == Some("1.25s"))
        let text = animate.toString()
        @Assert(text.contains("calcMode=\"custom-mode\""))
        @Assert(text.contains("dur=\"1.25s\""))
    }

    /** `begin` / `end` 接受 `SvgBegin`；清空时移除属性。 */
    @TestCase
    public func beginAndEndAttributes(): Unit {
        let animate = SvgAnimate()
        animate.begin = SvgBegin.offset(0.0).join(SvgBegin.after("a", 1.0))
        animate.end = SvgBegin.event("click")
        @Assert(animate.attr("begin") == Some("0s; a.end+1s"))
        @Assert(animate.attr("end") == Some("click"))
        @Assert(animate.toString().contains("begin=\"0s; a.end+1s\""))

        animate.begin = Option<SvgBegin>.None
        @Assert(animate.attr("begin") == Option<String>.None)
        @Assert(!animate.toString().contains("begin="))
    }

    /** `animateTransform` 覆盖五种变换类型，并复用动画公共属性。 */
    @TestCase
    public func animateTransformTypeMapping(): Unit {
        let transform = SvgAnimateTransform()
        @Assert(transform.tag == "animateTransform")
        transform.transformType = SvgAnimationTransformType.Translate
        @Assert(transform.attr("type") == Some("translate"))
        transform.transformType = SvgAnimationTransformType.Scale
        @Assert(transform.attr("type") == Some("scale"))
        transform.transformType = SvgAnimationTransformType.Rotate
        @Assert(transform.attr("type") == Some("rotate"))
        transform.transformType = SvgAnimationTransformType.SkewX
        @Assert(transform.attr("type") == Some("skewX"))
        transform.transformType = SvgAnimationTransformType.SkewY
        @Assert(transform.attr("type") == Some("skewY"))
        @Assert(transform.transformType == SvgAnimationTransformType.SkewY)

        transform.attributeName = "transform"
        transform.from = "0"
        transform.to = "360"
        transform.dur = "1s"
        transform.begin = SvgBegin.offset(0.0)
        let text = transform.toString()
        @Assert(text.contains("type=\"skewY\""))
        @Assert(text.contains("attributeName=\"transform\""))
        @Assert(text.contains("from=\"0\""))
        @Assert(text.contains("to=\"360\""))
        @Assert(text.contains("dur=\"1s\""))
        @Assert(text.contains("begin=\"0s\""))
    }

    /** `animateMotion` 的路径、关键点与旋转属性映射。 */
    @TestCase
    public func animateMotionAttributes(): Unit {
        let motion = SvgAnimateMotion()
        @Assert(motion.tag == "animateMotion")
        motion.path = "M0 0L10 10"
        motion.keyPoints = "0;0.5;1"
        motion.rotate = SvgMotionRotate.Fixed(45.0)
        @Assert(motion.path == Some("M0 0L10 10"))
        @Assert(motion.keyPoints == Some("0;0.5;1"))
        @Assert(motion.attr("rotate") == Some("45"))
        let text = motion.toString()
        @Assert(text.contains("path=\"M0 0L10 10\""))
        @Assert(text.contains("keyPoints=\"0;0.5;1\""))
        @Assert(text.contains("rotate=\"45\""))

        motion.rotate = SvgMotionRotate.Auto
        @Assert(motion.attr("rotate") == Some("auto"))
        motion.rotate = SvgMotionRotate.AutoReverse
        @Assert(motion.attr("rotate") == Some("auto-reverse"))
        @Assert(motion.rotate == SvgMotionRotate.AutoReverse)
    }

    /** `mpath` 生成唯一子元素，重复调用替换引用。 */
    @TestCase
    public func animateMotionMpath(): Unit {
        let motion = SvgAnimateMotion()
        let mpath = motion.mpath("#p")
        @Assert(mpath.tag == "mpath")
        @Assert(mpath.href == Some("#p"))
        @Assert(motion.children.size == 1)
        @Assert(motion.toString().contains("<mpath href=\"#p\"/>"))

        let replacement = motion.mpath("#q")
        @Assert(replacement.href == Some("#q"))
        @Assert(motion.children.size == 1)
        @Assert(motion.toString().contains("<mpath href=\"#q\"/>"))
        @Assert(!motion.toString().contains("#p"))
    }

    /** `set` 的四个属性映射，重复赋值保持属性原位置。 */
    @TestCase
    public func setElementAttributes(): Unit {
        let element = SvgSet()
        @Assert(element.tag == "set")
        element.attributeName = "visibility"
        element.to = "hidden"
        element.begin = SvgBegin.offset(1.0)
        element.restart = SvgRestart.Never
        @Assert(element.attributeName == Some("visibility"))
        @Assert(element.to == Some("hidden"))
        @Assert(element.attr("begin") == Some("1s"))
        @Assert(element.restart == Some(SvgRestart.Never))
        let text = element.toString()
        @Assert(text.contains("attributeName=\"visibility\""))
        @Assert(text.contains("to=\"hidden\""))
        @Assert(text.contains("begin=\"1s\""))
        @Assert(text.contains("restart=\"never\""))

        let sizeBefore = element.attributes.size
        element.attributeName = "opacity"
        @Assert(element.attributeName == Some("opacity"))
        @Assert(element.attributes.size == sizeBefore)
        @Assert(element.attributes[0].name.local == "attributeName")
    }

    /** 五个动画标签不进入 `SvgTag` 注册表。 */
    @TestCase
    public func animationTagsStayUnknown(): Unit {
        @Assert(!SvgTag.isKnown("animate"))
        @Assert(!SvgTag.isKnown("animateTransform"))
        @Assert(!SvgTag.isKnown("animateMotion"))
        @Assert(!SvgTag.isKnown("set"))
        @Assert(!SvgTag.isKnown("mpath"))
    }

    /** 生成文本经宽松模式解析后，动画标签与属性保持一致。 */
    @TestCase
    public func generatedAnimationSurvivesParse(): Unit {
        let root = SvgRoot()
        let rect = SvgRect(
            x: Some(SvgLength(10.0, unit: SvgLengthUnit.Px)),
            width: Some(SvgLength(40.0, unit: SvgLengthUnit.Px)),
            height: Some(SvgLength(40.0, unit: SvgLengthUnit.Px))
        )
        let animate = SvgAnimate()
        animate.attributeName = "x"
        animate.from = "10"
        animate.to = "150"
        animate.dur = "2s"
        animate.begin = SvgBegin.offset(0.0)
        animate.repeatCount = "indefinite"
        rect.appendElement(animate)
        root.appendElement(rect)

        let text = writeSvgString(SvgDocument(root))
        let parsed = SvgParser.parse(text)
        let parsedRect = parsed.root.child("rect")
        match (parsedRect) {
            case Some(found) =>
                let parsedAnimate = found.child("animate")
                match (parsedAnimate) {
                    case Some(animation) =>
                        @Assert(animation.attr("attributeName") == Some("x"))
                        @Assert(animation.attr("from") == Some("10"))
                        @Assert(animation.attr("to") == Some("150"))
                        @Assert(animation.attr("dur") == Some("2s"))
                        @Assert(animation.attr("begin") == Some("0s"))
                        @Assert(animation.attr("repeatCount") == Some("indefinite"))
                    case None => @Fail("解析结果缺少 animate 子元素")
                }
            case None => @Fail("解析结果缺少 rect 子元素")
        }
    }
}
