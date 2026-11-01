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
package fountain::f_rule.engine

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.agenda.*
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactBaseView, FactBaseViewStore, FactHandle, TypeTag}
import fountain::f_rule.rete.{SessionRuntime, ShardedNetwork}

/** 一条规则本次执行的输出槽。 */
public class FiredRule {
    public let ruleId: String
    public let outputs: HashMap<String, Any>

    public init(ruleId: String, outputs: HashMap<String, Any>) {
        this.ruleId = ruleId
        this.outputs = outputs
    }
}

/**
 * `fireDetailed` 的结果（`doc/10-roadmap.md` D10）。
 *
 * `outputs` 是整次 `fire` 合并后的输出槽；`fired` 保留逐条执行顺序，
 * 决策表命中策略的聚合依赖后者。
 */
public class FireResult {
    public let outputs: HashMap<String, Any>
    public let fired: Array<FiredRule>

    public init(outputs: HashMap<String, Any>, fired: Array<FiredRule>) {
        this.outputs = outputs
        this.fired = fired
    }
}

/**
 * 会话动作执行器（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 每个激活构造一个 `SessionActionContext`，动作改事实时通过 [FactPropagation]
 * 回写 Rete 网络；`runtime_` 在会话装配完成后注入（议程与网络互相引用）。
 */
class SessionActionRunner <: ActionRunner & FactPropagation {
    private let views_: FactBaseViewStore
    private let session_: String
    public var runtime: ?SessionRuntime = None

    SessionActionRunner(views: FactBaseViewStore, session: String) {
        this.views_ = views
        this.session_ = session
    }

    public func run(activation: Activation): HashMap<String, Any> {
        let view = views_.view(activation.factSpace, session_)
        let outputs = HashMap<String, Any>()
        let ctx = SessionActionContext(activation, view,
            { space: String => views_.view(space, session_) }, outputs, propagation: this)
        for (action in activation.rule.actions) {
            action.execute(ctx)
        }
        outputs
    }

    public func onAssert(space: String, handle: FactHandle, fact: Fact): Unit {
        match (runtime) {
            case Some(found) => found.assert(space, handle, fact)
            case None => ()
        }
    }

    public func onRetract(space: String, handle: FactHandle): Unit {
        match (runtime) {
            case Some(found) => found.retract(space, handle)
            case None => ()
        }
    }

    public func onUpdate(space: String, handle: FactHandle, fact: Fact): Unit {
        match (runtime) {
            case Some(found) => found.update(space, handle, fact)
            case None => ()
        }
    }
}

/**
 * 规则会话（`doc/08-api.md` §8）。
 *
 * 一个会话持有自己的事实库、Rete 运行态与议程；跨空间的激活进同一个议程统一排序。
 */
public class RuleSession {
    private let id_: String
    private let engine_: RuleEngine
    private let views_: FactBaseViewStore
    private let runtime_: SessionRuntime
    private let agenda_: Agenda
    private var disposed_: Bool

    init(engine: RuleEngine, id: String) {
        this.id_ = id
        this.engine_ = engine
        this.disposed_ = false
        this.views_ = FactBaseViewStore(engine.ruleSet.registry)
        let runner = SessionActionRunner(views_, id)
        var detector: ?CycleDetector = None
        if (engine.ruleSet.cycleDetection) {
            detector = CycleDetector(window: engine.ruleSet.cycleWindow,
                threshold: engine.ruleSet.cycleThreshold)
        }
        this.agenda_ = Agenda(engine.ruleSet.conflictResolver, runner: runner, cycle: detector)
        this.runtime_ = engine.network().session(id, agenda_)
        runner.runtime = Some(runtime_)
    }

    public prop id: String {
        get() {
            id_
        }
    }

    /** 缺省空间 `default` 的事实视图。 */
    public prop facts: FactBaseView {
        get() {
            views_.view(TypeTag.DEFAULT_SPACE, id_)
        }
    }

    /**
     * 指定空间的事实视图；空间未声明时抛 `UNKNOWN_FACT_SPACE`。
     *
     * 仓颉不允许属性与方法同名，因此文档里的 `facts(space)` 改名为 `factsOf(space)`；
     * 缺省空间的 `facts` 属性保持不变。
     */
    public func factsOf(space: String): FactBaseView {
        views_.view(space, id_)
    }

    public prop agenda: Agenda {
        get() {
            agenda_
        }
    }

    /** 在缺省空间插入。 */
    public func assert(fact: Fact): FactHandle {
        assert(TypeTag.DEFAULT_SPACE, fact)
    }

    /** 在指定空间插入；网络传播失败时回滚事实库。 */
    public func assert(space: String, fact: Fact): FactHandle {
        ensureOpen()
        let view = views_.view(space, id_)
        let handle = view.assert(fact)
        try {
            runtime_.assert(space, handle, fact)
        } catch (e: Exception) {
            let _ = view.retract(handle)
            throw e
        }
        handle
    }

    public func retract(handle: FactHandle): Unit {
        ensureOpen()
        let view = views_.view(handle.space, id_)
        if (view.retract(handle)) {
            runtime_.retract(handle.space, handle)
        }
    }

    public func update(handle: FactHandle, fact: Fact): Unit {
        ensureOpen()
        let view = views_.view(handle.space, id_)
        if (view.update(handle, fact)) {
            runtime_.update(handle.space, handle, fact)
        }
    }

    /** 执行议程，返回合并后的输出槽（[fireDetailed] 的薄封装）。 */
    public func fire(limit!: Int64 = -1): HashMap<String, Any> {
        fireDetailed(limit: limit).outputs
    }

    /** 执行议程并给出行级结果。 */
    public func fireDetailed(limit!: Int64 = -1): FireResult {
        ensureOpen()
        let _ = agenda_.fire(limit: limit)
        let fired = ArrayList<FiredRule>()
        for (record in agenda_.lastFired()) {
            fired.add(FiredRule(record.ruleId, record.outputs))
        }
        FireResult(agenda_.lastOutputs(), fired.toArray())
    }

    /** 释放本会话的事实、令牌与议程；由 `RuleEngine.release` 调用。 */
    func dispose(): Unit {
        if (disposed_) {
            return
        }
        disposed_ = true
        agenda_.clear()
        views_.release(id_)
    }

    private func ensureOpen(): Unit {
        if (disposed_ || engine_.closed) {
            throw RuleException(RuleErrorCode.CLOSED, "会话 ${id_} 已关闭")
        }
    }
}
