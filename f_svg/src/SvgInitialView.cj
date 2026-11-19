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

/** 根元素的 `zoomAndPan`；M6 只存值，不影响渲染。 */
public enum SvgZoomAndPan <: Equatable<SvgZoomAndPan> & ToString {
    | Disable
    | Magnify

    public operator func ==(that: SvgZoomAndPan): Bool {
        match ((this, that)) {
            case (Disable, Disable) => true
            case (Magnify, Magnify) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Disable => "disable"
            case Magnify => "magnify"
        }
    }

    internal static func fromName(name: String): ?SvgZoomAndPan {
        match (name.trimAscii().toAsciiLower()) {
            case "disable" => Some(Disable)
            case "magnify" => Some(Magnify)
            case _ => Option<SvgZoomAndPan>.None
        }
    }
}
