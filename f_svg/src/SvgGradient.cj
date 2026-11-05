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

import std.math.*

/** 渐变坐标单位。 */
public enum SvgCoordinateUnits <: Equatable<SvgCoordinateUnits> & ToString {
    | UserSpaceOnUse
    | ObjectBoundingBox

    public operator func ==(that: SvgCoordinateUnits): Bool {
        match ((this, that)) {
            case (UserSpaceOnUse, UserSpaceOnUse) => true
            case (ObjectBoundingBox, ObjectBoundingBox) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case UserSpaceOnUse => "UserSpaceOnUse"
            case ObjectBoundingBox => "ObjectBoundingBox"
        }
    }

    internal func attrName(): String {
        match (this) {
            case UserSpaceOnUse => "userSpaceOnUse"
            case ObjectBoundingBox => "objectBoundingBox"
        }
    }

    internal static func fromName(name: String): ?SvgCoordinateUnits {
        match (name) {
            case "userSpaceOnUse" => Some(UserSpaceOnUse)
            case "objectBoundingBox" => Some(ObjectBoundingBox)
            case _ => None
        }
    }
}

/** 渐变溢出方式。 */
public enum SvgSpreadMethod <: Equatable<SvgSpreadMethod> & ToString {
    | Pad
    | Reflect
    | Repeat

    public operator func ==(that: SvgSpreadMethod): Bool {
        match ((this, that)) {
            case (Pad, Pad) => true
            case (Reflect, Reflect) => true
            case (Repeat, Repeat) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Pad => "Pad"
            case Reflect => "Reflect"
            case Repeat => "Repeat"
        }
    }

    internal func attrName(): String {
        match (this) {
            case Pad => "pad"
            case Reflect => "reflect"
            case Repeat => "repeat"
        }
    }

    internal static func fromName(name: String): ?SvgSpreadMethod {
        match (name) {
            case "pad" => Some(Pad)
            case "reflect" => Some(Reflect)
            case "repeat" => Some(Repeat)
            case _ => None
        }
    }
}

/** 渐变基类。 */
public abstract class SvgGradient <: SvgElement {
    private let unitsCache = SvgValueCache<SvgCoordinateUnits>()
    private let transformCache = SvgValueCache<SvgTransform>()
    private let spreadCache = SvgValueCache<SvgSpreadMethod>()

    protected init(tag: String) {
        super(tag)
    }

    public mut prop gradientUnits: ?SvgCoordinateUnits {
        get() {
            this.unitsCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("gradientUnits")) {
                        case Some(text) => SvgCoordinateUnits.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(units) => this.setAttr("gradientUnits", units.attrName())
                case None => this.removeAttr("gradientUnits")
            }
        }
    }

    public mut prop gradientTransform: ?SvgTransform {
        get() {
            this.transformCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("gradientTransform")) {
                        case Some(text) => tryParseSvgTransform(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(transform) => this.setAttr("gradientTransform", transform.toString())
                case None => this.removeAttr("gradientTransform")
            }
        }
    }

    public mut prop spreadMethod: ?SvgSpreadMethod {
        get() {
            this.spreadCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("spreadMethod")) {
                        case Some(text) => SvgSpreadMethod.fromName(text.trimAscii())
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(method) => this.setAttr("spreadMethod", method.attrName())
                case None => this.removeAttr("spreadMethod")
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
}

internal func tryParseSvgTransform(text: String): ?SvgTransform {
    try {
        Some(SvgTransform.parse(text))
    } catch (_: SvgException) {
        None
    }
}
