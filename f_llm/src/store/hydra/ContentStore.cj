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

/** 进程内 f_hydra 内容族：记忆走 HydraMemoryRepository，知识走 dense+sparse 混合检索 */
public class HydraContentStore <: ContentStore {
    private let store: FStoreVectorStore
    private let model: Embedder
    private var cachedMemory: ?MemoryStore = None
    private var cachedKnowledge: ?KnowledgeStore = None

    public init() {
        let path = getVariable('llm_hydraPath') ?? './data/f_hydra'
        this.store = FStoreVectorStore(path)
        this.model = match(lookupOption<Embedder>()){
            case Some(value) => value
            case None => throw IllegalStateException(
                'llm_memoryStore=f_hydra requires an Embedder bean (DefaultEmbedder)')
        }
    }

    public prop memory: MemoryStore {
        get() {
            match(cachedMemory){
                case Some(value) => value
                case None =>
                    let impl = SqlMemoryStore(HydraMemoryRepository(), model)
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
                    let impl = HydraKnowledgeStore(store, model)
                    cachedKnowledge = Some(impl)
                    impl
            }
        }
    }
}

/**
 * f_hydra 知识库：块级记录，dense（content）+ sparse 两路召回。
 *
 * - collection `f_llm:kb`：`doc:{docId}` 存标题+正文，`{docId}#{seq}` 存块；
 * - `f_llm:kb:docs`：docId → 块数（覆盖写时据此清理旧块）。
 */
class HydraKnowledgeStore <: KnowledgeStore {
    private static let KB = 'f_llm:kb'
    private static let DOCS = 'f_llm:kb:docs'
    private static let SEP = String.fromUtf8([1u8])

    private let store: FStoreVectorStore
    private let model: Embedder

    init(store: FStoreVectorStore, model: Embedder) {
        this.store = store
        this.model = model
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        purgeChunks(doc.docId)
        store.upsert(KB,
                     VectorRecord('doc:${doc.docId}',
                                  '${doc.title}${SEP}${doc.content}',
                                  Array<Float64>()))
        var seq: Int64 = 0
        for(chunk in KnowledgeChunker.split(doc.content)){
            let vectors = HashMap<String, Array<Float64>>()
            vectors['content'] = model.embed(chunk)
            store.upsert(KB,
                         VectorRecord('${doc.docId}#${seq}', chunk, vectors['content'],
                                      sparse: model.tokenize(chunk), vectors: vectors,
                                      saveTime: DateTime.now().toUnixTimeStamp().toSeconds()))
            seq++
        }
        store.upsert(DOCS,
                     VectorRecord(doc.docId, seq.toString(), Array<Float64>()))
    }

    public func get(docId: String): ?KnowledgeDoc {
        match(store.get(KB, 'doc:${docId}')){
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
        store.remove(DOCS, docId)
        store.remove(KB, 'doc:${docId}')
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let hits = ArrayList<KnowledgeHit>()
        if(query.limit <= 0){
            return hits
        }
        let scores = HashMap<String, Float64>()
        if(!query.text.isEmpty()){
            for(hit in store.searchDenseField(
                    VectorQuery(KB, model.embed(query.text), limit: 200), 'content')){
                scores[hit.id] = hit.score
            }
            let tokens = model.tokenize(query.text)
            for(hit in store.searchSparse(SparseQuery(KB, tokens, limit: 200))){
                let current = scores.get(hit.id) ?? 0.0f64
                scores[hit.id] = current + hit.score * 0.1f64
            }
        }
        for((id, score) in scores){
            match(store.get(KB, id)){
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
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    public func docIds(offset: Int64, limit: Int64): ArrayList<String> {
        let ids = ArrayList<String>()
        for(id in store.ids(DOCS, offset, limit)){
            ids.add(id)
        }
        ids
    }

    private func purgeChunks(docId: String): Unit {
        match(store.get(DOCS, docId)){
            case Some(record) =>
                let count = Int64.tryParse(record.payload) ?? 0
                for(seq in 0..count){
                    store.remove(KB, '${docId}#${seq}')
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
