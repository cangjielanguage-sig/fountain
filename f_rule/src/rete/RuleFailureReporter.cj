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
import fountain::f_rule.condition.EvalFailureKind
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 约束/join 运行期异常的收敛点（`doc/03-condition-expression.md` §6.2）。
 *
 * alpha/beta 节点是共享结构，异常发生时按该节点登记的规则 id 逐个记失败；禁用状态
 * 仍落在规则集级的 `RuleFailureGuard` 上，与终端脚本共用同一份计数器。
 */
class RuleFailureReporter {
    private static let log = LoggerFactory.getLogger<RuleFailureReporter>()

    static func report(session: ReteSession, ruleIds: Array<String>, error: Exception,
        site: String): Unit {
        let network = match (session as SessionNetwork) {
            case Some(found) => found
            case None => return
        }
        let kind = RuleFailureReporter.classify(error)
        for (ruleId in ruleIds) {
            if (network.failureGuard.isDisabled(ruleId)) {
                continue
            }
            RuleFailureReporter.log.warn(
                "规则 ${ruleId} 表达式求值失败" +
                "（session=${network.session}，site=${site}，code=${kind}）：${error.message}"
            )
            if (network.failureGuard.recordFailure(ruleId, kind)) {
                RuleFailureReporter.log.error(
                    "规则 ${ruleId} 连续失败 ${network.failureGuard.threshold} 次，已禁用" +
                    "（ruleSet=${network.failureGuard.ruleSetId}，site=${site}）"
                )
            }
        }
    }

    private static func classify(error: Exception): EvalFailureKind {
        match (error as RuleException) {
            case Some(typed) =>
                if (typed.code == RuleErrorCode.TYPE_MISMATCH) {
                    EvalFailureKind.TypeMismatch
                } else {
                    EvalFailureKind.RuntimeFailure
                }
            case None => EvalFailureKind.RuntimeFailure
        }
    }
}
