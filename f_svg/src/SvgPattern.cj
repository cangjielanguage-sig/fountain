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
 * `pattern` 元素。
 *
 * 保留 `SvgContainer` 的子节点、`kind` 与标签名行为；`href` 继承与 tile 取样在渲染层实现。
 */
public class SvgPattern <: SvgContainer {
    private let xCache = SvgValueCache<SvgLength>()
    private let yCache = SvgValueCache<SvgLength>()
    private let widthCache = SvgValueCache<SvgLength>()
    private let heightCache = SvgValueCache<SvgLength>()
    private let unitsCache = SvgValueCache<SvgCoordinateUnits>()
    private let contentUnitsCache = SvgValueCache<SvgCoordinateUnits>()
    private let transformCache = SvgValueCache<SvgTransform>()
    private let viewBoxCache = SvgValueCache<SvgViewBox>()
    private let aspectCache = SvgValueCache<SvgPreserveAspectRatio>()

    public init() {
        super(SvgContainerKind.Pattern)
    }

    public mut prop x: ?SvgLength {
        get() {
            this.xCache.get(this.attributesVersion, {=> readLength(this, "x")})
        }
        set(value) {
            writeLength(this, "x", value)
        }
    }

    public mut prop y: ?SvgLength {
        get() {
            this.yCache.get(this.attributesVersion, {=> readLength(this, "y")})
        }
        set(value) {
            writeLength(this, "y", value)
        }
    }

    public mut prop width: ?SvgLength {
        get() {
            this.widthCache.get(this.attributesVersion, {=> readLength(this, "width")})
        }
        set(value) {
            writeLength(this, "width", value)
        }
    }

    public mut prop height: ?SvgLength {
        get() {
            this.heightCache.get(this.attributesVersion, {=> readLength(this, "height")})
        }
        set(value) {
            writeLength(this, "height", value)
        }
    }

    public mut prop patternUnits: SvgCoordinateUnits {
        get() {
            this.unitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("patternUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgCoordinateUnits.ObjectBoundingBox
        }
        set(value) {
            this.setAttr("patternUnits", value.attrName())
        }
    }

    public mut prop patternContentUnits: SvgCoordinateUnits {
        get() {
            this.contentUnitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("patternContentUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgCoordinateUnits.UserSpaceOnUse
        }
        set(value) {
            this.setAttr("patternContentUnits", value.attrName())
        }
    }

    public mut prop patternTransform: ?SvgTransform {
        get() {
            this.transformCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("patternTransform")) {
                        case Some(text) => tryParseSvgTransform(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(transform) => this.setAttr("patternTransform", transform.toString())
                case None => this.removeAttr("patternTransform")
            }
        }
    }

    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            writeSvgHref(this, value)
        }
    }

    /** tile 内容坐标系；声明后 `patternContentUnits` 被忽略。 */
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
}
