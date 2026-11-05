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
 * `vector-effect` 的取值。
 *
 * 以类 + 静态常量建模，避免与 `Option.None` 的枚举构造器同名冲突。
 */
public class SvgVectorEffect <: Equatable<SvgVectorEffect> & ToString {
    private let ordinal: Int64

    private init(ordinal: Int64) {
        this.ordinal = ordinal
    }

    public static prop NoEffect: SvgVectorEffect {
        get() {
            SvgVectorEffect(0)
        }
    }
    public static prop NonScalingStroke: SvgVectorEffect {
        get() {
            SvgVectorEffect(1)
        }
    }

    public operator func ==(that: SvgVectorEffect): Bool {
        this.ordinal == that.ordinal
    }

    public func toString(): String {
        match (this.ordinal) {
            case 0 => "none"
            case _ => "non-scaling-stroke"
        }
    }

    internal static func fromName(name: String): ?SvgVectorEffect {
        match (name.trimAscii().toAsciiLower()) {
            case "none" => Some(SvgVectorEffect.NoEffect)
            case "non-scaling-stroke" => Some(SvgVectorEffect.NonScalingStroke)
            case _ => None
        }
    }

    internal static func fromNameOrWarn(
        raw: ?String,
        warnings: ArrayList<String>,
        context: String
    ): SvgVectorEffect {
        match (raw) {
            case Some(text) =>
                match (SvgVectorEffect.fromName(text)) {
                    case Some(value) => value
                    case None =>
                        warnings.add("${context} 的值「${text}」不合法，已回退为 none")
                        SvgVectorEffect.NoEffect
                }
            case None => SvgVectorEffect.NoEffect
        }
    }
}
