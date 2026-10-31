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
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{DataEvent, EndEvent, EventType, ImmediateFlow, TaskEvent}
import fountain::f_rule.rule.{Rule, RuleSetBuilder}
import fountain::f_rule.engine.RuleEngine
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact}

/**
 * 产生式接缝（`doc/05-agenda-conflict-resolution.md` §10、`doc/06` §6）。
 *
 * `RuleTask.exec` 按信封取 session，构造事实、执行议程，再把输出槽包成下一个事件；
 * 输出事件的 session 与输入信封一致（I-02 的前置）。
 */
@Test
class RuleTask_test {
    private func engine(id: String): RuleEngine {
        let rule = Rule.builder("R1")
            .facts("orders")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
            .then({ ctx => ctx.set("discount", 0.85) })
            .build()
        let ruleSet = RuleSetBuilder(id)
            .version("v1")
            .factSpace("orders")
            .registerDynamicType("orders", "Order", ["amount"])
            .rule(rule)
            .build()
        RuleEngine(ruleSet)
    }

    private func order(amount: Int64): Fact {
        let fact = DynamicFact("Order")
        fact.set("amount", amount)
        fact
    }

    private func task(engine: RuleEngine, output!: String = "order.priced"): RuleTask {
        RuleTask(engine, name: "rule", acceptable: ["order.created"],
            output: output, factory: { env =>
                [("orders", order((env.payload as Int64).getOrThrow()))]
            })
    }

    private func input(ruleSetId: String, payload: Any): TaskEvent {
        TaskEvent(category: ruleSetId, tag: "v1", name: "order.created",
            data: RuleEnvelope(session: "s1", ruleSetId: ruleSetId, payload: payload, traceId: "t1"),
            session: "event-session")
    }

    /** 执行议程并把输出槽包进下一事件，session 取信封。 */
    @TestCase
    public func executesAgendaAndKeepsSession(): Unit {
        let id = "ruletask-exec"
        let eng = engine(id)
        let event = task(eng).exec(input(id, 500))
        @Expect(event.eventType, EventType.Task)
        @Expect(event.name, "order.priced")
        @Expect(event.session, "s1")
        let envelope = RuleEnvelope.from(event)
        @Expect(envelope.session, "s1")
        @Expect(envelope.traceId, "t1")
        let outputs = (envelope.unwrap() as HashMap<String, Any>).getOrThrow()
        @Expect(outputs.get("discount").getOrThrow() as Float64, 0.85)
        @Expect(eng.session("s1").factsOf("orders").size(), 1)
    }

    /** 未声明空间抛 `UNKNOWN_FACT_SPACE`，且 finally 解绑上下文。 */
    @TestCase
    public func unknownSpaceIsRejected(): Unit {
        let id = "ruletask-unknown"
        let eng = engine(id)
        let bad = RuleTask(eng, name: "rule", acceptable: ["order.created"],
            output: "order.priced", factory: { _ => [("nope", order(500))] })
        var caught = RuleErrorCode.CLOSED
        try {
            let _ = bad.exec(input(id, 500))
        } catch (e: RuleException) {
            caught = e.code
        }
        @Expect(caught, RuleErrorCode.UNKNOWN_FACT_SPACE)
        var noContext = RuleErrorCode.CLOSED
        try {
            FlowContext.current()
        } catch (e: RuleException) {
            noContext = e.code
        }
        @Expect(noContext, RuleErrorCode.NO_CONTEXT)
    }

    /** 接入真实 Flow：结束事件仍带同一 session 与输出。 */
    @TestCase
    public func worksInsideImmediateFlow(): Unit {
        let id = "ruletask-flow"
        let eng = engine(id)
        let flow = ImmediateFlow(category: id, tag: "v1")
        flow.registerStart("order.created")
        flow.registerTask(task(eng))
        flow.registerTask("order.priced") { e =>
            let data = (e as DataEvent).getOrThrow().data
            EndEvent(category: id, tag: "v1", data: data, session: e.session)
        }
        flow.registerEnd()
        let envelope = RuleEnvelope(session: "s1", ruleSetId: id, payload: 500)
        let end = flow.start(envelope).get().get()
        @Expect(end.eventType, EventType.End)
        let result = (RuleEnvelope.from(end).unwrap() as HashMap<String, Any>).getOrThrow()
        @Expect(result.get("discount").getOrThrow() as Float64, 0.85)
    }
}
