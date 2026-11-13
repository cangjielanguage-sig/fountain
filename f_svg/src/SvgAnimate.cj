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

/** `calcMode` 到 SVG 属性拼写。 */
internal func svgCalcModeAttrName(mode: SvgCalcMode): String {
    match (mode) {
        case Linear => "linear"
        case Discrete => "discrete"
        case Spline => "spline"
        case Paced => "paced"
    }
}

/** SVG `fill` 拼写到生成枚举；未知返回 `None`，原始属性仍保留。 */
internal func svgAnimationFillFromName(name: ?String): ?SvgAnimationFill {
    match (name) {
        case Some(text) =>
            match (text.trimAscii()) {
                case "remove" => Some(SvgAnimationFill.Remove)
                case "freeze" => Some(SvgAnimationFill.Freeze)
                case _ => None
            }
        case None => None
    }
}

/** SVG `restart` 拼写到生成枚举；未知返回 `None`。 */
internal func svgRestartFromName(name: ?String): ?SvgRestart {
    match (name) {
        case Some(text) =>
            match (text.trimAscii()) {
                case "always" => Some(SvgRestart.Always)
                case "whenNotActive" => Some(SvgRestart.WhenNotActive)
                case "never" => Some(SvgRestart.Never)
                case _ => None
            }
        case None => None
    }
}

/** SVG `calcMode` 拼写到既有枚举；未知返回 `None`。 */
internal func svgCalcModeFromName(name: ?String): ?SvgCalcMode {
    match (name) {
        case Some(text) =>
            match (text.trimAscii()) {
                case "linear" => Some(SvgCalcMode.Linear)
                case "discrete" => Some(SvgCalcMode.Discrete)
                case "spline" => Some(SvgCalcMode.Spline)
                case "paced" => Some(SvgCalcMode.Paced)
                case _ => None
            }
        case None => None
    }
}

/**
 * 类型化 `<animate>`。
 *
 * `attributes` 是唯一事实源：setter 走 `setAttr`，getter 读原始属性；
 * 未知取值原样输出，生成侧不校验。
 */
public open class SvgAnimate <: SvgElement {
    public init() {
        super("animate")
    }

    protected init(tag: String) {
        super(tag)
    }

    public mut prop attributeName: ?String {
        get() {
            this.attr("attributeName")
        }
        set(value) {
            this.writeOptionalAttribute("attributeName", value)
        }
    }

    public mut prop from: ?String {
        get() {
            this.attr("from")
        }
        set(value) {
            this.writeOptionalAttribute("from", value)
        }
    }

    public mut prop to: ?String {
        get() {
            this.attr("to")
        }
        set(value) {
            this.writeOptionalAttribute("to", value)
        }
    }

    public mut prop by: ?String {
        get() {
            this.attr("by")
        }
        set(value) {
            this.writeOptionalAttribute("by", value)
        }
    }

    /** 分号分隔的关键帧值，原样保存。 */
    public mut prop values: ?String {
        get() {
            this.attr("values")
        }
        set(value) {
            this.writeOptionalAttribute("values", value)
        }
    }

    public mut prop dur: ?String {
        get() {
            this.attr("dur")
        }
        set(value) {
            this.writeOptionalAttribute("dur", value)
        }
    }

    /** 开始时间表达式；`None` 时移除属性。 */
    public mut prop begin: ?SvgBegin {
        get() {
            match (this.attr("begin")) {
                case Some(text) => Some(SvgBegin.literal(text))
                case None => None
            }
        }
        set(value) {
            this.writeOptionalAttribute("begin", match (value) {
                case Some(begin) => Some(begin.toString())
                case None => None
            })
        }
    }

    /** 结束时间表达式；`None` 时移除属性。 */
    public mut prop end: ?SvgBegin {
        get() {
            match (this.attr("end")) {
                case Some(text) => Some(SvgBegin.literal(text))
                case None => None
            }
        }
        set(value) {
            this.writeOptionalAttribute("end", match (value) {
                case Some(end) => Some(end.toString())
                case None => None
            })
        }
    }

    public mut prop repeatCount: ?String {
        get() {
            this.attr("repeatCount")
        }
        set(value) {
            this.writeOptionalAttribute("repeatCount", value)
        }
    }

    public mut prop repeatDur: ?String {
        get() {
            this.attr("repeatDur")
        }
        set(value) {
            this.writeOptionalAttribute("repeatDur", value)
        }
    }

    public mut prop fill: ?SvgAnimationFill {
        get() {
            svgAnimationFillFromName(this.attr("fill"))
        }
        set(value) {
            this.writeOptionalAttribute("fill", match (value) {
                case Some(fill) => Some(fill.toString())
                case None => None
            })
        }
    }

    public mut prop calcMode: ?SvgCalcMode {
        get() {
            svgCalcModeFromName(this.attr("calcMode"))
        }
        set(value) {
            this.writeOptionalAttribute("calcMode", match (value) {
                case Some(mode) => Some(svgCalcModeAttrName(mode))
                case None => None
            })
        }
    }

    public mut prop keyTimes: ?String {
        get() {
            this.attr("keyTimes")
        }
        set(value) {
            this.writeOptionalAttribute("keyTimes", value)
        }
    }

    public mut prop keySplines: ?String {
        get() {
            this.attr("keySplines")
        }
        set(value) {
            this.writeOptionalAttribute("keySplines", value)
        }
    }

    public mut prop additive: ?String {
        get() {
            this.attr("additive")
        }
        set(value) {
            this.writeOptionalAttribute("additive", value)
        }
    }

    public mut prop accumulate: ?String {
        get() {
            this.attr("accumulate")
        }
        set(value) {
            this.writeOptionalAttribute("accumulate", value)
        }
    }

    public mut prop restart: ?SvgRestart {
        get() {
            svgRestartFromName(this.attr("restart"))
        }
        set(value) {
            this.writeOptionalAttribute("restart", match (value) {
                case Some(restart) => Some(restart.toString())
                case None => None
            })
        }
    }
}
