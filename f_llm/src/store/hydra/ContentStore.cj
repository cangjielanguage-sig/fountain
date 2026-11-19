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
package fountain::f_llm.store.hydra

import std.collection.*
import std.env.*
import std.time.*

import fountain::f_bean.*
import fountain::f_hydra.*

import fountain::f_llm.store.*

/** 进程内 f_hydra 内容族（默认）：记忆 + 知识都走 InProcessTransport */
public class HydraContentStore <: ContentStore {
    private let transport: HydraTransport
    private let model: Embedder
    private var cachedMemory: ?MemoryStore = None
    private var cachedKnowledge: ?KnowledgeStore = None

    public init() {
        let location = DeployPaths.resolve(getVariable('llm_hydraPath') ?? './data/f_hydra')
        this.transport = InProcessTransport(FStoreVectorStore(location))
        this.model = requireEmbedder()
    }

    init(transport: HydraTransport) {
        this.transport = transport
        this.model = requireEmbedder()
    }

    public prop memory: MemoryStore {
        get() {
            match(cachedMemory){
                case Some(value) => value
                case None =>
                    let impl = SqlMemoryStore(HydraMemoryRepository(transport), model)
                    cachedMemory = Some(impl)
                    impl
            }
        }
    }

    public prop knowledge: KnowledgeStore {
        get() {
            match(cachedKnowledge){
                case Some(value) => value
                case None =>
                    let impl = HydraKnowledgeStore(transport, model)
                    cachedKnowledge = Some(impl)
                    impl
            }
        }
    }

    private static func requireEmbedder(): Embedder {
        match(lookupOption<Embedder>()){
            case Some(value) => value
            case None => throw IllegalStateException(
                'content store requires an Embedder bean (DefaultEmbedder)')
        }
    }
}

/** 远程 fhydra 内容族：复用同一套仓库/知识实现，只把传输换成 HTTP */
public class FhydraContentStore <: ContentStore {
    private let delegate: HydraContentStore

    public init() {
        this.delegate = HydraContentStore(HttpTransport())
    }

    public prop memory: MemoryStore {
        get() { delegate.memory }
    }

    public prop knowledge: KnowledgeStore {
        get() { delegate.knowledge }
    }
}

/**
 * 知识库：块级记录，dense（content）+ sparse 两路召回。
 *
 * - collection `f_llm:kb`：`doc:{docId}` 存标题+正文，`{docId}#{seq}` 存块；
 * - `f_llm:kb:docs`：docId → 块数（覆盖写时据此清理旧块）。
 */
class HydraKnowledgeStore <: KnowledgeStore {
    private static let KB = 'f_llm:kb'
    private static let DOCS = 'f_llm:kb:docs'
    private static let SEP = String.fromUtf8([1u8])

    private let transport: HydraTransport
    private let model: Embedder

    init(transport: HydraTransport, model: Embedder) {
        this.transport = transport
        this.model = model
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        purgeChunks(doc.docId)
        transport.upsert(KB, VectorRecord('doc:${doc.docId}',
                                          '${doc.title}${SEP}${doc.content}',
                                          Array<Float64>()))
        var seq: Int64 = 0
        for(chunk in KnowledgeChunker.split(doc.content)){
            let vector = model.embed(chunk)
            let vectors = HashMap<String, Array<Float64>>()
            vectors['content'] = vector
            transport.upsert(KB, VectorRecord('${doc.docId}#${seq}', chunk, vector,
                                              sparse: model.tokenize(chunk), vectors: vectors,
                                              saveTime: DateTime.now().toUnixTimeStamp().toSeconds()))
            seq++
        }
        transport.upsert(DOCS, VectorRecord(doc.docId, seq.toString(), Array<Float64>()))
    }

    public func get(docId: String): ?KnowledgeDoc {
        match(transport.get(KB, 'doc:${docId}')){
            case Some(record) =>
                let parts = record.payload.split(SEP)
                if(parts.size < 2){
                    return None
                }
                Some(KnowledgeDoc(docId, parts[0], parts[1]))
            case None => None
        }
    }

    public func remove(docId: String): Bool {
        purgeChunks(docId)
        transport.remove(DOCS, docId)
        transport.remove(KB, 'doc:${docId}')
    }

    public func docIds(offset: Int64, limit: Int64): ArrayList<String> {
        let ids = ArrayList<String>()
        for(id in transport.ids(DOCS, offset, limit)){
            ids.add(id)
        }
        ids
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let hits = ArrayList<KnowledgeHit>()
        if(query.limit <= 0){
            return hits
        }
        let scores = HashMap<String, Float64>()
        if(!query.text.isEmpty()){
            for(hit in transport.searchDenseField(KB, 'content', model.embed(query.text), 200)){
                scores[hit.id] = hit.score
            }
            let tokens = model.tokenize(query.text)
            for(hit in transport.searchSparse(KB, tokens, 200)){
                let current = scores.get(hit.id) ?? 0.0f64
                scores[hit.id] = current + hit.score * 0.1f64
            }
        }
        // 每个候选都要 transport.get 一次正文（N+1）。先按分数排序、只取前 bound 个，
        // 把远程往返从「候选数」压到「需要的条数量级」；不够再顺延，保证 limit 仍能填满。
        let ranked = ArrayList<String>()
        for((id, value) in scores){
            ranked.add(id)
        }
        // 选择排序（候选最多几百，O(n²) 远小于一次远程往返）
        for(position in 0..ranked.size){
            var best = position
            for(candidate in position + 1..ranked.size){
                let left = scores.get(ranked[candidate]) ?? 0.0f64
                let right = scores.get(ranked[best]) ?? 0.0f64
                if(left > right){
                    best = candidate
                }
            }
            if(best != position){
                let temp = ranked[position]
                ranked[position] = ranked[best]
                ranked[best] = temp
            }
        }
        var bound = query.limit * 4
        if(bound < 20){
            bound = 20
        }
        if(bound > ranked.size){
            bound = ranked.size
        }
        var index = 0
        while(index < ranked.size && Int64(hits.size) < query.limit){
            let id = ranked[index]
            let score = scores.get(id) ?? 0.0f64
            index++
            match(transport.get(KB, id)){
                case Some(record) =>
                    let parts = id.split('#')
                    if(parts.size < 2){
                        continue
                    }
                    let docId = parts[0]
                    if(!wanted(query, docId)){
                        continue
                    }
                    hits.add(KnowledgeHit(docId, Int64.tryParse(parts[1]) ?? 0,
                                          record.payload, score))
                case None => ()
            }
            // 前 bound 个都取完还没凑够时，放宽到全量继续找（正确性优先于省往返）
            if(index >= bound && Int64(hits.size) < query.limit){
                bound = ranked.size
            }
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    private func purgeChunks(docId: String): Unit {
        match(transport.get(DOCS, docId)){
            case Some(record) =>
                let count = Int64.tryParse(record.payload) ?? 0
                for(seq in 0..count){
                    transport.remove(KB, '${docId}#${seq}')
                }
            case None => ()
        }
    }

    private static func wanted(query: KnowledgeQuery, docId: String): Bool {
        if(query.docIds.isEmpty()){
            return true
        }
        for(item in query.docIds){
            if(item == docId){
                return true
            }
        }
        false
    }
}

let _hydraContentRegistered = Stores.registerContent('f_hydra', { => HydraContentStore() })
let _fhydraContentRegistered = Stores.registerContent('fhydra', { => FhydraContentStore() })
