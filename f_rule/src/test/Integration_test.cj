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
package fountain::f_rule.test

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_egraph.base.{DataEvent, EndEvent, EventType, ImmediateFlow}
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.condition.{ExpressionMode, JoinConstraint, Operator, Pattern}
import fountain::f_rule.engine.{RuleEngine, RuleSession}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, FactBase, FactSchema, FieldType, TypeTag, TypedFact}
import fountain::f_rule.flow.{RuleEnvelope, RuleTask}
import fountain::f_rule.rule.{Rule, RuleSet, RuleSetBuilder}
import fountain::f_rule.rete.{RecordingSink, ShardedNetwork}
import fountain::f_rule.runtime.RuleRuntime
import fountain::f_rule.table.DecisionTable

/** I-03 / I-04 的宿主类：字段必须 `public` 才能被 `@JitBind` 登记。 */
@JitBind
public class IntegrationOrder {
    public var orderId: Int64
    public var amount: Int64
    public var level: Int64

    public init(orderId: Int64, amount: Int64, level: Int64) {
        this.orderId = orderId
        this.amount = amount
        this.level = level
    }
}

/** 未登记进 `Compiler` 的宿主类（I-05 用）。 */
@JitBind
public class UnregisteredOrder {
    public var amount: Int64

    public init(amount: Int64) {
        this.amount = amount
    }
}

/**
 * 集成用例 I-01~I-06（`doc/09-testing.md` §3.7）。
 *
 * 覆盖跨层链路：决策表 → Rete → 议程 → 输出、决策流与产生式共享会话、
 * `f_jit` 与内置解释器逐条一致、脚本访问登记类型、未登记类型的构建期拒绝，
 * 以及 1000 规则 / 10000 事实的规模正确性与门禁。
 */
@Tag[integration]
@Test
class Integration_test {
    private func integrationSchema(): FactSchema<IntegrationOrder> {
        FactSchema<IntegrationOrder>("IntegrationOrder")
            .field("orderId", FieldType.Number) { o => o.orderId }
            .field("amount", FieldType.Number) { o => o.amount }
            .field("level", FieldType.Number) { o => o.level }
    }

    private func compiler(): Compiler {
        let compiler = Compiler()
        compiler.registerType<IntegrationOrder>()
        RuleRuntime.initCompiler(compiler)
        compiler
    }

    private func order(orderId: Int64, amount: Int64, level: Int64): IntegrationOrder {
        IntegrationOrder(orderId, amount, level)
    }

    private func dynamicOrder(orderId: Int64, amount: Int64, level: Int64): DynamicFact {
        let fact = DynamicFact("Order")
        fact.set("orderId", orderId)
        fact.set("amount", amount)
        fact.set("level", level)
        fact
    }

    /** I-01：决策表装配进规则集后，经 Rete 与议程产出输出。 */
    @TestCase
    public func i01DecisionTableRunsThroughReteAndAgenda(): Unit {
        let table = DecisionTable.builder("pricing")
            .factSpace("orders")
            .whenColumn("order.level")
            .whenColumn("order.amount")
            .thenColumn("discount")
            .row("R1", [">=3", ">200", "0.85"])
            .row("R2", [">=1", ">500", "0.90"])
            .build()
        let ruleSet = RuleSetBuilder("i01")
            .factSpace("orders")
            .registerDynamicType("orders", "Order", ["orderId", "amount", "level"])
            .table(table)
            .build()
        @Expect(ruleSet.rules.size, 2)

        let engine = RuleEngine(ruleSet)
        let session = engine.session("i01")
        let _ = session.assert("orders", dynamicOrder(1, 600, 3))
        let outputs = session.fire()

        // `First` 策略把两行放进同一互斥组：只执行行序最前（salience 最高）的 R1。
        @Expect(outputs.get("discount").getOrThrow() as Float64, 0.85)
    }

    /** I-02：决策流与产生式混用，同一 session 的事实跨任务可见。 */
    @TestCase
    public func i02FlowAndProductionShareSessionFacts(): Unit {
        let first = Rule.builder("R1")
            .addPattern(Pattern("Order", "o").constrain("amount", Operator.Gt, 200))
            .then({ ctx => ctx.set("discount", 0.85) })
            .build()
        let second = Rule.builder("R2")
            .addPattern(Pattern("Order", "a").constrain("amount", Operator.Gt, 200))
            .addPattern(Pattern("Order", "b").constrain("amount", Operator.Gt, 200))
            .join(JoinConstraint("a", "orderId", Operator.Lt, "b", "orderId"))
            .then({ ctx => ctx.set("paired", true) })
            .build()
        let ruleSet = RuleSetBuilder("i02")
            .registerDynamicType("default", "Order", ["orderId", "amount", "level"])
            .rule(first)
            .rule(second)
            .build()
        let engine = RuleEngine(ruleSet)

        let flow = ImmediateFlow(category: "i02", tag: "v1")
        flow.registerStart("order.created")
        flow.registerTask(RuleTask(engine, name: "pricing", acceptable: ["order.created"],
            output: "order.priced", factory: { _ =>
                [(TypeTag.DEFAULT_SPACE, dynamicOrder(1, 500, 2))]
            }))
        flow.registerTask(RuleTask(engine, name: "pairing", acceptable: ["order.priced"],
            output: "order.paired", factory: { _ =>
                [(TypeTag.DEFAULT_SPACE, dynamicOrder(2, 300, 1))]
            }))
        flow.registerTask("order.paired") { e =>
            let data = (e as DataEvent).getOrThrow().data
            EndEvent(category: "i02", tag: "v1", data: data, session: e.session)
        }
        flow.registerEnd()

        let envelope = RuleEnvelope(session: "s1", ruleSetId: "i02", payload: 0, traceId: "t1")
        let end = flow.start(envelope).get().get()
        @Expect(end.eventType, EventType.End)
        let outputs = (RuleEnvelope.from(end).unwrap() as HashMap<String, Any>).getOrThrow()
        // R2 需要两条 amount>200 的事实；第二条由第二个任务插入，第一条必须来自同一会话。
        @Expect(outputs.get("paired").getOrThrow() as Bool, true)
        @Expect(outputs.get("discount").getOrThrow() as Float64, 0.85)
    }

