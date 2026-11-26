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

/** 一轮演进需要的素材：成功经验、失败经验、知识摘要 */
public class EvolutionInput {
    public let successes: ArrayList<ExperienceItem>
    public let failures: ArrayList<ExperienceItem>
    public let knowledge: ArrayList<ExperienceItem>

    public init(successes: ArrayList<ExperienceItem>, failures: ArrayList<ExperienceItem>,
        knowledge!: ArrayList<ExperienceItem> = ArrayList<ExperienceItem>()) {
        this.successes = successes
        this.failures = failures
        this.knowledge = knowledge
    }
}

public class SkillEvolutionReport {
    public let evolved: ArrayList<String>
    public let rejected: ArrayList<String>
    public let skipped: ArrayList<String>
    /** 本轮新建的技能标题（`nameCandidates: true` 时才会出现） */
    public let created: ArrayList<String>
    public let candidateClusters: Int64
    /** 本次进入归组的素材条数（水位线之后的新增） */
    public let materials: Int64

    public init(evolved: ArrayList<String>, rejected: ArrayList<String>, skipped: ArrayList<String>,
        created: ArrayList<String>, candidateClusters: Int64, materials!: Int64 = 0) {
        this.evolved = evolved
        this.rejected = rejected
        this.skipped = skipped
        this.created = created
        this.candidateClusters = candidateClusters
        this.materials = materials
    }
}

/**
 * 技能演进流水线：**只由这里统一执行**，流程结束的提炼只写记忆/经验/知识，不碰技能。
 *
 * 每轮做两件事，顺序不能反：
 * 1. **先演进已有技能**：把「上次执行之后新增」的成功经验与知识归到现有技能，够样本就改正文；
 * 2. **再提炼新技能**：归不上的素材聚成簇，够大就起名建档。
 *
 * 先演进再新建，是为了让「本可以并入现有技能」的素材优先被吸收，避免同一主题
 * 既改旧技能又建新技能，形成两份近似内容。
 */
public class SkillEvolutionJob {
    private init() {
    }

