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

/**
 * `filter` 元素。
 *
 * 区域属性缺省为 `None`，由渲染层按 `-10% / -10% / 120% / 120%` 解释；
 * `primitives` 只收集直接子节点中的 `SvgFilterPrimitive`，非 `fe*` 子节点保留在 `children`。
 */
public class SvgFilter <: SvgElement {
    private let xCache = SvgValueCache<SvgLength>()
    private let yCache = SvgValueCache<SvgLength>()
    private let widthCache = SvgValueCache<SvgLength>()
    private let heightCache = SvgValueCache<SvgLength>()
    private let filterUnitsCache = SvgValueCache<SvgCoordinateUnits>()
    private let primitiveUnitsCache = SvgValueCache<SvgCoordinateUnits>()

    public init() {
        super("filter")
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

    public mut prop filterUnits: SvgCoordinateUnits {
        get() {
            this.filterUnitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("filterUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgCoordinateUnits.ObjectBoundingBox
        }
        set(value) {
            this.setAttr("filterUnits", value.attrName())
        }
    }

    public mut prop primitiveUnits: SvgCoordinateUnits {
        get() {
            this.primitiveUnitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("primitiveUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            ) ?? SvgCoordinateUnits.UserSpaceOnUse
        }
        set(value) {
            this.setAttr("primitiveUnits", value.attrName())
        }
    }

    /** 直接子节点中的滤镜原语，按文档顺序。 */
    public prop primitives: ArrayList<SvgFilterPrimitive> {
        get() {
            let result = ArrayList<SvgFilterPrimitive>()
            for (node in this.children) {
                match (node) {
                    case ElementNode(element) =>
                        match (element) {
                            case primitive: SvgFilterPrimitive => result.add(primitive)
                            case _ => ()
                        }
                    case _ => ()
                }
            }
            result
        }
    }
}
