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
package fountain::f_rule.flow

import fountain::f_egraph.base.{EndEvent, ImmediateFlow}
import fountain::f_rule.rule.Rule

/**
 * 单条规则的独立流程（`doc/06-flow-orchestration.md` §2，P-01/P-02）。
 *
 * `category` 只含 `<ruleSetId>/<ruleId>`，不编码事实库空间；空间绑定在
 * `rule.factSpace` 上，运行时由 [FlowContext] 解析。因此同一规则换空间不需要改流程名。
 *
 * M4 只提供流程外壳与 session 透传；规则的匹配与动作由 [RuleTask] / [RuleSetFlow]
 * 在流程中显式编排。
 */
public class RuleFlow {
    public let flow: ImmediateFlow
    public let ruleId: String

    private init(flow: ImmediateFlow, ruleId: String) {
        this.flow = flow
        this.ruleId = ruleId
    }

    /**
     * 为单条规则构建独立流程。
     *
     * @param ruleSetId 规则集标识
     * @param rule 规则定义
     * @param version 规则集版本，作为 tag
     * @param acceptableEvent 上游事件名；缺省用 `rule.id`
     */
    public static func build(ruleSetId: String, rule: Rule, version: String,
        acceptableEvent!: String = ""): RuleFlow {
        let start = if (acceptableEvent.size > 0) { acceptableEvent } else { rule.id }
        let category = "${ruleSetId}/${rule.id}"
        let flow = ImmediateFlow(category: category, tag: version)
        flow.registerStart(start)
        flow.registerTask(start) { e =>
            let envelope = RuleEnvelope.from(e)
            EndEvent(
                category: category,
                tag: version,
                data: RuleEnvelope.wrap(e, envelope.unwrap()),
                session: envelope.session
            )
        }
        flow.registerEnd()
        RuleFlow(flow, rule.id)
    }
}
