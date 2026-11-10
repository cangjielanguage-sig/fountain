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
package fountain::f_rule.agenda

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.rule.RuleSetBuilder
import fountain::f_rule.condition.Pattern
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{DynamicFact, Fact, FactHandle}
import fountain::f_rule.rule.{DefaultConflictResolver, Rule}

/**
 * 循环检测（`doc/05-agenda-conflict-resolution.md` §9，A-11）。
 *
 * 覆盖：窗口内同一指纹第 101 次抛 `CYCLE_LIMIT`、默认关闭、窗口滑动后不再计数。
 */
@Test
class CycleDetection_test {
    private func activation(id: String, factId: Int64): Activation {
        let fact = DynamicFact("Order")
        fact.set("amount", 300)
        let handles = HashMap<String, FactHandle>()
        let facts = HashMap<String, Fact>()
        handles["o"] = FactHandle("orders", factId, "Order")
        facts["o"] = fact
        let rule = Rule.builder(id)
            .facts("orders")
            .addPattern(Pattern("Order", "o"))
            .build()
        Activation(rule, Bindings.of(handles, facts))
    }

    private func codeOf(body: () -> Unit): RuleErrorCode {
        try {
            body()
        } catch (e: RuleException) {
            return e.code
        }
        RuleErrorCode.CLOSED
    }

    /** 同一指纹第 101 次出现抛 `CYCLE_LIMIT`。 */
    @TestCase
    public func hundredthFirstOccurrenceExceedsLimit(): Unit {
        let detector = CycleDetector(window: 10000, threshold: 100)
        let item = activation("R1", 1)
        var i: Int64 = 0
        while (i < 100) {
            detector.record(item)
            i += 1
        }

        let code = codeOf({ => detector.record(item) })
        @Expect(code, RuleErrorCode.CYCLE_LIMIT)
    }

    /** 不同指纹各自独立计数。 */
    @TestCase
    public func differentFingerprintsAreIndependent(): Unit {
        let detector = CycleDetector(window: 10000, threshold: 100)
        var i: Int64 = 0
        while (i < 100) {
            detector.record(activation("R1", 1))
            detector.record(activation("R2", 2))
            i += 1
        }
        // 两个指纹各 100 次，都还在阈值内
        detector.record(activation("R3", 3))
    }

    /** 窗口滑动后旧记录被淘汰，不会累计到阈值。 */
    @TestCase
    public func evictedFingerprintsStopCounting(): Unit {
        let detector = CycleDetector(window: 10, threshold: 100)
        let item = activation("R1", 1)
        var i: Int64 = 0
        while (i < 200) {
            detector.record(item)
            i += 1
        }
    }

    /** `RuleSet.enableCycleDetection` 默认关闭，开启后窗口可配置。 */
    @TestCase
    public func cycleDetectionIsOptIn(): Unit {
        let builder = RuleSetBuilder("cycle")
            .registerDynamicType("default", "GenFact", ["amount"])
        let rule = Rule.builder("R1")
            .addPattern(Pattern("GenFact", "g"))
            .build()
        let ruleSet = builder.rule(rule).build()

        @Expect(ruleSet.cycleDetection, false)
        @Assert(ruleSet.cycleWindow, 10000)
        @Assert(ruleSet.cycleThreshold, 100)

        ruleSet.enableCycleDetection(window: 50)
        @Expect(ruleSet.cycleDetection, true)
        @Assert(ruleSet.cycleWindow, 50)
    }

    /** 议程接入检测器后，Loop 超限抛 `CYCLE_LIMIT`。 */
    @TestCase
    public func agendaRaisesWhenCycleLimitReached(): Unit {
        let raiser = RequeueRunner()
        let detector = CycleDetector(window: 10000, threshold: 100)
        let target = Agenda(DefaultConflictResolver(), mode: FireMode.Loop, runner: raiser,
            cycle: detector)
        let item = activation("R1", 1)
        raiser.target = Some(target)
        target.add(item)

        let code = codeOf({ => let _ = target.fire(limit: 1000) })
        @Expect(code, RuleErrorCode.CYCLE_LIMIT)
    }
}
