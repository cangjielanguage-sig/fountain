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

import fountain::f_log.LoggerFactory
import fountain::f_rule.agenda.{Activation, Bindings}
import fountain::f_rule.condition.{EvalOutcome, JitExpression}
import fountain::f_rule.rule.{Rule, RuleFailureGuard}

/**
 * 规则终端：把一个令牌展开成激活（`doc/04-rete-network.md` §8）。
 *
 * 每个规则一个终端（不共享），只依赖 [ActivationSink]：
 * `leftActivate` 交给 `add`，`leftRetract` 用同一组绑定构造等价激活交给 `remove`。
 * 激活的相等性由 `(factSpace, ruleId, bindings)` 决定，因此撤回不需要保存原对象。
 */
public class TerminalNode <: ReteNode & TokenSink {
    private static let log = LoggerFactory.getLogger<TerminalNode>()

    private let id_: Int64
    public let rule: Rule
    /** 规则声明的脚本条件；空数组表示只靠模式约束。 */
    private let scripts_: Array<JitExpression>
    private let failureGuard_: RuleFailureGuard

    public init(id: Int64, rule: Rule, scripts!: Array<JitExpression> = Array<JitExpression>(),
        failureGuard!: RuleFailureGuard = RuleFailureGuard("standalone")) {
        this.id_ = id
        this.rule = rule
        this.scripts_ = scripts
        this.failureGuard_ = failureGuard
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
        if (failureGuard_.isDisabled(rule.id)) {
            return
        }
        let bindings = token.bindings()
        let outcome = evaluate(bindings)
        if (outcome.isFailure()) {
            TerminalNode.log.warn(
                "规则 ${rule.id} 表达式求值失败" +
                "（session=${sessionIdOf(session)}，site=${site()}，" +
                "code=${outcome.kind}）：${outcome.detail}"
            )
            if (failureGuard_.recordFailure(rule.id, outcome.kind)) {
                TerminalNode.log.error(
                    "规则 ${rule.id} 连续失败 ${failureGuard_.threshold} 次，已禁用" +
                    "（ruleSet=${failureGuard_.ruleSetId}，site=${site()}）"
                )
            }
            return
        }
        failureGuard_.recordSuccess(rule.id)
        if (!outcome.value) {
            return
        }
        session.sink.add(activate(bindings))
    }

    public func leftRetract(session: ReteSession, token: Token): Unit {
        let bindings = token.bindings()
        let outcome = evaluate(bindings)
        if (outcome.isFailure() || !outcome.value) {
            return
        }
        session.sink.remove(activate(bindings))
    }

    /**
     * 求值规则脚本。全部为 true 才产生激活。
     *
     * 脚本是模式之外的附加判定，忽略它会让规则退化成「模式匹配即触发」。
     * 编译在 `ReteNetwork.newTerminal` 构建期完成，此处只做求值；运行期异常/超时
     * 统一收敛为 `EvalOutcome`，绝不穿透到 f_egraph 的事件循环。
     */
    private func evaluate(bindings: Bindings): EvalOutcome {
        if (scripts_.size == 0) {
            return EvalOutcome.evaluated(true)
        }
        let facts = bindings.toFactMap()
        for (script in scripts_) {
            let outcome = script.evalDetailed(facts, timeout: failureGuard_.expressionTimeout)
            if (outcome.isFailure()) {
                return outcome
            }
            if (!outcome.value) {
                return EvalOutcome.evaluated(false)
            }
        }
        EvalOutcome.evaluated(true)
    }

    private func sessionIdOf(session: ReteSession): String {
        match (session as SessionNetwork) {
            case Some(found) => found.session
            case None => ""
        }
    }

    private func site(): String {
        "terminal#${id_}@${rule.factSpace}"
    }

    /** 构造激活；供测试与议程直接调用。 */
    public func activate(bindings: Bindings): Activation {
        Activation(rule, bindings)
    }

    public func toString(): String {
        "TerminalNode(${id}, ${rule.id}@${rule.factSpace})"
    }
}