    /**
     * @param successes 成功经验（`kind=experience`）
     * @param failures 失败经验（`kind=experience_failed`），只用于成功率判定
     * @param knowledge 知识摘要，与成功经验一起参与归组/聚类
     * @param state 每技能冷却期状态 + 整轮水位线
     * @param since 水位线：只处理 `at > since` 的素材；0 表示全量
     */
    public static func run(skills: ArrayList<Skill>, successes: ArrayList<ExperienceItem>,
        failures: ArrayList<ExperienceItem>, knowledge: ArrayList<ExperienceItem>, chat: (String, String) -> String,
        state: EvolutionStateStore, policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(),
        embedder!: ?(String) -> Array<Float64> = None, matcherThreshold!: Float64 = 0.75, nameCandidates!: Bool = false,
        ledger!: ?EvolutionStore = None, since!: Int64 = 0, now!: Int64 = 0): SkillEvolutionReport {
        let evolved = ArrayList<String>()
        let rejected = ArrayList<String>()
        let skipped = ArrayList<String>()

        // 只处理水位线之后的素材；`at == 0` 表示时间未知（知识文档没有写入时间），始终参与
        let freshSuccess = fresh(successes, since)
        let freshFailure = fresh(failures, since)
        // 知识再按「已消费 docId」过滤：否则同一批知识会被每轮重复聚类、重复提案新技能。
        // 只对本轮候选做成员判定——查询规模与历史累积量无关，不存在「读不到更早记录」的截断
        let candidates = fresh(knowledge, since)
        let docIds = ArrayList<String>()
        for (item in candidates) {
            if (!item.source.isEmpty()) {
                docIds.add(item.source)
            }
        }
        let consumed = state.processedAmong(docIds.toArray())
        let freshKnowledge = ArrayList<ExperienceItem>()
        for (item in candidates) {
            if (item.source.isEmpty() || !consumed.contains(item.source)) {
                freshKnowledge.add(item)
            }
        }

        // 素材池 = 成功经验 + 知识：知识不参与成功率，但可以成为演进依据与新技能来源
        let materials = ArrayList<ExperienceItem>()
        for (item in freshSuccess) {
            materials.add(item)
        }
        for (item in freshKnowledge) {
            materials.add(item)
        }

        let matched = SkillMatcher.assign(materials, skills, embedder: embedder, threshold: matcherThreshold)
        let owner = HashMap<String, ArrayList<ExperienceItem>>()
        for (item in matched.assignments) {
            owner[item.skillTitle] = item.experiences
        }

        // 失败经验同样按技能归属后计数：成功率要按「这个技能的历史表现」算，
        // 不能拿全局成败冒充——不同技能的难度差很多
        let failed = SkillMatcher.assign(freshFailure, skills, embedder: embedder, threshold: matcherThreshold)
        let failureCounts = HashMap<String, Int64>()
        for (item in failed.assignments) {
            failureCounts[item.skillTitle] = Int64(item.experiences.size)
        }

        for (skill in skills) {
            let items = owner.get(skill.title) ?? ArrayList<ExperienceItem>()
            let failureCount = failureCounts.get(skill.title) ?? 0
            let previous = state.get(skill.title)
            let lastAt = match (previous) {
                case Some(record) => record.lastEvolvedAt
                case None => 0
            }
            let lastPassed = match (previous) {
                case Some(record) => record.lastGatePassed
                case None => true
            }
            let decision = policy.decide(Int64(items.size), failureCount, lastAt, lastPassed, now)
            if (!decision.shouldEvolve) {
                skipped.add('${skill.title}: ${decision.reason}')
                continue
            }

            let usage = usageOf(items)
            let prompt = '现有技能正文：\n${skill.details}\n\n近期使用情况：\n${usage}\n\n'
                + '把使用情况里可复用的经验合并进正文，输出新的正文，不要输出解释。'
            let newDetails = try {
                chat('', prompt)
            } catch (error: Exception) {
                ''
            }
            if (newDetails.trimAscii().isEmpty()) {
                rejected.add('${skill.title}: evolution returned empty content')
                state.save(EvolutionSkillState(skill.title, now, false))
                continue
            }

            let samples = SkillSamples.of(skill)
            let gate = SkillGate.evaluate(chat, skill.details, newDetails, samples)
            if (!gate.passed) {
                rejected.add('${skill.title}: ${gate.reason}')
                state.save(EvolutionSkillState(skill.title, now, false))
                continue
            }
            skillStoreUpsert(skill, newDetails.trimAscii())
            evolved.add('${skill.title}: v${skill.version} -> v${skill.version + 1} (${gate.reason})')
            state.save(EvolutionSkillState(skill.title, now, true))
        }

        // 新技能候选：只有显式开启 nameCandidates 才让模型起名并落库
        let created = ArrayList<String>()
        if (nameCandidates && !matched.candidates.isEmpty()) {
            var nextId: Int64 = 1
            for (skill in skills) {
                if (skill.id >= nextId) {
                    nextId = skill.id + 1
                }
            }
            for (candidate in matched.candidates) {
                match (SkillNamer.propose(chat, candidate.experiences)) {
                    case Some(draft) =>
                        // 把样例写进 functions，下一轮它才有 A/B 基线可用
                        emit(Skill(nextId, draft.title, draft.details, samplesJson(draft.samples), version: 1))
                        created.add('${draft.title} (id=${nextId})')
                        nextId++
                    case None => rejected.add('candidate cluster: model did not return a valid name')
                }
            }
        }

        // 标记本轮消费过的知识：下一轮它们不再进入素材池
        let usedKnowledge = ArrayList<String>()
        for (item in freshKnowledge) {
            if (!item.source.isEmpty()) {
                usedKnowledge.add(item.source)
            }
        }
        state.markKnowledge(usedKnowledge.toArray())

        let report = SkillEvolutionReport(evolved, rejected, skipped, created, Int64(matched.candidates.size),
            materials: Int64(materials.size))
        // 报告留档：传了报告表才写，写失败不影响本轮结果
        if (let Some(target) <- ledger) {
            try {
                SkillEvolutionLedger.write(target, report, now)
            } catch (error: Exception) {
                ()
            }
        }
        // 推进水位线：到「本轮真正处理过的最大 at」，而不是 now。
        // 素材总量超过单轮取数上限（`load` 的 limit）时，多出来的部分 at 更大；
        // 若把水位直接推到 now，它们下一轮就落在 since 之前，会被永久跳过。
        var advanced = 0
        for (item in freshSuccess) {
            if (item.at > advanced) {
                advanced = item.at
            }
        }
        for (item in freshFailure) {
            if (item.at > advanced) {
                advanced = item.at
            }
        }
        for (item in freshKnowledge) {
            if (item.at > advanced) {
                advanced = item.at
            }
        }
        if (advanced > 0) {
            // 只前进不后退：并发/乱序素材不会把水位拉回去
            if (advanced > state.lastRunAt()) {
                state.markRun(advanced)
            }
        } else if (now > 0) {
            // 没有任何带时间戳的素材（例如只有知识文档）：沿用「按轮次推进」
            state.markRun(now)
        }
        report
    }