    /** I-03：`JitPreferred` 与 `Interpreted` 对同一批事实逐条给出相同结论。 */
    @TestCase
    public func i03JitAndInterpreterAgreePerFact(): Unit {
        let _ = compiler()
        let jitEngine = RuleEngine(engineOf("i03-jit", ExpressionMode.JitPreferred))
        let interpretedEngine = RuleEngine(engineOf("i03-interp", ExpressionMode.Interpreted))

        let samples = [
            order(1, 100, 1), order(2, 100, 3), order(3, 900, 0),
            order(4, 900, 4), order(5, 0, 2)
        ]
        var index: Int64 = 0
        for (sample in samples) {
            let jitSession = jitEngine.session("s${index}")
            let _ = jitSession.assert(TypedFact(sample, integrationSchema()))
            let jitOutputs = jitSession.fire()

            let interpretedSession = interpretedEngine.session("s${index}")
            let _ = interpretedSession.assert(TypedFact(sample, integrationSchema()))
            let interpretedOutputs = interpretedSession.fire()

            let left = jitOutputs.contains("hit")
            let right = interpretedOutputs.contains("hit")
            @Expect(left, right)
            index += 1
        }
    }

    /** I-04：脚本规则体能访问 `@JitBind` 登记的类型并读取字段。 */
    @TestCase
    public func i04ScriptReadsRegisteredHostType(): Unit {
        let _ = compiler()
        let ruleSet = RuleSetBuilder("i04")
            .registerFact(integrationSchema())
            .rule(Rule.builder("R1")
                .addPattern(Pattern("IntegrationOrder", "o").constrain("amount", Operator.Ge, 0))
                .script("{ o: IntegrationOrder => o.level >= 3 && o.amount > 200 }")
                .then({ ctx => ctx.set("hit", true) })
                .build())
            .build()
        let engine = RuleEngine(ruleSet)
        let session = engine.session("i04")
        let _ = session.assert(TypedFact(order(1, 500, 3), integrationSchema()))
        let _ = session.assert(TypedFact(order(2, 500, 1), integrationSchema()))
        let result = session.fireDetailed()
        @Expect(Int64(result.fired.size), 1)
        @Expect(result.outputs.contains("hit"), true)
    }

    /** I-05：脚本引用未登记类型时构建期拒绝，不进入运行期。 */
    @TestCase
    public func i05UnregisteredTypeFailsAtBuild(): Unit {
        let _ = compiler()
        let builder = RuleSetBuilder("i05")
            .registerFact(integrationSchema())
            .rule(Rule.builder("R1")
                .addPattern(Pattern("IntegrationOrder", "o").constrain("amount", Operator.Ge, 0))
                .script("{ o: UnregisteredOrder => o.amount > 10 }")
                .then({ ctx => ctx.set("hit", true) })
                .build())
        var code = RuleErrorCode.ILLEGAL_STATE
        try {
            let _ = builder.build()
        } catch (e: RuleException) {
            code = e.code
        }
        @Expect(code, RuleErrorCode.SCRIPT_COMPILE)
        @Expect(builder.buildOrInvalid().isValid(), false)
    }

    /** I-06：1000 规则 / 10000 事实的正确性 + 插入门禁。 */
    @TestCase
    public func i06ThousandRulesTenThousandFacts(): Unit {
        let ruleSet = PerfFixture.ruleSet("i06", 1000)
        let network = ShardedNetwork(ruleSet)
        let space = ruleSet.registry.get(TypeTag.DEFAULT_SPACE).getOrThrow()
        let facts = PerfFixture.facts(10000)
        let expected = PerfFixture.expectedActivations(1000, 10000)

        let sink = RecordingSink()
        let stats = PerfSupport.measure(0, 1) {
            let runtime = network.session("i06", sink)
            let base = FactBase(space, "i06")
            for (fact in facts) {
                runtime.assert(TypeTag.DEFAULT_SPACE, base.assert(fact), fact)
            }
        }
        PerfSupport.report("I-06 1000 规则 / 10000 事实插入", stats)
        @Assert(Int64(sink.size()), expected)
        PerfSupport.requireAtMost("I-06 插入", stats.p95(), PerfGate.B02_INSERT_NANOS)
    }

    private func engineOf(id: String, mode: ExpressionMode): RuleSet {
        RuleSetBuilder(id)
            .registerFact(integrationSchema())
            .expressionMode(mode)
            .rule(Rule.builder("R1")
                .addPattern(Pattern("IntegrationOrder", "o").constrain("amount", Operator.Ge, 0))
                .script("{ o: IntegrationOrder => o.level >= 3 }")
                .then({ ctx => ctx.set("hit", true) })
                .build())
            .build()
    }
}
