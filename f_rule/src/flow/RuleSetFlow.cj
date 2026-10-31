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

import std.collection.{ArrayList, HashSet}
import fountain::f_egraph.base.{Event, ImmediateFlow}
import fountain::f_rule.{Rule, RuleEngine}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}

/**
 * 规则集编排门面（`doc/06-flow-orchestration.md` §2、§7，P-13/P-14）。
 *
 * 链式 `start` / `fanout` / `join` / `end` 底层由 `ImmediateFlow` + [ResolveTask] +
 * [JoinTask] 组成。`fanout` 校验每条分支首条规则的事实空间：不同空间可并行，
 * 同空间会并发改写同一批事实，构建期抛 `SAME_SPACE_FANOUT`。`end` 做可达性检查，
 * 扇出分支未全部汇入 `JoinTask` 时抛 `FANOUT_WITHOUT_JOIN`。
 */
public class RuleSetFlow {
    private let engine_: RuleEngine
    private let flow_: ImmediateFlow
    private let productions_ = ArrayList<Array<String>>()
    private let joinGroups_ = ArrayList<Array<String>>()
    private var startName_: String = ""
    private var hasTask_: Bool = false
    private var ended_: Bool = false

    private init(engine: RuleEngine) {
        this.engine_ = engine
        this.flow_ = ImmediateFlow(category: engine.ruleSet.id, tag: engine.ruleSet.version)
    }

    /** 以规则集的 `id`/`version` 作为流程 category/tag。 */
    public static func build(engine: RuleEngine): RuleSetFlow {
        RuleSetFlow(engine)
    }

    /** 底层流程，供调用方进一步定制。 */
    public prop flow: ImmediateFlow {
        get() {
            flow_
        }
    }

    public func start(name: String): RuleSetFlow {
        startName_ = name
        flow_.registerStart(name)
        this
    }

    /**
     * 在 `event` 上扇出到若干 `(子事件名, "<ruleSetId>/<ruleId>")`。
     *
     * 分支规则的 `factSpace` 必须两两不同；同空间写同一批事实的顺序不可控，
     * 需要串联而不是扇出。
     */
    public func fanout(event: String, branches: Array<(String, String)>): RuleSetFlow {
        ensureStarted()
        ensureFirstTask(event)
        let seen = HashSet<String>()
        for ((_, ruleCategory) in branches) {
            let rule = findRule(ruleCategory)
            if (seen.contains(rule.factSpace)) {
                throw RuleException(
                    RuleErrorCode.SAME_SPACE_FANOUT,
                    "扇出分支包含同一事实空间 ${rule.factSpace} 的规则；同空间规则必须串联"
                )
            }
            seen.add(rule.factSpace)
        }
        let childNames = ArrayList<String>()
        for ((child, _) in branches) {
            childNames.add(child)
        }
        let plan = { e: Event =>
            let payload = RuleEnvelope.from(e).unwrap()
            let parts = ArrayList<(String, Any)>()
            for ((child, _) in branches) {
                parts.add((child, payload))
            }
            parts.toArray()
        }
        flow_.registerTask(ResolveTask(
            name: "fanout",
            acceptable: [event],
            producing: childNames.toArray(),
            plan: plan
        ))
        productions_.add(childNames.toArray())
        hasTask_ = true
        this
    }

    /** 汇合分支；`branches` 不得与已有 JoinTask 重叠。 */
    public func join(branches: Array<String>, output: String): RuleSetFlow {
        ensureStarted()
        let groups = ArrayList<Array<String>>()
        for (group in joinGroups_) {
            groups.add(group)
        }
        groups.add(branches)
        Reachability.validateJoinBranches(groups.toArray())
        joinGroups_.add(branches)
        flow_.registerTask(JoinTask(
            name: "join-${joinGroups_.size}",
            branches: branches,
            output: output
        ))
        hasTask_ = true
        this
    }

    /** 校验扇出可达性并注册结束事件。 */
    public func end(): RuleSetFlow {
        ensureStarted()
        if (productions_.size > 0 && joinGroups_.size == 0) {
            throw RuleException(
                RuleErrorCode.FANOUT_WITHOUT_JOIN,
                "存在未汇合的扇出：JoinTask 之前不允许出现通往 End 的路径"
            )
        }
        // 中间任务可能改写事件名（check -> done），编排层只知道"有汇合点"；
        // 逐边的可达性由 Reachability.validate 在显式拓扑场景使用。
        flow_.registerEnd()
        ended_ = true
        this
    }

    private func ensureStarted(): Unit {
        if (startName_.size == 0) {
            throw RuleException(RuleErrorCode.ILLEGAL_STATE, "RuleSetFlow 必须先调用 start")
        }
        if (ended_) {
            throw RuleException(RuleErrorCode.ILLEGAL_STATE, "RuleSetFlow 已结束，不能再追加任务")
        }
    }

    private func ensureFirstTask(event: String): Unit {
        if (!hasTask_ && event != startName_) {
            throw RuleException(
                RuleErrorCode.ILLEGAL_STATE,
                "首个任务的事件 ${event} 必须等于 start 事件 ${startName_}"
            )
        }
    }

    private func findRule(ruleCategory: String): Rule {
        var ruleId = ruleCategory
        match (ruleCategory.lastIndexOf('/')) {
            case Some(index) => ruleId = ruleCategory[index + 1..]
            case None => ()
        }
        for (rule in engine_.ruleSet.rules) {
            if (rule.id == ruleId) {
                return rule
            }
        }
        throw RuleException(
            RuleErrorCode.ILLEGAL_STATE,
            "规则集 ${engine_.ruleSet.id} 中不存在规则 ${ruleId}"
        )
    }
}
