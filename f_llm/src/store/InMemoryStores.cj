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
import std.time.DateTime

import fountain::f_bean.*
import fountain::f_bean.macros.*

/**
 * 内存实现：只用于单测与本地演示，**不注册进 Stores**（§5.3）。
 *
 * 检索是「包含匹配」，不代表真实向量检索；生产实现由 PG/MySQL/fhydra 提供。
 */
public class InMemoryContentStore <: ContentStore {
    private let memoryStore = InMemoryMemoryStore()

    public prop memory: MemoryStore {
        get() { memoryStore }
    }
    private var cachedKnowledge: ?KnowledgeStore = None

    /** 有 `Embedder` bean 时启用语义检索，否则退化为词面 */
    public prop knowledge: KnowledgeStore {
        get() {
            match(cachedKnowledge){
                case Some(store) => store
                case None =>
                    let store = match(lookupOption<Embedder>()){
                        case Some(model) => InMemoryKnowledgeStore(model)
                        case None => InMemoryKnowledgeStore()
                    }
                    cachedKnowledge = Some(store)
                    store
            }
        }
    }
}

public class InMemoryMetaStore <: MetaStore {
    private let characterStore = InMemoryCharacterStore()
    private let skillStore = InMemorySkillStore()
    private let promptStore = InMemoryPromptStore()
    private let confStore = InMemoryLLMConfStore()

    public prop characters: CharacterStore {
        get() { characterStore }
    }
    public prop skills: SkillStore {
        get() { skillStore }
    }
    public prop prompts: PromptStore {
        get() { promptStore }
    }
    public prop confs: LLMConfStore {
        get() { confStore }
    }
}

@Bean
@BeanMeta[condition: ConfCond.Value('llm_memoryStore', StringCond.Exactly('inMemory'))]
public class InMemoryMemoryStore <: MemoryStore {
    private let records = HashMap<Int64, MemoryRecord>()
    private var seq: Int64 = 0

    public func add(write: MemoryWrite): MemoryRecord {
        seq++
        let record = MemoryRecord(seq, write.userId, write.namespace, write.title,
                                  write.content, write.kind, DateTime.now())
        records[record.id] = record
        record
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        match(records.get(id)){
            case Some(record) => if(record.userId == userId) { Some(record) } else { None }
            case None => None
        }
    }

    public func remove(userId: Int64, id: Int64): Bool {
        match(records.get(id)){
            case Some(record) =>
                if(record.userId == userId){
                    records.remove(id)
                    true
                }else{
                    false
                }
            case None => false
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let matched = ArrayList<MemoryRecord>()
        for((_, record) in records){
            if(record.userId == userId && record.namespace == namespace){
                matched.add(record)
            }
        }
        slice(matched, offset, limit)
    }

    public func search(query: MemoryQuery): ArrayList<MemoryHit> {
        let hits = ArrayList<MemoryHit>()
        for((_, record) in records){
            if(record.userId != query.userId){
                continue
            }
            if(query.namespaces.size > 0 && !containsText(query.namespaces, record.namespace)){
                continue
            }
            if(query.kinds.size > 0 && !containsText(query.kinds, record.kind)){
                continue
            }
            let matched = query.text.isEmpty() || record.title.contains(query.text) ||
                          record.content.contains(query.text)
            if(matched){
                hits.add(MemoryHit(record, 1.0f64))
            }
        }
        let limited = ArrayList<MemoryHit>()
        var index = 0
        while(index < hits.size && index < query.topK){
            limited.add(hits[index])
            index++
        }
        limited
    }

    private func slice(source: ArrayList<MemoryRecord>, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let result = ArrayList<MemoryRecord>()
        var index = offset
        while(index < source.size && index < offset + limit){
            result.add(source[index])
            index++
        }
        result
    }
}

/** 词面检索版知识库；公开是为了让测试能绕开全局 `Embedder` bean 做确定性断言 */
public class InMemoryKnowledgeStore <: KnowledgeStore {
    private let docs = HashMap<String, KnowledgeDoc>()
    private let chunks = HashMap<String, ArrayList<KnowledgeChunk>>()
    private let vectors = HashMap<String, Array<Float64>>()
    private let embedder: ?Embedder

    public init() {
        this.embedder = None
    }

    public init(embedder: Embedder) {
        this.embedder = Some(embedder)
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        docs[doc.docId] = doc
        let list = ArrayList<KnowledgeChunk>()
        var seq: Int64 = 0
        for(content in KnowledgeChunker.split(doc.content)){
            list.add(KnowledgeChunk(doc.docId, seq, content))
            match(embedder){
                case Some(model) => vectors[chunkKey(doc.docId, seq)] = model.embed(content)
                case None => ()
            }
            seq++
        }
        chunks[doc.docId] = list
    }

    public func get(docId: String): ?KnowledgeDoc {
        docs.get(docId)
    }

