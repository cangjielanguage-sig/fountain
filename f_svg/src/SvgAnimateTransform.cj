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

/** SVG `type` 拼写到变换类型；未知返回 `None`。 */
internal func svgAnimationTransformTypeFromName(name: String): ?SvgAnimationTransformType {
    match (name.trimAscii()) {
        case "translate" => Some(SvgAnimationTransformType.Translate)
        case "scale" => Some(SvgAnimationTransformType.Scale)
        case "rotate" => Some(SvgAnimationTransformType.Rotate)
        case "skewX" => Some(SvgAnimationTransformType.SkewX)
        case "skewY" => Some(SvgAnimationTransformType.SkewY)
        case _ => None
    }
}

/** 类型化 `<animateTransform>`。 */
public class SvgAnimateTransform <: SvgAnimate {
    public init() {
        super("animateTransform")
    }

    /**
     * 变换类型。
     *
     * 属性缺失时 getter 返回 `Translate`，但构造时不写 `type`；
     * 只有 setter 被调用才落盘。
     */
    public mut prop transformType: SvgAnimationTransformType {
        get() {
            match (this.attr("type")) {
                case Some(text) => svgAnimationTransformTypeFromName(text) ?? SvgAnimationTransformType.Translate
                case None => SvgAnimationTransformType.Translate
            }
        }
        set(value) {
            this.setAttr("type", value.toString())
        }
    }
}
