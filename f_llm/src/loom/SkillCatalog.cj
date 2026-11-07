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
import std.math.*
import std.sync.*

import fountain::f_llm.embedding.*
import fountain::f_llm.store.*

/** 命中的技能：标题 + 正文 + 相关度 */
public class SkillEntry {
    public let title: String
    public let details: String
    public let score: Float64

    public init(title: String, details: String, score: Float64) {
        this.title = title
        this.details = details
        this.score = score
    }
}

/**
 * 技能目录：按任务描述挑出应该加载的技能。
 *
 * 两种检索方式：
 * - **向量**：装了 embedder 时，把 `标题 + 正文` 编码后做余弦相似度（向量按 `标题#版本` 缓存）；
 * - **关键词**：没装 embedder（或编码失败）时，退回词面包含度——保证任何环境都能用。
 *
 * 目录本身不持久化：技能数量在几十级，每次从 `SkillStore.list()` 现取现算足够。
 */
public class SkillCatalog {
    private static let mutex = Mutex()
    private static var storeFactory: ?() -> SkillStore = None
    private static var embedder: ?(String) -> Array<Float64> = None
    private static var vectors = HashMap<String, Array<Float64>>()
    /** 编码失败计数：query 侧 / 技能侧（静默降级要能被看见） */
    private static var queryEmbedFailures: Int64 = 0
    private static var skillEmbedFailures: Int64 = 0

    private init() {
    }

    /** @param factory 惰性取技能库（装配期容器可能还没 bootstrap） */
    public static func install(factory: () -> SkillStore,
                               embedder!: ?(String) -> Array<Float64> = None): Unit {
        synchronized(mutex){
            storeFactory = factory
            SkillCatalog.embedder = embedder
            vectors = HashMap<String, Array<Float64>>()
        }
    }

    public static func reset(): Unit {
        synchronized(mutex){
            storeFactory = None
            embedder = None
            vectors = HashMap<String, Array<Float64>>()
            queryEmbedFailures = 0
            skillEmbedFailures = 0
        }
    }

    /**
     * 自上次 `reset()` 以来，向量化失败的次数。
     *
     * 向量失败会**静默退回关键词**（可用性优先），但这会让「装了编码器却在跑关键词」
     * 这种配置错误完全看不出来——评测与排障时需要这个计数来判断到底走了哪条路。
     */
    public static func embedFailures(): Int64 {
        let box = FailureBox()
        synchronized(mutex){
            box.query = queryEmbedFailures
            box.skill = skillEmbedFailures
        }
        box.query + box.skill
    }

    /** 编码失败计数明细：query 侧、技能侧 */
    public static func embedFailureDetail(): (Int64, Int64) {
        let box = FailureBox()
        synchronized(mutex){
            box.query = queryEmbedFailures
            box.skill = skillEmbedFailures
        }
        (box.query, box.skill)
    }

    private static func noteQueryFailure(): Unit {
        synchronized(mutex){
            queryEmbedFailures++
        }
    }

    private static func noteSkillFailure(): Unit {
        synchronized(mutex){
            skillEmbedFailures++
        }
    }

    /**
     * 用 f_llm 的 Embedding（BGE-M3 等）构造编码器，直接传给 `install(embedder: …)`
     * 或 `LoomWiring.wire(skillEmbedder: …)`。
     */
    public static func embeddingEncoder(llmName: String): (String) -> Array<Float64> {
        { text => Embedding.embed(llmName, EmbeddingParam(agentId: 0, session: '', input: text)).embedding }
    }

    /** 当前是否走向量检索（装了 embedder 才算） */
    public static func isVectorized(): Bool {
        let box = SkillFlagBox()
        synchronized(mutex){
            box.value = match(embedder){
                case Some(_) => true
                case None => false
            }
        }
        box.value
    }

    /**
     * @param query 任务描述（通常是流程的起始输入或计划备注）
     * @param topK 最多返回几条
     * @param minScore 低于该分数不返回（向量模式下是余弦相似度，关键词模式下是命中率）
     */
    public static func search(query: String, topK!: Int64 = 3,
                              minScore!: Float64 = 0.0): ArrayList<SkillEntry> {
        let result = ArrayList<SkillEntry>()
        let text = query.trimAscii()
        if(text.isEmpty()){
            return result
        }
        let skills = skillsOf()
        if(skills.isEmpty()){
            return result
        }

        let encoder = currentEmbedder()
        var scored = ArrayList<SkillEntry>()
        match(encoder){
            case Some(encode) =>
                let queryVector = tryEncode(encode, text)
                match(queryVector){
                    case Some(queryVec) =>
                        for(skill in skills){
                            match(vectorOf(encode, skill)){
                                case Some(vector) =>
                                    scored.add(SkillEntry(skill.title, skill.details,
                                        cosine(queryVec, vector)))
                                case None => noteSkillFailure()
                            }
                        }
                    case None =>
                        // 编码失败：整体退回关键词，避免一次网络故障就让技能不可用
                        noteQueryFailure()
                        scored = keywordScore(skills, text)
                }
            case None => scored = keywordScore(skills, text)
        }

        sortDesc(scored)
        for(item in scored){
            if(Int64(result.size) >= topK){
                break
            }
            if(item.score >= minScore && item.score > 0.0){
                result.add(item)
            }
        }
        result
    }