    /** `since <= 0` 表示全量；`at == 0` 视为时间未知，始终保留 */
    private static func fresh(items: ArrayList<ExperienceItem>, since: Int64): ArrayList<ExperienceItem> {
        if (since <= 0) {
            return items
        }
        let result = ArrayList<ExperienceItem>()
        for (item in items) {
            if (item.at == 0 || item.at > since) {
                result.add(item)
            }
        }
        result
    }

    /**
     * 从存储里取本轮素材：成功经验、失败经验、知识摘要。
     *
     * 经验写入时不绑定技能，所以按 `kind` 取；知识没有写入时间（`at = 0`），
     * 因此每轮都会参与归组——这也是新技能的主要来源。
     */
    public static func load(gateway: LoomStoreGateway, userId: Int64, namespace: String, limit!: Int64 = 500): EvolutionInput {
        EvolutionInput(experiencesOf(gateway, userId, namespace, 'experience', limit),
            experiencesOf(gateway, userId, namespace, 'experience_failed', limit),
            knowledge: knowledgeOf(gateway, limit, userId, namespace))
    }

    private static func experiencesOf(gateway: LoomStoreGateway, userId: Int64, namespace: String, kind: String,
        limit: Int64): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        let payload = '{\"userId\":${userId},'
            + '\"namespace\":${FlowPlan.jsonQuote(namespace)},'
            + '\"kind\":${FlowPlan.jsonQuote(kind)},'
            + '\"offset\":0,\"limit\":${limit}}'
        let text = try {
            gateway.call('memory', 'list', payload)
        } catch (error: Exception) {
            '[]'
        }
        let json = match (JsonValue.fromStr(text) as JsonArray) {
            case Some(value) => value
            case None => return result
        }
        for (item in json) {
            match (item as JsonObject) {
                case Some(record) =>
                    let id = intField(record, 'id')
                    let content = strField(record, 'content')
                    if (!content.isEmpty()) {
                        // 网关已暴露 saveTime；缺失（旧数据/别的网关实现）时退化为 id
                        let saveTime = intField(record, 'saveTime')
                        result.add(ExperienceItem(id, content, at: if (saveTime > 0) {
                            saveTime
                        } else {
                            id
                        }))
                    }
                case None => ()
            }
        }
        result
    }

    /**
     * 知识文档是否属于该租户：`docId` 由提炼侧写成
     * `loom:<userId>:<namespace>:<flow>:<stamp>-<seq>`，据此过滤，避免跨租户串味。
     *
     * 旧格式（`loom:<flow>:<seq>`）无法判定归属，一律不取——宁可少取，不可串味。
     */
    public static func ownedBy(docId: String, userId: Int64, namespace: String): Bool {
        docId.startsWith('loom:${userId}:${namespace}:')
    }

    private static func knowledgeOf(gateway: LoomStoreGateway, limit: Int64, userId: Int64, namespace: String): ArrayList<ExperienceItem> {
        let result = ArrayList<ExperienceItem>()
        let ids = try {
            gateway.call('knowledge', 'docIds', '{\"offset\":0,\"limit\":${limit}}')
        } catch (error: Exception) {
            '[]'
        }
        let list = match (JsonValue.fromStr(ids) as JsonArray) {
            case Some(value) => value
            case None => return result
        }
        var index: Int64 = 0
        for (item in list) {
            match (item as JsonString) {
                case Some(docId) =>
                    // 只吃本租户写进来的知识：docId 形如 loom:<userId>:<namespace>:<flow>:<stamp>-<seq>
                    if (!ownedBy(docId.value, userId, namespace)) {
                        continue
                    }
                    let text = try {
                        gateway.call('knowledge', 'get', '{\"docId\":${FlowPlan.jsonQuote(docId.value)}}')
                    } catch (error: Exception) {
                        ''
                    }
                    if (!text.trimAscii().isEmpty()) {
                        match (JsonValue.fromStr(text) as JsonObject) {
                            case Some(doc) =>
                                let content = strField(doc, 'content')
                                if (!content.isEmpty()) {
                                    index++
                                    // source = docId：用于「已消费就不重复聚类」
                                    result.add(ExperienceItem(index, content, at: 0, source: docId.value))
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
        }
        result
    }

    private static func intField(json: JsonObject, key: String): Int64 {
        match (json.get(key)) {
            case Some(value) => Int64.tryParse(value.toString()) ?? 0
            case None => 0
        }
    }

    private static func strField(json: JsonObject, key: String): String {
        match (json.get(key)) {
            case Some(value) => match (value as JsonString) {
                case Some(text) => text.value
                case None => ''
            }
            case None => ''
        }
    }

    /**
     * 注册成定时任务：到点跑一轮（演进已有技能 → 提炼新技能）。
     *
     * 水位线从 `state.lastRunAt()` 取，因此重启后不会把历史素材重跑一遍。
     */
    public static func schedule(name: String, cron: String, scheduler: LoomScheduler, skills: () -> ArrayList<Skill>,
        input: () -> EvolutionInput, chat: (String, String) -> String, state: EvolutionStateStore,
        policy!: SkillEvolutionPolicy = SkillEvolutionPolicy(), embedder!: ?(String) -> Array<Float64> = None,
        nameCandidates!: Bool = false, ledger!: ?EvolutionStore = None, lease!: ?EvolutionLease = None,
        clock!: () -> Int64 = {=> 0}): Unit {
        scheduler.schedule(name, cron, {
            => try {
                let now = clock()
                // 每日租约：只有抢到今天的进程才执行，其余进程直接放弃
                let allowed = match (lease) {
                    case Some(value) => !value.acquire(now).isEmpty()
                    case None => true
                }
                if (allowed) {
                    let materials = input()
                    let _ = run(skills(), materials.successes, materials.failures, materials.knowledge, chat, state,
                        policy: policy, embedder: embedder, nameCandidates: nameCandidates, ledger: ledger,
                        since: state.lastRunAt(), now: now)
                }
            } catch (error: Exception) {
                // 定时线程不能把异常抛出去，否则会中断后续调度
                ()
            }
        })
    }

    /** 落库入口单独抽出来，测试可以替换成不落库的桩 */
    private static var sink: ?(Skill) -> Unit = None

    public static func installSink(fn: (Skill) -> Unit): Unit {
        synchronized(sinkMutex) {
            sink = Some(fn)
        }
    }

    public static func resetSink(): Unit {
        synchronized(sinkMutex) {
            sink = None
        }
    }

    private static let sinkMutex = Mutex()

    private static func skillStoreUpsert(skill: Skill, newDetails: String): Unit {
        emit(Skill(skill.id, skill.title, newDetails, skill.functions, version: skill.version + 1))
    }

    private static func emit(skill: Skill): Unit {
        let box = SinkBox()
        synchronized(sinkMutex) {
            box.value = sink
        }
        match (box.value) {
            case Some(fn) => fn(skill)
            case None => ()
        }
    }

    /** 新技能的 functions 里塞样例，供下一轮 A/B 用 */
    private static func samplesJson(samples: ArrayList<SkillSample>): String {
        var text = '{"samples":['
        var first = true
        for (sample in samples) {
            if (!first) {
                text += ','
            }
            first = false
            text += '{\"input\":${FlowPlan.jsonQuote(sample.input)},'
            text += '\"expect\":${FlowPlan.jsonQuote(sample.expect)}}'
        }
        text + ']}'
    }

    private static func usageOf(items: ArrayList<ExperienceItem>): String {
        var text = ''
        for (item in items) {
            text += '- ${item.content}\n'
        }
        text
    }
}

class SinkBox {
    public var value: ?(Skill) -> Unit = None
}
