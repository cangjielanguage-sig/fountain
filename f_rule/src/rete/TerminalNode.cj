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
import fountain::f_rule.condition.JitExpression
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
    /** 规则声明的脚本条件；空数组表示只靠模式约束。 */
    private let scripts_: Array<JitExpression>

    public init(id: Int64, rule: Rule, scripts!: Array<JitExpression> = Array<JitExpression>()) {
        this.id_ = id
        this.rule = rule
        this.scripts_ = scripts
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
        let bindings = token.bindings()
        if (!evaluate(bindings)) {
            return
        }
        session.sink.add(activate(bindings))
    }

    public func leftRetract(session: ReteSession, token: Token): Unit {
        let bindings = token.bindings()
        if (!evaluate(bindings)) {
            return
        }
        session.sink.remove(activate(bindings))
    }

    /**
     * 求值规则脚本。全部为 true 才产生激活。
     *
     * 脚本是模式之外的附加判定，忽略它会让规则退化成「模式匹配即触发」。
     * 编译在 `ReteNetwork.newTerminal` 构建期完成，此处只做求值。
     */
    private func evaluate(bindings: Bindings): Bool {
        if (scripts_.size == 0) {
            return true
        }
        let facts = bindings.toFactMap()
        for (script in scripts_) {
            if (!script.eval(facts)) {
                return false
            }
        }
        true
    }

    /** 构造激活；供测试与议程直接调用。 */
    public func activate(bindings: Bindings): Activation {
        Activation(rule, bindings)
    }

    public func toString(): String {
        "TerminalNode(${id}, ${rule.id}@${rule.factSpace})"
    }
}
