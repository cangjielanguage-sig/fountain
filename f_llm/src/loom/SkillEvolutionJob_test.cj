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
        if(system.contains('技能标题')){
            return '{"title":"爬虫助手","details":"限速、重试、记录失败",'
                + '"samples":[{"input":"爬虫怎么防封","expect":"限速"}]}'
        }
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

/** 演进流水线：水位线 → 演进已有技能 → 提炼新技能 */
@Test
class SkillEvolutionJob_test {
    private static let NONE = ArrayList<ExperienceItem>()

    private static func skills(samples: Bool): ArrayList<Skill> {
        let functions = if(samples){
            '{"samples":[{"input":"写日报","expect":"三段式"}]}'
        }else{
            '{}'
        }
        ArrayList<Skill>([Skill(1, '日报助手', '旧版', functions, version: 1)])
    }

    private static func experiences(count: Int64, at!: Int64 = 0): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        for(index in 0..count){
            result.add(ExperienceItem(index + 1, '日报助手 三段式 经验 ${index}', at: at))
        }
        result
    }

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

    /** 门禁通过：版本 +1 并落库 */
    @TestCase
    func testEvolvesWhenGatePasses(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let report = SkillEvolutionJob.run(skills(true), experiences(3), NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
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
            let report = SkillEvolutionJob.run(skills(false), experiences(3), NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
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
            let report = SkillEvolutionJob.run(skills(true), experiences(1), NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
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
            let state = InMemoryEvolutionStateStore()
            SkillEvolutionJob.run(skills(true), experiences(3), NONE, NONE,
                fixture.chat, state, embedder: encoder(), now: 1000)
            let second = SkillEvolutionJob.run(skills(true), experiences(3), NONE, NONE,
                fixture.chat, state, embedder: encoder(), now: 2000)
            @Expect(second.evolved.size, 0)
            @Expect(second.skipped.size, 1)
            @Expect(second.skipped[0].contains('cooldown'), true)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 水位线只推进到处理过的最大 at：超量素材留到下一轮，而不是被 now 永久跳过 */
    @TestCase
    func testWatermarkAdvancesToMaxProcessedAt(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let state = InMemoryEvolutionStateStore()
        try{
            let items = ArrayList<ExperienceItem>()
            items.add(ExperienceItem(1, '日报助手 三段式 经验 a', at: 10))
            items.add(ExperienceItem(2, '日报助手 三段式 经验 b', at: 20))
            items.add(ExperienceItem(3, '日报助手 三段式 经验 c', at: 30))

            SkillEvolutionJob.run(skills(true), items, NONE, NONE,
                fixture.chat, state, embedder: encoder(), now: 5000)

            // 不是 5000：否则 at=30 之后、now 之前的素材会被下一轮的 since 过滤掉
            @Expect(state.lastRunAt(), 30)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 跑完推进水位线：下一轮据此只取新增素材 */
    @TestCase
    func testMarksRunWatermark(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let state = InMemoryEvolutionStateStore()
        try{
            @Expect(state.lastRunAt(), 0)
            SkillEvolutionJob.run(skills(true), experiences(3), NONE, NONE,
                fixture.chat, state, embedder: encoder(), now: 5000)
            @Expect(state.lastRunAt(), 5000)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 水位线之前的老素材不参与：没有新素材就什么都不做 */
    @TestCase
    func testWatermarkSkipsOldMaterials(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let old = SkillEvolutionJob.run(skills(true), experiences(3, at: 100), NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), since: 500, now: 1000)
            @Expect(old.materials, 0)
            @Expect(old.evolved.size, 0)

            let fresh = SkillEvolutionJob.run(skills(true), experiences(3, at: 900), NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), since: 500, now: 1000)
            @Expect(fresh.materials, 3)
            @Expect(fresh.evolved.size, 1)
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
            let report = SkillEvolutionJob.run(skills(true), items, NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), now: 1000)
            @Expect(report.candidateClusters, 1)
            @Expect(fixture.saved.size, 0)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 知识也能成为新技能来源（知识 `at=0`，每轮都参与） */
    @TestCase
    func testKnowledgeFeedsNewSkill(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let knowledge = ArrayList<ExperienceItem>([
                ExperienceItem(1, '爬虫要限速'),
                ExperienceItem(2, '爬虫要重试'),
                ExperienceItem(3, '爬虫要记失败')
            ].toArray())
            let report = SkillEvolutionJob.run(skills(true), NONE, NONE, knowledge,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), nameCandidates: true, now: 1000)
            @Expect(report.materials, 3)
            @Expect(report.created.size, 1)
            @Expect(fixture.saved[0].title, '爬虫助手')
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 打开 nameCandidates：模型起名后真的建出技能 */
    @TestCase
    func testCreatesNamedSkillFromCandidateCluster(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let items = ArrayList<ExperienceItem>([
                ExperienceItem(1, '爬虫要限速'),
                ExperienceItem(2, '爬虫要重试'),
                ExperienceItem(3, '爬虫要记失败')
            ].toArray())
            let report = SkillEvolutionJob.run(skills(true), items, NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), nameCandidates: true, now: 1000)
            @Expect(report.candidateClusters, 1)
            @Expect(report.created.size, 1)
            @Expect(fixture.saved.size, 1)
            @Expect(fixture.saved[0].title, '爬虫助手')
            @Expect(fixture.saved[0].version, 1)
            @Expect(fixture.saved[0].details.contains('限速'), true)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 新建技能必须自带样例，否则下一轮无法自我演进 */
    @TestCase
    func testCreatedSkillCarriesSamples(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let items = ArrayList<ExperienceItem>([
                ExperienceItem(1, '爬虫要限速'),
                ExperienceItem(2, '爬虫要重试'),
                ExperienceItem(3, '爬虫要记失败')
            ].toArray())
            SkillEvolutionJob.run(skills(true), items, NONE, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), nameCandidates: true, now: 1000)
            @Expect(fixture.saved.size, 1)
            @Expect(fixture.saved[0].functions.contains('samples'), true)
            @Expect(SkillSamples.of(fixture.saved[0]).size, 1)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 模型给的名字不合法：宁可不建 */
    @TestCase
    func testInvalidNameSkipsCreation(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let badChat = { system: String, user: String =>
            if(system.contains('技能标题')){
                '不是 JSON'
            }else{
                ''
            }
        }
        try{
            let items = ArrayList<ExperienceItem>([
                ExperienceItem(1, '爬虫要限速'),
                ExperienceItem(2, '爬虫要重试'),
                ExperienceItem(3, '爬虫要记失败')
            ].toArray())
            let report = SkillEvolutionJob.run(skills(true), items, NONE, NONE,
                badChat, InMemoryEvolutionStateStore(),
                embedder: encoder(), nameCandidates: true, now: 1000)
            @Expect(report.created.size, 0)
            @Expect(fixture.saved.size, 0)
            @Expect(report.rejected[0].contains('valid name'), true)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 失败经验按技能归属后计入成功率：3 成功 2 失败 → 0.6 未达标，跳过 */
    @TestCase
    func testFailuresAreAttributedPerSkill(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        try{
            let failed = ArrayList<ExperienceItem>([
                ExperienceItem(1, '日报助手 三段式 出错'),
                ExperienceItem(2, '日报助手 结论 出错')
            ].toArray())
            let report = SkillEvolutionJob.run(skills(true), experiences(3), failed, NONE,
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), now: 1000)
            @Expect(report.evolved.size, 0)
            @Expect(report.skipped.size, 1)
            @Expect(report.skipped[0].contains('success rate too low'), true)
            @Expect(fixture.calls, 0)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 从存储按 kind 取两批经验 + 知识 */
    @TestCase
    func testLoadReadsExperiencesByKind(): Unit {
        let gateway = LoomStoreGateway(InMemoryContentStore(), InMemoryMetaStore())
        gateway.call('memory', 'add',
            '{"userId":1,"namespace":"n","title":"a","content":"日报 成功一","kind":"experience"}')
        gateway.call('memory', 'add',
            '{"userId":1,"namespace":"n","title":"b","content":"日报 成功二","kind":"experience"}')
        gateway.call('memory', 'add',
            '{"userId":1,"namespace":"n","title":"c","content":"日报 失败一","kind":"experience_failed"}')
        gateway.call('knowledge', 'upsert',
            '{"docId":"loom:1:n:daily:1-1","title":"t","content":"知识正文"}')

        let input = SkillEvolutionJob.load(gateway, 1, 'n')
        @Expect(input.successes.size, 2)
        @Expect(input.failures.size, 1)
        @Expect(input.knowledge.size, 1)
        @Expect(input.knowledge[0].content.contains('知识正文'), true)
    }

    /** 每日租约：同一天触发两次，只有第一次真正执行 */
    @TestCase
    func testLeaseAllowsOnlyOneRunPerDay(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let scheduler = ManualScheduler()
        let lease = InMemoryEvolutionLease()
        let stamp = 1_700_000_000
        try{
            SkillEvolutionJob.schedule('lease-skill', '0 0 3 * * * *', scheduler,
                { => skills(true) },
                { => EvolutionInput(experiences(3), NONE) },
                fixture.chat, InMemoryEvolutionStateStore(),
                embedder: encoder(), lease: lease, clock: { => stamp })
            scheduler.fire('lease-skill')
            @Expect(fixture.saved.size, 1)

            // 同一天第二次触发：租约不放行
            scheduler.fire('lease-skill')
            @Expect(fixture.saved.size, 1)

            // 第二天：租约放行，但冷却期还在，所以仍然只演进了 1 次
            @Expect(lease.acquire(stamp + 86400).isEmpty(), false)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 知识消费一次后不再重复参与聚类 */
    @TestCase
    func testConsumedKnowledgeIsNotReclustered(): Unit {
        let fixture = EvolutionFixture()
        SkillEvolutionJob.installSink(fixture.sink)
        let state = InMemoryEvolutionStateStore()
        let knowledge = ArrayList<ExperienceItem>([
            ExperienceItem(1, '爬虫要限速', source: 'k1'),
            ExperienceItem(2, '爬虫要重试', source: 'k2'),
            ExperienceItem(3, '爬虫要记失败', source: 'k3')
        ].toArray())
        try{
            let first = SkillEvolutionJob.run(skills(true), NONE, NONE, knowledge,
                fixture.chat, state, embedder: encoder(), nameCandidates: true, now: 1000)
            @Expect(first.materials, 3)
            @Expect(first.created.size, 1)

            // 第二轮：这批知识已被消费，素材池为空
            let second = SkillEvolutionJob.run(skills(true), NONE, NONE, knowledge,
                fixture.chat, state, embedder: encoder(), nameCandidates: true, now: 2000)
            @Expect(second.materials, 0)
            @Expect(second.created.size, 0)
            @Expect(state.processedKnowledge().size, 3)
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
        let state = InMemoryEvolutionStateStore()
        try{
            SkillEvolutionJob.schedule('nightly-skill', '0 0 3 * * * *', scheduler,
                { => skills(true) },
                { => EvolutionInput(experiences(3), NONE) },
                fixture.chat, state, embedder: encoder(), clock: { => 7000 })
            @Expect(scheduler.crons.get('nightly-skill').getOrThrow(), '0 0 3 * * * *')

            scheduler.fire('nightly-skill')
            @Expect(fixture.saved.size, 1)
            @Expect(fixture.saved[0].version, 2)
            @Expect(state.lastRunAt(), 7000)
        }finally{
            SkillEvolutionJob.resetSink()
        }
    }

    /** 知识素材按租户前缀过滤 */
    @TestCase
    func testOwnedByFiltersOtherTenants(): Unit {
        @Expect(SkillEvolutionJob.ownedBy('loom:7:work:daily:1-1', 7, 'work'), true)
        @Expect(SkillEvolutionJob.ownedBy('loom:8:work:daily:1-1', 7, 'work'), false)
        @Expect(SkillEvolutionJob.ownedBy('loom:7:other:daily:1-1', 7, 'work'), false)
        @Expect(SkillEvolutionJob.ownedBy('loom:daily:1', 7, 'work'), false)
    }
}