    public func remove(docId: String): Bool {
        chunks.remove(docId)
        match(docs.get(docId)){
            case Some(_) =>
                docs.remove(docId)
                true
            case None => false
        }
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let terms = KnowledgeSearch.terms(query.text)
        let queryVector = match(embedder){
            case Some(model) => Some(model.embed(query.text))
            case None => None<Array<Float64>>
        }
        if(terms.isEmpty() && queryVector.isNone()){
            return ArrayList<KnowledgeHit>()
        }
        let hits = ArrayList<KnowledgeHit>()
        for((docId, list) in chunks){
            if(query.docIds.size > 0){
                var wanted = false
                for(item in query.docIds){
                    if(item == docId){
                        wanted = true
                        break
                    }
                }
                if(!wanted){
                    continue
                }
            }
            for(chunk in list){
                let lexical = KnowledgeSearch.score(chunk.content, terms)
                let dense = match(queryVector){
                    case Some(target) => match(vectors.get(chunkKey(docId, chunk.seq))){
                        case Some(source) => VectorMath.cosine(target, source)
                        case None => 0.0f64
                    }
                    case None => 0.0f64
                }
                if(lexical <= 0.0f64 && dense <= 0.0f64){
                    continue
                }
                let boosted = if(lexical > 5.0f64){ 5.0f64 }else{ lexical }
                hits.add(KnowledgeHit(docId, chunk.seq, chunk.content, dense + 0.1f64 * boosted))
            }
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    public func docIds(offset: Int64, limit: Int64): ArrayList<String> {
        let ids = ArrayList<String>()
        for((docId, _) in docs){
            ids.add(docId)
        }
        // HashMap 无序，排序后再分页，保证重复调用结果稳定
        for(index in 1..ids.size){
            let current = ids[index]
            var position = index - 1
            while(position >= 0 && ids[position] > current){
                ids[position + 1] = ids[position]
                position--
            }
            ids[position + 1] = current
        }
        let result = ArrayList<String>()
        var index = offset
        while(index < ids.size && result.size < limit){
            result.add(ids[index])
            index++
        }
        result
    }

    private static func chunkKey(docId: String, seq: Int64): String {
        '${docId}#${seq}'
    }
}

class InMemoryCharacterStore <: CharacterStore {
    private let characters = HashMap<Int64, Character>()

    public func get(userId: Int64): ?Character {
        characters.get(userId)
    }

    public func set(character: Character): Unit {
        characters[character.userId] = character
    }

    public func reset(userId: Int64): Unit {
        characters.remove(userId)
    }
}

class InMemorySkillStore <: SkillStore {
    private let skills = HashMap<Int64, Skill>()

    public func upsert(skill: Skill): Unit {
        skills[skill.id] = skill
    }

    public func get(id: Int64): ?Skill {
        skills.get(id)
    }

    public func list(): ArrayList<Skill> {
        let result = ArrayList<Skill>()
        for((_, skill) in skills){
            result.add(skill)
        }
        result
    }

    public func remove(id: Int64): Bool {
        match(skills.get(id)){
            case Some(_) =>
                skills.remove(id)
                true
            case None => false
        }
    }
}

class InMemoryPromptStore <: PromptStore {
    private let versions = HashMap<String, HashMap<Int64, PromptEntry>>()

    public func put(entry: PromptEntry): Unit {
        match(versions.get(entry.name)){
            case Some(bucket) => bucket[entry.version] = entry
            case None =>
                let bucket = HashMap<Int64, PromptEntry>()
                bucket[entry.version] = entry
                versions[entry.name] = bucket
        }
    }

    public func get(name: String, version: Int64): ?PromptEntry {
        match(versions.get(name)){
            case Some(bucket) => bucket.get(version)
            case None => None
        }
    }

    public func latest(name: String): ?PromptEntry {
        match(versions.get(name)){
            case Some(bucket) =>
                var latestVersion: Int64 = -1
                for((version, _) in bucket){
                    if(version > latestVersion){
                        latestVersion = version
                    }
                }
                if(latestVersion < 0){
                    None
                }else{
                    bucket.get(latestVersion)
                }
            case None => None
        }
    }

    public func remove(name: String, version: Int64): Bool {
        match(versions.get(name)){
            case Some(bucket) =>
                match(bucket.get(version)){
                    case Some(_) =>
                        bucket.remove(version)
                        true
                    case None => false
                }
            case None => false
        }
    }
}

class InMemoryLLMConfStore <: LLMConfStore {
    private let views = ArrayList<LLMConfView>()

    public func names(): ArrayList<String> {
        let names = ArrayList<String>()
        for(view in views){
            if(view.enabled && view.weight > 0 && !contains(names, view.llmName)){
                names.add(view.llmName)
            }
        }
        names
    }

    public func candidates(llmName: String): ArrayList<LLMConfView> {
        let result = ArrayList<LLMConfView>()
        for(view in views){
            if(view.enabled && view.weight > 0 && view.llmName == llmName){
                result.add(view)
            }
        }
        result
    }

    public func put(view: LLMConfView): Int64 {
        views.add(view)
        Int64(views.size)
    }

    private static func contains(values: ArrayList<String>, target: String): Bool {
        for(value in values){
            if(value == target){
                return true
            }
        }
        false
    }
}

func containsText(values: Array<String>, target: String): Bool {
    for(value in values){
        if(value == target){
            return true
        }
    }
    false
}