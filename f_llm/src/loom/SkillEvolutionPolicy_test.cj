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
package fountain::f_llm.loom

import std.unittest.*
import std.unittest.testmacro.*

/** 演进触发策略：样本数、成功率、冷却期（含失败后加长） */
@Test
class SkillEvolutionPolicy_test {
    private static let NOW: Int64 = 1_000_000

    /** 样本够、从未演进：放行 */
    @TestCase
    func testAllowsWhenEnoughSamples(): Unit {
        let decision = SkillEvolutionPolicy().decide(3, 0, 0, true, NOW)
        @Expect(decision.shouldEvolve, true)
        @Expect(decision.reason, 'ok')
    }

    /** 成功样本不足：拦下 */
    @TestCase
    func testRejectsWhenSamplesTooFew(): Unit {
        let decision = SkillEvolutionPolicy().decide(2, 5, 0, true, NOW)
        @Expect(decision.shouldEvolve, false)
        @Expect(decision.reason.contains('not enough successful samples'), true)
    }

    /** 成功率不达标：拦下 */
    @TestCase
    func testRejectsWhenSuccessRateLow(): Unit {
        let decision = SkillEvolutionPolicy().decide(3, 7, 0, true, NOW)
        @Expect(decision.shouldEvolve, false)
        @Expect(decision.reason.contains('success rate too low'), true)
    }

    /** 冷却期内：拦下 */
    @TestCase
    func testRejectsWithinCooldown(): Unit {
        let decision = SkillEvolutionPolicy().decide(5, 0, NOW - 3600, true, NOW)
        @Expect(decision.shouldEvolve, false)
        @Expect(decision.reason.contains('cooldown'), true)
    }

    /** 上次门禁失败：冷却期更长 */
    @TestCase
    func testFailedGateUsesLongerCooldown(): Unit {
        // 距上次 1.5 天：正常冷却（1 天）已过，但失败冷却（2 天）未过
        let decision = SkillEvolutionPolicy().decide(5, 0, NOW - 129600, false, NOW)
        @Expect(decision.shouldEvolve, false)
        @Expect(decision.reason.contains('last gate passed: false'), true)
    }

    /** 冷却期过后：放行 */
    @TestCase
    func testAllowsAfterCooldown(): Unit {
        let decision = SkillEvolutionPolicy().decide(5, 0, NOW - 200000, false, NOW)
        @Expect(decision.shouldEvolve, true)
    }

    /** 阈值可配：放宽样本数后少量样本也能演进 */
    @TestCase
    func testCustomThresholds(): Unit {
        let policy = SkillEvolutionPolicy(minSamples: 1, minSuccessRate: 0.5f64)
        @Expect(policy.decide(1, 1, 0, true, NOW).shouldEvolve, true)
    }
}
