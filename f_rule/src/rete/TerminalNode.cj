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
package fountain::f_rule.rete

import fountain::f_rule.agenda.{Activation, Bindings}
import fountain::f_rule.rule.Rule

/**
 * 规则终端：把一个令牌展开成激活（`doc/04-rete-network.md` §8）。
 *
 * 每个规则一个终端（不共享），只依赖 [ActivationSink]：
 * `leftActivate` 交给 `add`，`leftRetract` 用同一组绑定构造等价激活交给 `remove`。
 * 激活的相等性由 `(factSpace, ruleId, bindings)` 决定，因此撤回不需要保存原对象。
 */
public class TerminalNode <: ReteNode & TokenSink {
    private let id_: Int64
    public let rule: Rule

    public init(id: Int64, rule: Rule) {
        this.id_ = id
        this.rule = rule
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    public prop ruleId: String {
        get() {
            rule.id
        }
    }

    public prop factSpace: String {
        get() {
            rule.factSpace
        }
    }

    public prop specificity: Int64 {
        get() {
            Activation.specificityOf(rule)
        }
    }

    public func leftActivate(session: ReteSession, token: Token): Unit {
        session.sink.add(activate(token.bindings()))
    }

    public func leftRetract(session: ReteSession, token: Token): Unit {
        session.sink.remove(activate(token.bindings()))
    }

    /** 构造激活；供测试与议程直接调用。 */
    public func activate(bindings: Bindings): Activation {
        Activation(rule, bindings)
    }

    public func toString(): String {
        "TerminalNode(${id}, ${rule.id}@${rule.factSpace})"
    }
}
