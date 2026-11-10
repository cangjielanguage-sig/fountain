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

/** `overflow` 的取值。 */
public enum SvgOverflow <: Equatable<SvgOverflow> & ToString {
    | Visible
    | Hidden
    | Scroll
    | Auto

    public operator func ==(that: SvgOverflow): Bool {
        match ((this, that)) {
            case (Visible, Visible) => true
            case (Hidden, Hidden) => true
            case (Scroll, Scroll) => true
            case (Auto, Auto) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Visible => "visible"
            case Hidden => "hidden"
            case Scroll => "scroll"
            case Auto => "auto"
        }
    }

    /** 是否裁剪到视口。 */
    public func clips(): Bool {
        match (this) {
            case Visible => false
            case _ => true
        }
    }

    internal static func fromName(name: String): ?SvgOverflow {
        match (name.trimAscii().toAsciiLower()) {
            case "visible" => Some(Visible)
            case "hidden" => Some(Hidden)
            case "scroll" => Some(Scroll)
            case "auto" => Some(Auto)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgOverflow {
        match (raw) {
            case Some(text) =>
                match (SvgOverflow.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 hidden")
                        Hidden
                }
            case None => Hidden
        }
    }
}
