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

/** `svg` 根元素。缺省尺寸保持 `None`，由渲染器按 100% 解释。 */
public class SvgRoot <: SvgElement {
    private let xCache = SvgValueCache<SvgLength>()
    private let yCache = SvgValueCache<SvgLength>()
    private let widthCache = SvgValueCache<SvgLength>()
    private let heightCache = SvgValueCache<SvgLength>()
    private let viewBoxCache = SvgValueCache<SvgViewBox>()
    private let aspectCache = SvgValueCache<SvgPreserveAspectRatio>()

    public init(width!: ?SvgLength = None, height!: ?SvgLength = None) {
        super("svg")
        match (width) {
            case Some(length) => this.setAttr("width", length.toString())
            case None => ()
        }
        match (height) {
            case Some(length) => this.setAttr("height", length.toString())
            case None => ()
        }
    }

    public mut prop x: ?SvgLength {
        get() {
            this.xCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("x")) {
                        case Some(text) => SvgLength.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            this.writeOptionalAttribute("x", match (value) {
                case Some(length) => Some(length.toString())
                case None => None
            })
        }
    }

    public mut prop y: ?SvgLength {
        get() {
            this.yCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("y")) {
                        case Some(text) => SvgLength.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            this.writeOptionalAttribute("y", match (value) {
                case Some(length) => Some(length.toString())
                case None => None
            })
        }
    }

    public mut prop width: ?SvgLength {
        get() {
            this.widthCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("width")) {
                        case Some(text) => SvgLength.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            this.writeOptionalAttribute("width", match (value) {
                case Some(length) => Some(length.toString())
                case None => None
            })
        }
    }

    public mut prop height: ?SvgLength {
        get() {
            this.heightCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("height")) {
                        case Some(text) => SvgLength.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            this.writeOptionalAttribute("height", match (value) {
                case Some(length) => Some(length.toString())
                case None => None
            })
        }
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
            this.writeOptionalAttribute("viewBox", match (value) {
                case Some(box) => Some(box.toString())
                case None => None
            })
        }
    }

    public mut prop preserveAspectRatio: ?SvgPreserveAspectRatio {
        get() {
            this.aspectCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("preserveAspectRatio")) {
                        case Some(text) => tryParseSvgPreserveAspectRatio(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            this.writeOptionalAttribute("preserveAspectRatio", match (value) {
                case Some(ratio) => Some(ratio.toString())
                case None => None
            })
        }
    }
}

internal func tryParseSvgViewBox(text: String): ?SvgViewBox {
    try {
        Some(SvgViewBox.parse(text))
    } catch (_: SvgException) {
        None
    }
}

internal func tryParseSvgPreserveAspectRatio(text: String): ?SvgPreserveAspectRatio {
    try {
        Some(SvgPreserveAspectRatio.parse(text))
    } catch (_: SvgException) {
        None
    }
}
