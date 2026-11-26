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

/** `textPath side` 的取值。 */
public enum SvgTextPathSide <: Equatable<SvgTextPathSide> & ToString {
    | Left
    | Right

    public operator func ==(that: SvgTextPathSide): Bool {
        match ((this, that)) {
            case (Left, Left) => true
            case (Right, Right) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Left => "left"
            case Right => "right"
        }
    }

    internal static func fromName(name: String): ?SvgTextPathSide {
        match (name.trimAscii().toAsciiLower()) {
            case "left" => Some(Left)
            case "right" => Some(Right)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgTextPathSide {
        match (raw) {
            case Some(text) =>
                match (SvgTextPathSide.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 left")
                        Left
                }
            case None => Left
        }
    }
}

/** `textPath method` 的取值。 */
public enum SvgTextPathMethod <: Equatable<SvgTextPathMethod> & ToString {
    | Align
    | Stretch

    public operator func ==(that: SvgTextPathMethod): Bool {
        match ((this, that)) {
            case (Align, Align) => true
            case (Stretch, Stretch) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Align => "align"
            case Stretch => "stretch"
        }
    }

    internal static func fromName(name: String): ?SvgTextPathMethod {
        match (name.trimAscii().toAsciiLower()) {
            case "align" => Some(Align)
            case "stretch" => Some(Stretch)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgTextPathMethod {
        match (raw) {
            case Some(text) =>
                match (SvgTextPathMethod.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 align")
                        Align
                }
            case None => Align
        }
    }
}

/** `textPath spacing` 的取值。 */
public enum SvgTextPathSpacing <: Equatable<SvgTextPathSpacing> & ToString {
    | Auto
    | Exact

    public operator func ==(that: SvgTextPathSpacing): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (Exact, Exact) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case Exact => "exact"
        }
    }

    internal static func fromName(name: String): ?SvgTextPathSpacing {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "exact" => Some(Exact)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgTextPathSpacing {
        match (raw) {
            case Some(text) =>
                match (SvgTextPathSpacing.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 auto")
                        Auto
                }
            case None => Auto
        }
    }
}

/** `textPath` 元素。 */
public class SvgTextPath <: SvgTextElement {
    private let startOffsetCache = SvgValueCache<SvgLength>()
    private let pathCache = SvgValueCache<SvgPathData>()
    private let sideCache = SvgValueCache<SvgTextPathSide>()
    private let methodCache = SvgValueCache<SvgTextPathMethod>()
    private let spacingCache = SvgValueCache<SvgTextPathSpacing>()

    public init(href!: ?String = None, startOffset!: ?SvgLength = None) {
        super("textPath")
        this.href = href
        this.startOffset = startOffset
    }

    /** 读取同时接受 `href` 与 `xlink:href`，写入默认落在 `xlink:href`。 */
    public mut prop href: ?String {
        get() {
            readSvgHref(this)
        }
        set(value) {
            writeSvgHref(this, value)
        }
    }

    public mut prop startOffset: ?SvgLength {
        get() {
            this.startOffsetCache.get(this.attributesVersion, {=> readLength(this, "startOffset")})
        }
        set(value) {
            writeLength(this, "startOffset", value)
        }
    }

    /** `path` 属性（`d` 语法），优先于 `href` 指向的路径。 */
    public mut prop path: ?SvgPathData {
        get() {
            this.pathCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("path")) {
                        case Some(text) => SvgPathData.tryParse(text)
                        case None => None
                    }
                }
            )
        }
        set(value) {
            match (value) {
                case Some(data) => this.setAttr("path", data.toString())
                case None => this.removeAttr("path")
            }
        }
    }

    public mut prop side: SvgTextPathSide {
        get() {
            this.sideCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("side")) {
                        case Some(text) => SvgTextPathSide.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgTextPathSide.Left
        }
        set(value) {
            this.setAttr("side", value.toString())
        }
    }

    public mut prop method: SvgTextPathMethod {
        get() {
            this.methodCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("method")) {
                        case Some(text) => SvgTextPathMethod.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgTextPathMethod.Align
        }
        set(value) {
            this.setAttr("method", value.toString())
        }
    }

    public mut prop spacing: SvgTextPathSpacing {
        get() {
            this.spacingCache.get(
                this.attributesVersion,
                {=>
                    match (this.attr("spacing")) {
                        case Some(text) => SvgTextPathSpacing.fromName(text)
                        case None => None
                    }
                }
            ) ?? SvgTextPathSpacing.Auto
        }
        set(value) {
            this.setAttr("spacing", value.toString())
        }
    }
}
