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

import fountain::f_llm.store.*

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
    public let candidateClusters: Int64

    public init(evolved: ArrayList<String>, rejected: ArrayList<String>,
                skipped: ArrayList<String>, candidateClusters: Int64) {
        this.evolved = evolved
        this.rejected = rejected
        this.skipped = skipped
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
                           failures: HashMap<String, Int64>,
                           chat: (String, String) -> String,
                           state: SkillEvolutionState,
                           policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(),
                           embedder!: ?(String) -> Array<Float64> = None,
                           matcherThreshold!: Float64 = 0.75,
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

        for(skill in skills){
            let items = owner.get(skill.title) ?? ArrayList<ExperienceItem>()
            let failureCount = failures.get(skill.title) ?? 0
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

        SkillEvolutionReport(evolved, rejected, skipped,
            Int64(matched.candidates.size))
    }

    /**
     * 注册成定时任务：到点跑一轮（判定 → 提炼 → 门禁 → 落库）。
     *
     * 依赖的输入都用闭包传入，因为技能库、经验库、当前时间是运行期才确定的。
     */
    public static func schedule(name: String, cron: String, scheduler: LoomScheduler,
                                skills: () -> ArrayList<Skill>,
                                successes: () -> ArrayList<ExperienceItem>,
                                failures: () -> HashMap<String, Int64>,
                                chat: (String, String) -> String,
                                state: SkillEvolutionState,
                                policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(),
                                embedder!: ?(String) -> Array<Float64> = None,
                                clock!: () -> Int64 = { => 0 }): Unit {
        scheduler.schedule(name, cron, { =>
            try{
                run(skills(), successes(), failures(), chat, state,
                    policy: policy, embedder: embedder, now: clock())
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
        let next = Skill(skill.id, skill.title, newDetails, skill.functions,
                         version: skill.version + 1)
        let box = SinkBox()
        synchronized(sinkMutex){
            box.value = sink
        }
        match(box.value){
            case Some(fn) => fn(next)
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
