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

/** `restart` 属性取值。字符串形式即 SVG 拼写。 */
public enum SvgRestart <: Equatable<SvgRestart> & ToString {
    | Always
    | WhenNotActive
    | Never

    public operator func ==(that: SvgRestart): Bool {
        match ((this, that)) {
            case (Always, Always) => true
            case (WhenNotActive, WhenNotActive) => true
            case (Never, Never) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Always => "always"
            case WhenNotActive => "whenNotActive"
            case Never => "never"
        }
    }
}

/** 动画结束后是否保留末值。字符串形式即 SVG 拼写。 */
public enum SvgAnimationFill <: Equatable<SvgAnimationFill> & ToString {
    | Remove
    | Freeze

    public operator func ==(that: SvgAnimationFill): Bool {
        match ((this, that)) {
            case (Remove, Remove) => true
            case (Freeze, Freeze) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Remove => "remove"
            case Freeze => "freeze"
        }
    }
}

/** `animateTransform` 的变换类型。字符串形式即 SVG `type` 拼写。 */
public enum SvgAnimationTransformType <: Equatable<SvgAnimationTransformType> & ToString {
    | Translate
    | Scale
    | Rotate
    | SkewX
    | SkewY

    public operator func ==(that: SvgAnimationTransformType): Bool {
        match ((this, that)) {
            case (Translate, Translate) => true
            case (Scale, Scale) => true
            case (Rotate, Rotate) => true
            case (SkewX, SkewX) => true
            case (SkewY, SkewY) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Translate => "translate"
            case Scale => "scale"
            case Rotate => "rotate"
            case SkewX => "skewX"
            case SkewY => "skewY"
        }
    }
}

/** `animateMotion` 的 `rotate` 取值：自动、自动反向或固定角度。 */
public enum SvgMotionRotate <: Equatable<SvgMotionRotate> & ToString {
    | Auto
    | AutoReverse
    | Fixed(Float64)

    public operator func ==(that: SvgMotionRotate): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (AutoReverse, AutoReverse) => true
            case (Fixed(left), Fixed(right)) => left == right
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case AutoReverse => "auto-reverse"
            case Fixed(angle) => formatSvgNumber(angle)
        }
    }
}
