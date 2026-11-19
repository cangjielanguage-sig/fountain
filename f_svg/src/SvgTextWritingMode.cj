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

/** `writing-mode` 的取值。 */
public enum SvgWritingMode <: Equatable<SvgWritingMode> & ToString {
    | LrTb
    | Lr
    | Tb
    | TbRl

    public operator func ==(that: SvgWritingMode): Bool {
        match ((this, that)) {
            case (LrTb, LrTb) => true
            case (Lr, Lr) => true
            case (Tb, Tb) => true
            case (TbRl, TbRl) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case LrTb => "lr-tb"
            case Lr => "lr"
            case Tb => "tb"
            case TbRl => "tb-rl"
        }
    }

    /** 是否竖排。 */
    public func isVertical(): Bool {
        match (this) {
            case Tb | TbRl => true
            case _ => false
        }
    }

    internal static func fromName(name: String): ?SvgWritingMode {
        match (name.trimAscii().toAsciiLower()) {
            case "lr-tb" => Some(LrTb)
            case "lr" => Some(Lr)
            case "tb" => Some(Tb)
            case "tb-rl" => Some(TbRl)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgWritingMode {
        match (raw) {
            case Some(text) =>
                match (SvgWritingMode.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 lr-tb")
                        LrTb
                }
            case None => LrTb
        }
    }
}
