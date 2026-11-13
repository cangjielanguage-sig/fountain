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
package fountain::f_llm.store

import std.collection.*
import std.convert.*
import std.sync.*

import fountain::f_store.Store

/** 单个技能的演进进度 */
public class EvolutionSkillState {
    public let skillTitle: String
    /** 上次尝试演进的时间戳（秒）；0 表示从未演进 */
    public let lastEvolvedAt: Int64
    /** 上次是否通过 A/B 门禁（决定冷却期用长档还是短档） */
    public let lastGatePassed: Bool

    public init(skillTitle: String, lastEvolvedAt: Int64, lastGatePassed: Bool) {
        this.skillTitle = skillTitle
        this.lastEvolvedAt = lastEvolvedAt
        this.lastGatePassed = lastGatePassed
    }
}

/**
 * 技能演进的状态存储：每个技能的冷却期依据 + 整轮执行的水位线。
 *
 * 水位线（`lastRunAt`）决定「这次只处理上次之后新增的记忆/经验/知识」，
 * 避免每轮都把全量历史重新归组、重复演进。
 */
public interface EvolutionStateStore {
    /** 建表等一次性准备；`f_store` 与内存实现为空 */
    func ensureSchema(): Unit {
        ()
    }

    func get(skillTitle: String): ?EvolutionSkillState

    func save(state: EvolutionSkillState): Unit

    /** 上次整轮执行的时间戳（秒）；0 表示从未执行 */
    func lastRunAt(): Int64

    /** 记录本轮执行时间，下一轮据此筛新增素材 */
    func markRun(at: Int64): Unit

    /**
     * 已参与过聚类的知识 docId（**全量**）。
     *
     * 只用于运维/调试查看。判断某个候选是否消费过请用 [processedAmong]：
     * 全量读取在记录数超过实现内部上限时会截断，导致老记录被误判成「没消费过」。
     */
    func processedKnowledge(): Array<String> {
        Array<String>()
    }

    /** 标记这些知识已被消费 */
    func markKnowledge(docIds: Array<String>): Unit {
        ()
    }

    /**
     * 这些 docId 里哪些已被消费过。
     *
     * 语义是**成员判定**而不是「取全部已消费集合」：判定的规模只与本次候选数量有关，
     * 与历史累积量无关。默认实现退化成拉全量再比对，实现方应覆盖成按主键点查 / `IN` 查询。
     */
    func processedAmong(docIds: Array<String>): HashMap<String, Bool> {
        let known = HashMap<String, Bool>()
        for(docId in processedKnowledge()){
            known[docId] = true
        }
        let consumed = HashMap<String, Bool>()
        for(docId in docIds){
            if(known.contains(docId)){
                consumed[docId] = true
            }
        }
        consumed
    }
}

/** 内存实现：测试与零配置启动 */
public class InMemoryEvolutionStateStore <: EvolutionStateStore {
    private let mutex = Mutex()
    private var states = HashMap<String, EvolutionSkillState>()
    private var runAt: Int64 = 0
    private var knowledge = HashSet<String>()

    public init() {
    }

    public func processedKnowledge(): Array<String> {
        let box = KnowledgeBox()
        synchronized(mutex){
            let list = ArrayList<String>()
            for(docId in knowledge){
                list.add(docId)
            }
            box.value = list.toArray()
        }
        box.value
    }

    public func markKnowledge(docIds: Array<String>): Unit {
        synchronized(mutex){
            for(docId in docIds){
                if(!docId.isEmpty()){
                    knowledge.add(docId)
                }
            }
        }
    }

    public func processedAmong(docIds: Array<String>): HashMap<String, Bool> {
        let box = KnowledgeSetBox()
        synchronized(mutex){
            let consumed = HashMap<String, Bool>()
            for(docId in docIds){
                if(knowledge.contains(docId)){
                    consumed[docId] = true
                }
            }
            box.value = consumed
        }
        box.value
    }

    public func get(skillTitle: String): ?EvolutionSkillState {
        let box = StateBox()
        synchronized(mutex){
            box.value = states.get(skillTitle)
        }
        box.value
    }

    public func save(state: EvolutionSkillState): Unit {
        synchronized(mutex){
            states[state.skillTitle] = state
        }
    }

    public func lastRunAt(): Int64 {
        let box = StampBox()
        synchronized(mutex){
            box.value = runAt
        }
        box.value
    }

