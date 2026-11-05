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

/** marker 的缩放单位。 */
public enum SvgMarkerUnits <: Equatable<SvgMarkerUnits> & ToString {
    | StrokeWidth
    | UserSpaceOnUse

    public operator func ==(that: SvgMarkerUnits): Bool {
        match ((this, that)) {
            case (StrokeWidth, StrokeWidth) => true
            case (UserSpaceOnUse, UserSpaceOnUse) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case StrokeWidth => "strokeWidth"
            case UserSpaceOnUse => "userSpaceOnUse"
        }
    }

    internal static func fromName(name: String): ?SvgMarkerUnits {
        match (name) {
            case "strokeWidth" => Some(StrokeWidth)
            case "userSpaceOnUse" => Some(UserSpaceOnUse)
            case _ => None
        }
    }
}

/** marker 的朝向：自动切线、起点反向自动切线，或固定角度。 */
public enum SvgMarkerOrient <: Equatable<SvgMarkerOrient> & ToString {
    | Auto
    | AutoStartReverse
    | Angle(Float64)

    public operator func ==(that: SvgMarkerOrient): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (AutoStartReverse, AutoStartReverse) => true
            case (Angle(left), Angle(right)) => left == right
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case AutoStartReverse => "auto-start-reverse"
            case Angle(degrees) => formatSvgNumber(degrees)
        }
    }

    internal static func fromName(name: String): ?SvgMarkerOrient {
        match (name) {
            case "auto" => Some(Auto)
            case "auto-start-reverse" => Some(AutoStartReverse)
            case _ =>
                match (tryParseSvgFloat(name)) {
                    case Some(degrees) => Some(Angle(degrees))
                    case None => None
                }
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgMarkerOrient {
        match (raw) {
            case Some(text) =>
                match (SvgMarkerOrient.fromName(text.trimAscii())) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 0")
                        Angle(0.0)
                }
            case None => Angle(0.0)
        }
    }
}

// TODO(M3-8): marker 类型化模型。
