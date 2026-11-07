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
 * `pointer-events` 的 SVG 取值。
 *
 * `auto` 等价于 `visiblePainted`；`none` 连同子树退出命中。
 */
public enum SvgPointerEvents <: Equatable<SvgPointerEvents> & ToString {
    | Auto
    | None
    | VisiblePainted
    | VisibleFill
    | VisibleStroke
    | Visible
    | Painted
    | Fill
    | Stroke
    | All
    | BoundingBox

    public operator func ==(that: SvgPointerEvents): Bool {
        match ((this, that)) {
            case (Auto, Auto) => true
            case (None, None) => true
            case (VisiblePainted, VisiblePainted) => true
            case (VisibleFill, VisibleFill) => true
            case (VisibleStroke, VisibleStroke) => true
            case (Visible, Visible) => true
            case (Painted, Painted) => true
            case (Fill, Fill) => true
            case (Stroke, Stroke) => true
            case (All, All) => true
            case (BoundingBox, BoundingBox) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Auto => "auto"
            case None => "none"
            case VisiblePainted => "visiblePainted"
            case VisibleFill => "visibleFill"
            case VisibleStroke => "visibleStroke"
            case Visible => "visible"
            case Painted => "painted"
            case Fill => "fill"
            case Stroke => "stroke"
            case All => "all"
            case BoundingBox => "bounding-box"
        }
    }

    /** 按 CSS 关键字解析；未知值返回 `None`。 */
    public static func fromName(name: String): ?SvgPointerEvents {
        match (name.trimAscii().toAsciiLower()) {
            case "auto" => Some(Auto)
            case "none" => Some(None)
            case "visiblepainted" => Some(VisiblePainted)
            case "visiblefill" => Some(VisibleFill)
            case "visiblestroke" => Some(VisibleStroke)
            case "visible" => Some(Visible)
            case "painted" => Some(Painted)
            case "fill" => Some(Fill)
            case "stroke" => Some(Stroke)
            case "all" => Some(All)
            case "bounding-box" => Some(BoundingBox)
            case _ => Option<SvgPointerEvents>.None
        }
    }
}
