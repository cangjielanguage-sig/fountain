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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/** A/B 门禁：只有新版不比旧版差才落库 */
@Test
class SkillGate_test {
    private static func samples(): ArrayList<SkillSample> {
        ArrayList<SkillSample>([
            SkillSample('写日报', '三段式'),
            SkillSample('写周报', '结论')
        ].toArray())
    }

    /** 假模型：system 里出现关键词就回显对应答案 */
    private static func chat(hits: Array<String>): (String, String) -> String {
        { system, user =>
            var text = ''
            for(word in hits){
                if(system.contains(word)){
                    text += word + ' '
                }
            }
            text
        }
    }

    /** 新版更好：放行 */
    @TestCase
    func testPassesWhenNewVersionIsBetter(): Unit {
        // 旧版什么都不命中，新版命中两个关键词
        let result = SkillGate.evaluate(chat(['三段式', '结论']), '旧正文', '新正文 三段式 结论',
            samples(), minScore: 0.6)
        @Expect(result.passed, true)
        @Expect(result.oldScore, 0.0f64)
        @Expect(result.newScore, 1.0f64)
    }

    /** 新版更差：拦下 */
    @TestCase
    func testRejectsWhenNewVersionIsWorse(): Unit {
        let result = SkillGate.evaluate(chat(['三段式', '结论']), '旧正文 三段式 结论', '新正文',
            samples(), minScore: 0.6)
        @Expect(result.passed, false)
        @Expect(result.reason.contains('scores lower'), true)
    }

    /** 平手且达标：放行 */
    @TestCase
    func testPassesOnTieAboveMinScore(): Unit {
        let result = SkillGate.evaluate(chat(['三段式', '结论']), '三段式 结论', '三段式 结论',
            samples(), minScore: 0.6)
        @Expect(result.passed, true)
        @Expect(result.newScore, 1.0f64)
    }

    /** 绝对分不达标：拦下 */
    @TestCase
    func testRejectsBelowMinScore(): Unit {
        let result = SkillGate.evaluate(chat(['三段式']), '旧', '三段式', samples(), minScore: 0.9)
        @Expect(result.passed, false)
        @Expect(result.reason.contains('below minScore'), true)
    }

    /** 没有样例：拒绝，不能无据落库 */
    @TestCase
    func testRejectsWithoutSamples(): Unit {
        let result = SkillGate.evaluate(chat(['三段式']), '旧', '新', ArrayList<SkillSample>())
        @Expect(result.passed, false)
        @Expect(result.reason.contains('no samples'), true)
    }

    /** 样例从技能包的 functions.samples 解析 */
    @TestCase
    func testSamplesParsedFromSkillFunctions(): Unit {
        let skill = Skill(1, '日报助手', '正文',
            '{"samples":[{"input":"写日报","expect":"三段式"},{"input":"无 expect"}]}', version: 1)
        let parsed = SkillSamples.of(skill)
        @Expect(parsed.size, 1)
        @Expect(parsed[0].input, '写日报')
        @Expect(parsed[0].expect, '三段式')
    }

    /** functions 不是 JSON：安全返回空 */
    @TestCase
    func testMalformedFunctionsYieldsNoSamples(): Unit {
        @Expect(SkillSamples.of(Skill(1, 't', 'd', 'not-json', version: 1)).size, 0)
    }
}
