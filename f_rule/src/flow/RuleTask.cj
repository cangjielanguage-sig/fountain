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

import std.collection.HashMap
import fountain::f_egraph.base.{Event, Task, TaskEvent}
import fountain::f_rule.engine.RuleEngine
import fountain::f_rule.fact.{Fact, TypeTag}

/** 事件载荷 → `(space, fact)` 列表；缺省把 `Fact` 载荷插入 `default` 空间。 */
public type FactFactory = (RuleEnvelope) -> Array<(String, Fact)>

/**
 * 产生式模式与决策流模式的接缝（`doc/05-agenda-conflict-resolution.md` §10）。
 *
 * `exec` 顺序：取信封 → `FlowContext.attach` → 按 [FactFactory] 建事实 →
 * `agenda.fire()` → 输出槽包成下一个 `TaskEvent`。session 始终取自信封，
 * 输出事件也用 `RuleEnvelope.wrap` 保留 session/traceId。
 */
public class RuleTask <: Task {
    private let engine_: RuleEngine
    private let name_: String
    private let acceptable_: Array<String>
    private let output_: String
    private let factory_: FactFactory

    public init(engine: RuleEngine, name!: String, acceptable!: Array<String>, output!: String,
        factory!: ?FactFactory = None) {
        this.engine_ = engine
        this.name_ = name
        this.acceptable_ = acceptable
        this.output_ = output
        this.factory_ = match (factory) {
            case Some(found) => found
            case None => { envelope => RuleTask.defaultFactory(envelope) }
        }
        FlowContext.configure(engine.ruleSet.id, engine.ruleSet.registry)
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            acceptable_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            [output_]
        }
    }

    public func exec(e: Event): Event {
        let envelope = RuleEnvelope.from(e)
        let _ = FlowContext.attach(envelope)
        var outputs = HashMap<String, Any>()
        try {
            let session = engine_.session(envelope.session)
            for ((space, fact) in factory_(envelope)) {
                let _ = session.assert(space, fact)
            }
            outputs = session.fire()
        } finally {
            FlowContext.detach()
        }
        TaskEvent(
            category: e.category,
            tag: e.tag,
            name: output_,
            data: RuleEnvelope.wrap(e, outputs),
            session: envelope.session
        )
    }

    private static func defaultFactory(envelope: RuleEnvelope): Array<(String, Fact)> {
        if (let fact: Fact <- envelope.payload) {
            return [(TypeTag.DEFAULT_SPACE, fact)]
        }
        Array<(String, Fact)>()
    }
}
