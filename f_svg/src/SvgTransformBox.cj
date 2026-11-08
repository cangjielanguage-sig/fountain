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

/** `transform-box` 的参考盒。 */
public enum SvgTransformBox <: Equatable<SvgTransformBox> & ToString {
    | ViewBox
    | FillBox

    public operator func ==(that: SvgTransformBox): Bool {
        match ((this, that)) {
            case (ViewBox, ViewBox) => true
            case (FillBox, FillBox) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case ViewBox => "view-box"
            case FillBox => "fill-box"
        }
    }

    /** 大小写不敏感解析；未知值返回 `None`。 */
    public static func fromName(name: String): ?SvgTransformBox {
        match (name.trimAscii().toAsciiLower()) {
            case "view-box" => Some(ViewBox)
            case "fill-box" => Some(FillBox)
            case _ => None
        }
    }

    /** 解析失败回退 `ViewBox`。 */
    public static func fromNameOrDefault(name: ?String): SvgTransformBox {
        match (name) {
            case Some(value) => fromName(value) ?? ViewBox
            case None => ViewBox
        }
    }
}
