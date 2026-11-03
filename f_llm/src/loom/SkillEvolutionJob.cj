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
import std.sync.*

import fountain::f_data.*

import fountain::f_llm.store.*

/** 一轮演进需要的两批经验 */
public class EvolutionInput {
    public let successes: ArrayList<ExperienceItem>
    public let failures: ArrayList<ExperienceItem>

    public init(successes: ArrayList<ExperienceItem>, failures: ArrayList<ExperienceItem>) {
        this.successes = successes
        this.failures = failures
    }
}

/** 每个技能的演进状态：上次尝试时间、上次是否过门禁 */
public class SkillEvolutionState {
    private let mutex = Mutex()
    private var lastAt = HashMap<String, Int64>()
    private var lastPassed = HashMap<String, Bool>()

    public init() {
    }

    public func lastEvolvedAt(skillTitle: String): Int64 {
        let box = TimeBox()
        synchronized(mutex){
            box.value = lastAt.get(skillTitle) ?? 0
        }
        box.value
    }

    public func lastGatePassed(skillTitle: String): Bool {
        let box = FlagBox()
        synchronized(mutex){
            box.value = lastPassed.get(skillTitle) ?? true
        }
        box.value
    }

    public func mark(skillTitle: String, at: Int64, passed: Bool): Unit {
        synchronized(mutex){
            lastAt[skillTitle] = at
            lastPassed[skillTitle] = passed
        }
    }
}

public class SkillEvolutionReport {
    public let evolved: ArrayList<String>
    public let rejected: ArrayList<String>
    public let skipped: ArrayList<String>
    /** 本轮新建的技能标题（`nameCandidates: true` 时才会出现） */
    public let created: ArrayList<String>
    public let candidateClusters: Int64

    public init(evolved: ArrayList<String>, rejected: ArrayList<String>,
                skipped: ArrayList<String>, created: ArrayList<String>,
                candidateClusters: Int64) {
        this.evolved = evolved
        this.rejected = rejected
        this.skipped = skipped
        this.created = created
        this.candidateClusters = candidateClusters
    }
}

/**
 * 演进流水线：判定 → 提炼 → A/B 门禁 → 落库。
 *
 * 四步的顺序是刻意的：
 * 1. **判定**（[SkillEvolutionPolicy]）不通过就直接跳过，连模型都不调；
 * 2. **提炼**让模型基于该技能的成功经验产出新版正文；
 * 3. **门禁**（[SkillGate]）用技能自带样例跑 A/B，不达标不落库；
 * 4. **落库**成功才把版本 +1，并记录状态供下一轮冷却期使用。
 *
 * 聚成簇但还归不到任何技能的经验只作为「新技能候选」上报，不自动建库——
 * 起名字、定边界需要人确认。
 */
public class SkillEvolutionJob {
    private init() {
    }

    public static func run(skills: ArrayList<Skill>,
                           successes: ArrayList<ExperienceItem>,
                           failures: ArrayList<ExperienceItem>,
                           chat: (String, String) -> String,
                           state: SkillEvolutionState,
                           policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(),
                           embedder!: ?(String) -> Array<Float64> = None,
                           matcherThreshold!: Float64 = 0.75,
                           nameCandidates!: Bool = false,
                           now!: Int64 = 0): SkillEvolutionReport {
        let evolved = ArrayList<String>()
        let rejected = ArrayList<String>()
        let skipped = ArrayList<String>()

        let matched = SkillMatcher.assign(successes, skills, embedder: embedder,
                                          threshold: matcherThreshold)
        let owner = HashMap<String, ArrayList<ExperienceItem>>()
        for(item in matched.assignments){
            owner[item.skillTitle] = item.experiences
        }

        // 失败经验同样按技能归属后计数：成功率要按「这个技能的历史表现」算，
        // 不能拿全局成败冒充——不同技能的难度差很多
        let failed = SkillMatcher.assign(failures, skills, embedder: embedder,
                                         threshold: matcherThreshold)
        let failureCounts = HashMap<String, Int64>()
        for(item in failed.assignments){
            failureCounts[item.skillTitle] = Int64(item.experiences.size)
        }

        for(skill in skills){
            let items = owner.get(skill.title) ?? ArrayList<ExperienceItem>()
            let failureCount = failureCounts.get(skill.title) ?? 0
            let decision = policy.decide(Int64(items.size), failureCount,
                state.lastEvolvedAt(skill.title), state.lastGatePassed(skill.title), now)
            if(!decision.shouldEvolve){
                skipped.add('${skill.title}: ${decision.reason}')
                continue
            }

            let usage = usageOf(items)
            let prompt = '现有技能正文：\n${skill.details}\n\n近期使用情况：\n${usage}\n\n'
                + '把使用情况里可复用的经验合并进正文，输出新的正文，不要输出解释。'
            let newDetails = try{
                chat('', prompt)
            }catch(error: Exception){
                ''
            }
            if(newDetails.trimAscii().isEmpty()){
                rejected.add('${skill.title}: evolution returned empty content')
                state.mark(skill.title, now, false)
                continue
            }

            let samples = SkillSamples.of(skill)
            let gate = SkillGate.evaluate(chat, skill.details, newDetails, samples)
            if(!gate.passed){
                rejected.add('${skill.title}: ${gate.reason}')
                state.mark(skill.title, now, false)
                continue
            }
            skillStoreUpsert(skill, newDetails.trimAscii())
            evolved.add('${skill.title}: v${skill.version} -> v${skill.version + 1} (${gate.reason})')
            state.mark(skill.title, now, true)
        }

        // 新技能候选：只有显式开启 nameCandidates 才让模型起名并落库
        let created = ArrayList<String>()
        if(nameCandidates && !matched.candidates.isEmpty()){
            var nextId: Int64 = 1
            for(skill in skills){
                if(skill.id >= nextId){
                    nextId = skill.id + 1
                }
            }
            for(candidate in matched.candidates){
                match(SkillNamer.propose(chat, candidate.experiences)){
                    case Some(draft) =>
                        emit(Skill(nextId, draft.title, draft.details, '{}', version: 1))
                        created.add('${draft.title} (id=${nextId})')
                        nextId++
                    case None =>
                        rejected.add('candidate cluster: model did not return a valid name')
                }
            }
        }

        SkillEvolutionReport(evolved, rejected, skipped, created,
            Int64(matched.candidates.size))
    }

