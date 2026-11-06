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
package fountain::f_rule.agenda

import std.collection.HashMap
import fountain::f_rule.fact.{Fact, FactBaseView, FactHandle}
import fountain::f_rule.rule.ActionContext

/**
 * 事实变更传播契约（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 动作改事实后必须把变更送进 Rete 网络，否则新激活不会产生、失效激活不会被移除。
 * 议程与网络互不依赖，因此用本接口把回调注入动作上下文。
 */
public interface FactPropagation {
    func onAssert(space: String, handle: FactHandle, fact: Fact): Unit
    func onRetract(space: String, handle: FactHandle): Unit
    func onUpdate(space: String, handle: FactHandle, fact: Fact): Unit
}

/** 空实现：单测与不需要传播的场景使用。 */
public class NoopPropagation <: FactPropagation {
    public init() {}

    public func onAssert(space: String, handle: FactHandle, fact: Fact): Unit {
        let _ = space
        let _ = handle
        let _ = fact
    }

    public func onRetract(space: String, handle: FactHandle): Unit {
        let _ = space
        let _ = handle
    }

    public func onUpdate(space: String, handle: FactHandle, fact: Fact): Unit {
        let _ = space
        let _ = handle
        let _ = fact
    }
}

/**
 * 会话级动作上下文（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * - `assert` / `retract` / `update` 只作用于 `activation.factSpace`；
 * - 跨空间访问一律显式：`factIn` 只读，`copyTo` 物化出独立事实；
 * - 输出槽由调用方注入，同一次 `fire` 内多个动作共享。
 */
public class SessionActionContext <: ActionContext {
    private let activation_: Activation
    private let view_: FactBaseView
    private let viewOf_: (String) -> FactBaseView
    private let outputs_: HashMap<String, Any>
    private let propagation_: FactPropagation

    public init(activation: Activation, view: FactBaseView,
        viewOf: (String) -> FactBaseView, outputs: HashMap<String, Any>,
        propagation!: FactPropagation = NoopPropagation()) {
        this.activation_ = activation
        this.view_ = view
        this.viewOf_ = viewOf
        this.outputs_ = outputs
        this.propagation_ = propagation
    }

    public prop factSpace: String {
        get() {
            activation_.factSpace
        }
    }

    /**
     * 按绑定取事实。
     *
     * 有句柄时回查来源空间的事实库，拿到的是 `update` 之后的当前实例；
     * 没有句柄（朴素匹配路径）时退回激活里保存的事实。
     */
    public func fact(binding: String): ?Fact {
        match (activation_.bindings.get(binding)) {
            case Some(handle) =>
                match (view_.get(handle)) {
                    case Some(current) => Some(current)
                    case None => activation_.bindings.resolve(binding)
                }
            case None => activation_.bindings.resolve(binding)
        }
    }

    public func assert(fact: Fact): FactHandle {
        let handle = view_.assert(fact)
        propagation_.onAssert(factSpace, handle, fact)
        handle
    }

    public func retract(handle: FactHandle): Unit {
        if (view_.retract(handle)) {
            propagation_.onRetract(factSpace, handle)
        }
    }

    public func update(handle: FactHandle, fact: Fact): Unit {
        if (view_.update(handle, fact)) {
            propagation_.onUpdate(factSpace, handle, fact)
        }
    }

    public func set(name: String, value: Any): Unit {
        outputs_[name] = value
    }

    public func get(name: String): ?Any {
        outputs_.get(name)
    }

    public func outputs(): HashMap<String, Any> {
        let copy = HashMap<String, Any>()
        for ((key, value) in outputs_) {
            copy[key] = value
        }
        copy
    }

    public func factIn(space: String, handle: FactHandle): ?Fact {
        viewOf_(space).get(handle)
    }

    public func copyTo(space: String, fact: Fact): FactHandle {
        let target = viewOf_(space)
        let handle = target.assertCopy(fact)
        match (target.get(handle)) {
            case Some(stored) => propagation_.onAssert(space, handle, stored)
            case None => ()
        }
        handle
    }
}
