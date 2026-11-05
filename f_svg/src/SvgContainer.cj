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

/** 结构容器的语义种类。差异只在对消费者的含义，数据结构相同。 */
public enum SvgContainerKind <: Equatable<SvgContainerKind> & ToString {
    | Group
    | Defs
    | Symbol
    | Marker
    | Pattern
    | ClipPath
    | Mask
    | Switch
    | Anchor
    | ForeignObject

    public operator func ==(that: SvgContainerKind): Bool {
        match ((this, that)) {
            case (Group, Group) => true
            case (Defs, Defs) => true
            case (Symbol, Symbol) => true
            case (Marker, Marker) => true
            case (Pattern, Pattern) => true
            case (ClipPath, ClipPath) => true
            case (Mask, Mask) => true
            case (Switch, Switch) => true
            case (Anchor, Anchor) => true
            case (ForeignObject, ForeignObject) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Group => "Group"
            case Defs => "Defs"
            case Symbol => "Symbol"
            case Marker => "Marker"
            case Pattern => "Pattern"
            case ClipPath => "ClipPath"
            case Mask => "Mask"
            case Switch => "Switch"
            case Anchor => "Anchor"
            case ForeignObject => "ForeignObject"
        }
    }

    internal func tagName(): String {
        match (this) {
            case Group => "g"
            case Defs => "defs"
            case Symbol => "symbol"
            case Marker => "marker"
            case Pattern => "pattern"
            case ClipPath => "clipPath"
            case Mask => "mask"
            case Switch => "switch"
            case Anchor => "a"
            case ForeignObject => "foreignObject"
        }
    }

    internal static func fromTag(tag: String): ?SvgContainerKind {
        match (tag) {
            case "g" => Some(Group)
            case "defs" => Some(Defs)
            case "symbol" => Some(Symbol)
            case "marker" => Some(Marker)
            case "pattern" => Some(Pattern)
            case "clipPath" => Some(ClipPath)
            case "mask" => Some(Mask)
            case "switch" => Some(Switch)
            case "a" => Some(Anchor)
            case "foreignObject" => Some(ForeignObject)
            case _ => None
        }
    }
}

/** 结构容器：`g` / `defs` / `symbol` / `marker` / `pattern` / `clipPath` / `mask` / `switch` / `a` / `foreignObject`。 */
public class SvgContainer <: SvgElement {
    public let kind: SvgContainerKind

    public init(kind: SvgContainerKind) {
        super(kind.tagName())
        this.kind = kind
    }
}