    private static func skillsOf(): ArrayList<Skill> {
        let factory = currentFactory()
        match(factory){
            case Some(make) =>
                try{
                    make().list()
                }catch(error: Exception){
                    ArrayList<Skill>()
                }
            case None => ArrayList<Skill>()
        }
    }

    private static func currentFactory(): ?() -> SkillStore {
        let box = FactoryBox()
        synchronized(mutex){
            box.value = storeFactory
        }
        box.value
    }

    private static func currentEmbedder(): ?(String) -> Array<Float64> {
        let box = EmbedderBox()
        synchronized(mutex){
            box.value = embedder
        }
        box.value
    }

    private static func tryEncode(encode: (String) -> Array<Float64>,
                                  text: String): ?Array<Float64> {
        try{
            let vector = encode(text)
            if(vector.isEmpty()){
                return None
            }
            Some(vector)
        }catch(error: Exception){
            None
        }
    }

    /** 技能向量按 `标题#版本` 缓存：正文变了（版本变了）自然失效 */
    private static func vectorOf(encode: (String) -> Array<Float64>,
                                 skill: Skill): ?Array<Float64> {
        let key = '${skill.title}#${skill.version}'
        let cached = readVector(key)
        match(cached){
            case Some(vector) => return Some(vector)
            case None => ()
        }
        let vector = tryEncode(encode, '${skill.title}\n${skill.details}')
        match(vector){
            case Some(value) =>
                writeVector(key, value)
                Some(value)
            case None => None
        }
    }

    private static func readVector(key: String): ?Array<Float64> {
        let box = VectorBox()
        synchronized(mutex){
            box.value = vectors.get(key)
        }
        box.value
    }

    private static func writeVector(key: String, value: Array<Float64>): Unit {
        synchronized(mutex){
            vectors[key] = value
        }
    }

    private static func keywordScore(skills: ArrayList<Skill>, query: String): ArrayList<SkillEntry> {
        let result = ArrayList<SkillEntry>()
        let needle = query.toAsciiLower()
        for(skill in skills){
            let haystack = '${skill.title} ${skill.details}'.toAsciiLower()
            var score = 0.0f64
            if(haystack.contains(needle)){
                score = 1.0f64
            }else{
                let tokens = needle.split(' ')
                var hits: Int64 = 0
                var total: Int64 = 0
                for(token in tokens){
                    let word = token.trimAscii()
                    if(word.isEmpty()){
                        continue
                    }
                    total++
                    if(haystack.contains(word)){
                        hits++
                    }
                }
                if(total > 0){
                    score = Float64(hits) / Float64(total)
                }
                // 中文没有空格：先看查询有多少字落在技能里（虚词太多，阈值要高）
                let byRune = runeScore(haystack, needle)
                if(byRune >= 0.5f64 && byRune > score){
                    score = byRune
                }
                // 再看技能标题有多少字被任务描述覆盖——「帮我写日报」命中「日报助手」靠这条
                let byTitle = runeScore(needle, skill.title.toAsciiLower())
                if(byTitle >= 0.5f64 && byTitle > score){
                    score = byTitle
                }
            }
            if(score > 0.0f64){
                result.add(SkillEntry(skill.title, skill.details, score))
            }
        }
        result
    }

    /** 按字符命中比例打分：用于没有空格的中文查询 */
    private static func runeScore(haystack: String, query: String): Float64 {
        var total: Int64 = 0
        var hits: Int64 = 0
        let seen = HashSet<Rune>()
        for(rune in query.runes()){
            if(seen.contains(rune)){
                continue
            }
            seen.add(rune)
            total++
            if(haystack.contains(rune.toString())){
                hits++
            }
        }
        if(total == 0){
            return 0.0f64
        }
        Float64(hits) / Float64(total)
    }

    private static func cosine(left: Array<Float64>, right: Array<Float64>): Float64 {
        let size = if(left.size < right.size){ left.size }else{ right.size }
        if(size == 0){
            return 0.0f64
        }
        var dot = 0.0f64
        var leftNorm = 0.0f64
        var rightNorm = 0.0f64
        for(index in 0..size){
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }
        if(leftNorm <= 0.0f64 || rightNorm <= 0.0f64){
            return 0.0f64
        }
        dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    private static func sortDesc(items: ArrayList<SkillEntry>): Unit {
        for(index in 1..items.size){
            let current = items[index]
            var position = index - 1
            while(position >= 0 && items[position].score < current.score){
                items[position + 1] = items[position]
                position--
            }
            items[position + 1] = current
        }
    }
}

class FactoryBox {
    public var value: ?() -> SkillStore = None
}

class EmbedderBox {
    public var value: ?(String) -> Array<Float64> = None
}

class FailureBox {
    public var query: Int64 = 0
    public var skill: Int64 = 0
}

class VectorBox {
    public var value: ?Array<Float64> = None
}

class SkillFlagBox {
    public var value: Bool = false
}
