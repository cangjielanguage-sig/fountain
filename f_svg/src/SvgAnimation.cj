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

/** 动画类型。 */
public enum SvgAnimationKind <: Equatable<SvgAnimationKind> & ToString {
    | Animate
    | AnimateTransform
    | AnimateMotion
    | Set

    public operator func ==(that: SvgAnimationKind): Bool {
        match ((this, that)) {
            case (Animate, Animate) => true
            case (AnimateTransform, AnimateTransform) => true
            case (AnimateMotion, AnimateMotion) => true
            case (Set, Set) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Animate => "Animate"
            case AnimateTransform => "AnimateTransform"
            case AnimateMotion => "AnimateMotion"
            case Set => "Set"
        }
    }
}

/** 供调用方查询的动画摘要。 */
public class SvgAnimationInfo {
    public let targetId: ?String
    public let attributeName: String
    public let begin: Float64
    public let end: Float64
    public let kind: SvgAnimationKind

    internal init(
        targetId: ?String,
        attributeName: String,
        begin: Float64,
        end: Float64,
        kind: SvgAnimationKind
    ) {
        this.targetId = targetId
        this.attributeName = attributeName
        this.begin = begin
        this.end = end
        this.kind = kind
    }

    public func toString(): String {
        "${this.kind}(${this.targetId ?? "?"}.${this.attributeName}) [${this.begin}, ${this.end}]"
    }
}

/** `id.begin` / `id.end` 时间引用。 */
internal class SvgTimeReference {
    let id: String
    let isBegin: Bool

    init(id: String, isBegin: Bool) {
        this.id = id
        this.isBegin = isBegin
    }
}

internal func parseSvgTimeValue(text: String): ?Float64 {
    let trimmed = text.trimAscii()
    if (trimmed.size == 0) {
        return None
    }
    if (trimmed.toAsciiLower() == "indefinite") {
        return Some(Float64.Inf)
    }
    var number = trimmed
    var factor = 1.0
    if (trimmed.size > 2 && trimmed[trimmed.size - 2..].toAsciiLower() == "ms") {
        number = trimmed[0..trimmed.size - 2]
        factor = 0.001
    } else if (trimmed.size > 1 && trimmed[trimmed.size - 1] == b's') {
        number = trimmed[0..trimmed.size - 1]
        factor = 1.0
    }
    match (tryParseSvgFloat(number)) {
        case Some(value) => Some(value * factor)
        case None => None
    }
}

internal func parseSvgTimeReference(text: String): ?SvgTimeReference {
    let trimmed = text.trimAscii()
    if (trimmed.size > 6 && trimmed.endsWith(".begin")) {
        return Some(SvgTimeReference(trimmed[0..trimmed.size - 6], true))
    }
    if (trimmed.size > 4 && trimmed.endsWith(".end")) {
        return Some(SvgTimeReference(trimmed[0..trimmed.size - 4], false))
    }
    None
}

/** 事件型 begin（click 等）在 M2 不支持。 */
internal func isSvgEventTime(text: String): Bool {
    let trimmed = text.trimAscii().toAsciiLower()
    trimmed == "click" || trimmed == "mousedown" || trimmed == "mouseup" ||
    trimmed == "mouseover" || trimmed == "focus" || trimmed == "load" || trimmed == "begin"
}
