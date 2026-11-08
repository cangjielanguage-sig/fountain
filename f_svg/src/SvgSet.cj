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

/** 类型化 `<set>`：一次性属性赋值。 */
public class SvgSet <: SvgElement {
    public init() {
        super("set")
    }

    public mut prop attributeName: ?String {
        get() {
            this.attr("attributeName")
        }
        set(value) {
            this.writeOptionalAttribute("attributeName", value)
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