    public func markRun(at: Int64): Unit {
        synchronized(mutex){
            runAt = at
        }
    }
}

/**
 * f_store 实现（元数据族，与 `FStoreLoomStore` 共用 `llm_metaStorePath`）。
 *
 * 键布局：
 *
 * ```
 * f_llm:evo-state:run            → 整轮水位线（epoch 秒）
 * f_llm:evo-state:skill:{title}  → at \u0001 passed(0/1)
 * ```
 */
public class FStoreEvolutionStateStore <: EvolutionStateStore {
    private static const RUN_KEY = 'f_llm:evo-state:run'
    private static const SKILL_PREFIX = 'f_llm:evo-state:skill:'
    /** 已消费的知识 docId：`f_llm:evo-state:kn:{docId}` = 1 */
    private static const KNOWLEDGE_PREFIX = 'f_llm:evo-state:kn:'
    private static let SEP = String.fromUtf8([1u8])

    private let store: Store
    private let mutex = Mutex()

    public init(path: String) {
        this.store = Store(path)
    }

    /** 容器用：路径取 `llm_metaStorePath` */
    public init() {
        this.store = Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))
    }

    public func get(skillTitle: String): ?EvolutionSkillState {
        let box = StateBox()
        synchronized(mutex){
            box.value = readState(skillTitle)
        }
        box.value
    }

    public func save(state: EvolutionSkillState): Unit {
        synchronized(mutex){
            let passed = if(state.lastGatePassed){ '1' }else{ '0' }
            let text = '${state.lastEvolvedAt}${SEP}${passed}'
            store.add('${SKILL_PREFIX}${state.skillTitle}'.toArray(), text.toArray())
        }
    }

    public func lastRunAt(): Int64 {
        let box = StampBox()
        synchronized(mutex){
            box.value = readRun()
        }
        box.value
    }

    public func markRun(at: Int64): Unit {
        synchronized(mutex){
            store.add(RUN_KEY.toArray(), at.toString().toArray())
        }
    }

    public func processedKnowledge(): Array<String> {
        let box = KnowledgeBox()
        synchronized(mutex){
            let list = ArrayList<String>()
            for((key, _) in store.prefix(KNOWLEDGE_PREFIX.toArray())){
                let text = String.fromUtf8(key)
                if(text.size > KNOWLEDGE_PREFIX.size){
                    list.add(text[KNOWLEDGE_PREFIX.size..])
                }
            }
            box.value = list.toArray()
        }
        box.value
    }

    public func markKnowledge(docIds: Array<String>): Unit {
        synchronized(mutex){
            for(docId in docIds){
                if(!docId.isEmpty()){
                    store.add('${KNOWLEDGE_PREFIX}${docId}'.toArray(), [1u8])
                }
            }
        }
    }

    /** 按主键点查：每个候选一次 `get`，与历史累积量无关 */
    public func processedAmong(docIds: Array<String>): HashMap<String, Bool> {
        let box = KnowledgeSetBox()
        synchronized(mutex){
            let consumed = HashMap<String, Bool>()
            for(docId in docIds){
                if(docId.isEmpty()){
                    continue
                }
                match(store.get('${KNOWLEDGE_PREFIX}${docId}'.toArray())){
                    case Some(_) => consumed[docId] = true
                    case None => ()
                }
            }
            box.value = consumed
        }
        box.value
    }

    private func readState(skillTitle: String): ?EvolutionSkillState {
        match(store.get('${SKILL_PREFIX}${skillTitle}'.toArray())){
            case Some(bytes) =>
                let parts = String.fromUtf8(bytes).split(SEP)
                if(parts.size < 2){
                    return None
                }
                let at = Int64.tryParse(parts[0]) ?? 0
                Some(EvolutionSkillState(skillTitle, at, parts[1] == '1'))
            case None => None
        }
    }

    private func readRun(): Int64 {
        match(store.get(RUN_KEY.toArray())){
            case Some(bytes) => Int64.tryParse(String.fromUtf8(bytes)) ?? 0
            case None => 0
        }
    }
}

class StateBox {
    public var value: ?EvolutionSkillState = None
}

class StampBox {
    public var value: Int64 = 0
}

class KnowledgeBox {
    public var value: Array<String> = Array<String>()
}

class KnowledgeSetBox {
    public var value: HashMap<String, Bool> = HashMap<String, Bool>()
}
