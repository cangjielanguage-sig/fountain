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

/** 变更类型。 */
public enum SvgMutationKind <: Equatable<SvgMutationKind> & ToString {
    | Attribute
    | ChildInserted
    | ChildRemoved

    public operator func ==(that: SvgMutationKind): Bool {
        match ((this, that)) {
            case (Attribute, Attribute) => true
            case (ChildInserted, ChildInserted) => true
            case (ChildRemoved, ChildRemoved) => true
            case _ => false
        }
    }

    public func toString(): String {
        match (this) {
            case Attribute => "Attribute"
            case ChildInserted => "ChildInserted"
            case ChildRemoved => "ChildRemoved"
        }
    }
}

/** 一次变更事件。 */
public class SvgMutationEvent {
    public let kind: SvgMutationKind
    public let element: SvgElement
    public let attributeName: ?String
    public let oldValue: ?String
    public let newValue: ?String
    public let child: ?SvgNode

    internal init(
        kind: SvgMutationKind,
        element: SvgElement,
        attributeName!: ?String = None,
        oldValue!: ?String = None,
        newValue!: ?String = None,
        child!: ?SvgNode = None
    ) {
        this.kind = kind
        this.element = element
        this.attributeName = attributeName
        this.oldValue = oldValue
        this.newValue = newValue
        this.child = child
    }
}

/** 同步变更监听器。异常被 hub 捕获并写入文档 warning。 */
public interface SvgMutationListener {
    func onMutation(event: SvgMutationEvent): Unit
}

internal let SVG_MUTATION_LISTENER_LIMIT: Int64 = 32

/** 文档级变更 hub；根元素持有引用，元素沿 parent 链找到它。 */
internal class SvgMutationHub {
    private let listeners = ArrayList<SvgMutationListener>()
    var warnings: ?ArrayList<String> = None

    func add(listener: SvgMutationListener): Unit {
        if (this.listeners.size >= SVG_MUTATION_LISTENER_LIMIT) {
            throw invalidValue("变更监听器数量超过上限 ${SVG_MUTATION_LISTENER_LIMIT}")
        }
        this.listeners.add(listener)
    }

    func remove(listener: SvgMutationListener): Unit {
        // 接口无引用相等；移除最早注册的监听器，满足单监听器解绑场景。
        if (this.listeners.size > 0) {
            this.listeners.remove(at: 0)
        }
    }

    func notify(event: SvgMutationEvent): Unit {
        for (listener in this.listeners) {
            try {
                listener.onMutation(event)
            } catch (error: Exception) {
                match (this.warnings) {
                    case Some(list) => list.add("变更监听器异常：${error.message}")
                    case None => ()
                }
            }
        }
    }
}

/** 沿 parent 链通知根上的 hub；未挂载或根无 hub 时不通知。 */
internal func svgNotifyMutation(element: SvgElement, event: SvgMutationEvent): Unit {
    var current: ?SvgElement = Some(element)
    while (true) {
        match (current) {
            case Some(node) =>
                match (node.mutationHub) {
                    case Some(hub) =>
                        hub.notify(event)
                        return
                    case None => current = node.parent
                }
            case None => return
        }
    }
}