    /**
     * 从存储里取本轮输入：成功经验、失败经验各一批。
     *
     * 经验写入时不绑定技能，所以这里只能按 `kind` 取；归属由 [run] 内部的匹配完成。
     */
    public static func load(gateway: LoomStoreGateway, userId: Int64, namespace: String,
                            limit!: Int64 = 500): EvolutionInput {
        EvolutionInput(experiencesOf(gateway, userId, namespace, 'experience', limit),
                       experiencesOf(gateway, userId, namespace, 'experience_failed', limit))
    }

    private static func experiencesOf(gateway: LoomStoreGateway, userId: Int64,
                                      namespace: String, kind: String,
                                      limit: Int64): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        let payload = '{"userId":${userId},'
            + '"namespace":${FlowPlan.jsonQuote(namespace)},'
            + '"kind":${FlowPlan.jsonQuote(kind)},'
            + '"offset":0,"limit":${limit}}'
        let text = try{
            gateway.call('memory', 'list', payload)
        }catch(error: Exception){
            '[]'
        }
        let json = match(JsonValue.fromStr(text) as JsonArray){
            case Some(value) => value
            case None => return result
        }
        for(item in json){
            match(item as JsonObject){
                case Some(record) =>
                    let id = match(record.get('id')){
                        case Some(value) => Int64.tryParse(value.toString()) ?? 0
                        case None => 0
                    }
                    let content = match(record.get('content')){
                        case Some(value) =>
                            match(value as JsonString){
                                case Some(field) => field.value
                                case None => ''
                            }
                        case None => ''
                    }
                    if(!content.isEmpty()){
                        result.add(ExperienceItem(id, content))
                    }
                case None => ()
            }
        }
        result
    }

    /**
     * 注册成定时任务：到点跑一轮（判定 → 提炼 → 门禁 → 落库）。
     *
     * 依赖的输入都用闭包传入，因为技能库、经验库、当前时间是运行期才确定的。
     */
    public static func schedule(name: String, cron: String, scheduler: LoomScheduler,
                                skills: () -> ArrayList<Skill>,
                                successes: () -> ArrayList<ExperienceItem>,
                                failures: () -> ArrayList<ExperienceItem>,
                                chat: (String, String) -> String,
                                state: SkillEvolutionState,
                                policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(),
                                embedder!: ?(String) -> Array<Float64> = None,
                                nameCandidates!: Bool = false,
                                clock!: () -> Int64 = { => 0 }): Unit {
        scheduler.schedule(name, cron, { =>
            try{
                run(skills(), successes(), failures(), chat, state,
                    policy: policy, embedder: embedder,
                    nameCandidates: nameCandidates, now: clock())
            }catch(error: Exception){
                // 定时线程不能把异常抛出去，否则会中断后续调度
                ()
            }
        })
    }

    /** 落库入口单独抽出来，测试可以替换成不落库的桩 */
    private static var sink: ?(Skill) -> Unit = None

    public static func installSink(fn: (Skill) -> Unit): Unit {
        synchronized(sinkMutex){
            sink = Some(fn)
        }
    }

    public static func resetSink(): Unit {
        synchronized(sinkMutex){
            sink = None
        }
    }

    private static let sinkMutex = Mutex()

    private static func skillStoreUpsert(skill: Skill, newDetails: String): Unit {
        emit(Skill(skill.id, skill.title, newDetails, skill.functions,
                   version: skill.version + 1))
    }

    private static func emit(skill: Skill): Unit {
        let box = SinkBox()
        synchronized(sinkMutex){
            box.value = sink
        }
        match(box.value){
            case Some(fn) => fn(skill)
            case None => ()
        }
    }

    private static func usageOf(items: ArrayList<ExperienceItem>): String {
        var text = ''
        for(item in items){
            text += '- ${item.content}\n'
        }
        text
    }
}

class TimeBox {
    public var value: Int64 = 0
}

class FlagBox {
    public var value: Bool = true
}

class SinkBox {
    public var value: ?(Skill) -> Unit = None
}
