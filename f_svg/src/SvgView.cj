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

/**
 * `view` 元素：只承载视口映射信息，不产生绘制指令。
 */
public class SvgView <: SvgElement {
    private let viewBoxCache = SvgValueCache<SvgViewBox>()
    private let aspectCache = SvgValueCache<SvgPreserveAspectRatio>()

    public init() {
        super("view")
    }

    public mut prop viewBox: ?SvgViewBox {
        get() {
            this.viewBoxCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("viewBox")) {
                        case Some(text) => tryParseSvgViewBox(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(box) => this.setAttr("viewBox", box.toString())
                case None => this.removeAttr("viewBox")
            }
        }
    }

    public mut prop preserveAspectRatio: SvgPreserveAspectRatio {
        get() {
            this.aspectCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("preserveAspectRatio")) {
                        case Some(text) => tryParseSvgPreserveAspectRatio(text)
                        case None => None
                    }
                }
            ) ?? SvgPreserveAspectRatio.Default
        }
        set(value) {
            this.setAttr("preserveAspectRatio", value.toString())
        }
    }

    public mut prop viewTarget: ?String {
        get() {
            this.attr("viewTarget")
        }
        set(value) {
            this.writeOptionalAttribute("viewTarget", value)
        }
    }
}
