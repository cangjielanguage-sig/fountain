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

/** 记录落库结果与调用次数的假世界 */
class EvolutionFixture {
    public var saved: ArrayList<Skill> = ArrayList<Skill>()
    public var calls: Int64 = 0
    public var newDetails: String = '新版 三段式'

    public func chat(system: String, user: String): String {
        calls++
        if(system.contains('新版')){
            return '三段式'
        }
        if(system.contains('旧版')){
            return ''
        }
        if(user.contains('现有技能正文')){
            return newDetails
        }
        ''
    }

    public func sink(skill: Skill): Unit {
        saved.add(skill)
    }
}

/** 演进流水线：判定 → 提炼 → 门禁 → 落库 */
@Test
class SkillEvolutionJob_test {
    private static func skills(samples: Bool): ArrayList<Skill> {
        let functions = if(samples){
            '{"samples":[{"input":"写日报","expect":"三段式"}]}'
        }else{
            '{}'
        }
        ArrayList<Skill>([Skill(1, '日报助手', '旧版', functions, version: 1)])
    }

    private static func experiences(count: Int64): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        for(index in 0..count){
            result.add(ExperienceItem(index + 1, '日报助手 三段式 经验 ${index}'))
        }
        result
    }

    /** 门禁通过：版本 +1 并落库 */
    @TestCase
    func testEvolvesWhenGatePasses(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let report = SkillEvolutionJob.run(skills(true), experiences(3),
                HashMap<String, Int64>(), fixture.chat, SkillEvolutionState(),
                embedder: encoder(), now: 1000)
            @Expect(report.evolved.size, 1)
            @Expect(report.rejected.size, 0)
            @Expect(fixture.saved.size, 1)
            @Expect(fixture.saved[0].version, 2)
            @Expect(fixture.saved[0].details.contains('新版'), true)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 没样例：门禁拒绝，不落库 */
    @TestCase
    func testRejectsWithoutSamples(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let report = SkillEvolutionJob.run(skills(false), experiences(3),
                HashMap<String, Int64>(), fixture.chat, SkillEvolutionState(),
                embedder: encoder(), now: 1000)
            @Expect(report.evolved.size, 0)
            @Expect(report.rejected.size, 1)
            @Expect(report.rejected[0].contains('no samples'), true)
            @Expect(fixture.saved.size, 0)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 样本不足：策略直接跳过，一次模型都不调 */
    @TestCase
    func testSkipsWhenPolicyRejects(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let report = SkillEvolutionJob.run(skills(true), experiences(1),
                HashMap<String, Int64>(), fixture.chat, SkillEvolutionState(),
                embedder: encoder(), now: 1000)
            @Expect(report.skipped.size, 1)
            @Expect(report.skipped[0].contains('not enough successful samples'), true)
            @Expect(fixture.calls, 0)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 冷却期内：第二轮被跳过 */
    @TestCase
    func testSecondRunWithinCooldownIsSkipped(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let state = SkillEvolutionState()
            SkillEvolutionJob.run(skills(true), experiences(3),
                HashMap<String, Int64>(), fixture.chat, state,
                embedder: encoder(), now: 1000)
            let second = SkillEvolutionJob.run(skills(true), experiences(3),
                HashMap<String, Int64>(), fixture.chat, state,
                embedder: encoder(), now: 2000)
            @Expect(second.evolved.size, 0)
            @Expect(second.skipped.size, 1)
            @Expect(second.skipped[0].contains('cooldown'), true)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 归不到技能的经验聚成簇：只上报，不自动建技能 */
    @TestCase
    func testReportsCandidateClustersWithoutCreatingSkills(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let items = ArrayList<ExperienceItem>([
                ExperienceItem(1, '爬虫要限速'),
                ExperienceItem(2, '爬虫要重试'),
                ExperienceItem(3, '爬虫要记失败')
            ].toArray())
            let report = SkillEvolutionJob.run(skills(true), items,
                HashMap<String, Int64>(), fixture.chat, SkillEvolutionState(),
                embedder: encoder(), now: 1000)
            @Expect(report.candidateClusters, 1)
            @Expect(fixture.saved.size, 0)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 注册成定时任务后，触发一次即跑一轮演进 */
    @TestCase
    func testScheduleRunsOneRoundOnFire(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let scheduler = ManualScheduler()
        try{
            SkillEvolutionJob.schedule('nightly-skill', '0 0 3 * * * *', scheduler,
                { => skills(true) }, { => experiences(3) }, { => HashMap<String, Int64>() },
                fixture.chat, SkillEvolutionState(), embedder: encoder())
            @Expect(scheduler.crons.get('nightly-skill').getOrThrow(), '0 0 3 * * * *')

            scheduler.fire('nightly-skill')
            @Expect(fixture.saved.size, 1)
            @Expect(fixture.saved[0].version, 2)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 二维假编码器：日报与爬虫各占一维，保证归属可预期 */
    private static func encoder(): ?(String) -> Array<Float64> {
        { text =>
            if(text.contains('日报') || text.contains('三段式') || text.contains('旧版')
               || text.contains('新版')){
                [1.0f64, 0.0f64]
            }else if(text.contains('爬虫')){
                [0.0f64, 1.0f64]
            }else{
                [0.5f64, 0.5f64]
            }
        }
    }
}
