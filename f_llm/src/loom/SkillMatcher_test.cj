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

/** 经验归属发现：归到已有技能、聚成新技能候选、关键词降级 */
@Test
class SkillMatcher_test {
    /** 三维假编码器：日报 / 评审 / 其它各占一维 */
    private static func encoder(): (String) -> Array<Float64> {
        { text =>
            if(text.contains('日报') || text.contains('三段式')){
                [1.0f64, 0.0f64, 0.0f64]
            }else if(text.contains('评审') || text.contains('挑错')){
                [0.0f64, 1.0f64, 0.0f64]
            }else{
                [0.0f64, 0.0f64, 1.0f64]
            }
        }
    }

    private static func skills(): ArrayList<Skill> {
        ArrayList<Skill>([Skill(1, '日报助手', '先列三段式，再给数据', '{}', version: 1)])
    }

    private static func items(contents: Array<String>): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        var id: Int64 = 0
        for(text in contents){
            id++
            result.add(ExperienceItem(id, text))
        }
        result
    }

    /** 与技能同向的经验归到该技能 */
    @TestCase
    func testAssignsExperienceToExistingSkill(): Unit {
        let result = SkillMatcher.assign(
            items(['写日报要三段式', '日报结尾给结论']), skills(), embedder: encoder())
        @Expect(result.assignments.size, 1)
        @Expect(result.assignments[0].skillTitle, '日报助手')
        @Expect(result.assignments[0].experiences.size, 2)
        @Expect(result.candidates.size, 0)
    }

    /** 够数的相似经验聚成新技能候选 */
    @TestCase
    func testClustersUnmatchedExperiencesIntoCandidate(): Unit {
        let result = SkillMatcher.assign(
            items(['爬虫要限速', '爬虫要重试', '爬虫要记录失败']), skills(), embedder: encoder())
        @Expect(result.assignments.size, 0)
        @Expect(result.candidates.size, 1)
        @Expect(result.candidates[0].experiences.size, 3)
    }

    /** 不够 minCluster 条：不提案新技能 */
    @TestCase
    func testSmallClusterIsNotProposed(): Unit {
        let result = SkillMatcher.assign(
            items(['爬虫要限速', '爬虫要重试']), skills(), embedder: encoder(),
            minCluster: 3)
        @Expect(result.candidates.size, 0)
        @Expect(result.assignedCount, 0)
    }

    /** 没有编码器：退回关键词，阈值放宽后仍能归属 */
    @TestCase
    func testKeywordFallbackAssignsByTextOverlap(): Unit {
        let result = SkillMatcher.assign(
            items(['日报助手 先列三段式 再给数据 最后给结论']), skills(), threshold: 0.5)
        @Expect(result.assignments.size, 1)
        @Expect(result.assignments[0].skillTitle, '日报助手')
    }

    /** 空输入不报错 */
    @TestCase
    func testEmptyInput(): Unit {
        let result = SkillMatcher.assign(ArrayList<ExperienceItem>(), skills(), embedder: encoder())
        @Expect(result.assignments.size, 0)
        @Expect(result.candidates.size, 0)
    }
}
