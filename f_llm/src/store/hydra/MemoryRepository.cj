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
import std.convert.*
import std.env.*
import std.time.*

import fountain::f_hydra.*

import fountain::f_llm.store.*

/**
 * 进程内 f_hydra 记忆仓库（方案 C）。
 *
 * 每个 (userId, namespace) 一个 collection；一条记忆一条记录：
 * - `vectors = {title, content}`，默认 dense 用 content 向量；
 * - `filters = {kind}`；
 * - payload 是 f_llm 自己的编码（`title\u0001content\u0001kind\u0001saveTime\u0001namespace`），
 *   f_hydra 不解析。
 *
 * id 全局自增，落在映射 collection `f_llm:mem:map`：
 * - `seq` → 当前最大 id；
 * - `map:{id}` → 该记忆所属 collection（`get/remove/colbert` 只有 id 参数时需要）。
 */
public class HydraMemoryRepository <: MemoryRepository {
    private static let MAP = 'f_llm:mem:map'
    private static let SEQ_KEY = 'seq'
    private static let SEP = String.fromUtf8([1u8])

    private let store: FStoreVectorStore

    public init(path!: String = '') {
        let location = if(path.isEmpty()){
            getVariable('llm_hydraPath') ?? './data/f_hydra'
        }else{
            path
        }
        this.store = FStoreVectorStore(location)
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        let id = nextId()
        let collection = collectionOf(write.userId, write.namespace)
        let saveTime = DateTime.now().toUnixTimeStamp().toSeconds()
        let vectors = HashMap<String, Array<Float64>>()
        vectors['title'] = titleVector
        vectors['content'] = contentVector
        let filters = HashMap<String, String>()
        if(!write.kind.isEmpty()){
            filters['kind'] = write.kind
        }
        store.upsert(collection, VectorRecord(id.toString(),
                                              encode(write.title, write.content, write.kind,
                                                     saveTime, write.namespace),
                                              contentVector, vectors: vectors,
                                              filters: filters, saveTime: saveTime))
        store.upsert(MAP, VectorRecord('map:${id}', collection, Array<Float64>()))
        id
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>,
                            limit: Int64): ArrayList<MemoryHit> {
        let hits = ArrayList<MemoryHit>()
        if(limit <= 0){
            return hits
        }
        for(namespace in query.namespaces){
            let collection = collectionOf(query.userId, namespace)
            for(hit in store.searchDenseField(VectorQuery(collection, vector, limit: limit), 'content')){
                collect(hits, query, collection, hit)
            }
        }
        rank(hits, limit)
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        let hits = ArrayList<MemoryHit>()
        if(limit <= 0 || tokens.isEmpty()){
            return hits
        }
        for(namespace in query.namespaces){
            let collection = collectionOf(query.userId, namespace)
            for(hit in store.searchSparse(SparseQuery(collection, tokens, limit: limit))){
                collect(hits, query, collection, hit)
            }
        }
        rank(hits, limit)
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        rewrite(memoryId, tokens, None<Array<Array<Float64>>>)
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        // 一条记录只有一组 colbert：标题在前、正文在后（f_hydra 不区分，由调用方约定）
        let merged = ArrayList<Array<Float64>>()
        for(vector in titleVectors){
            merged.add(vector)
        }
        for(vector in contentVectors){
            merged.add(vector)
        }
        rewrite(memoryId, HashMap<Int64, Float64>(), Some(merged.toArray()))
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        let collection = collectionOfId(recordId)
        if(collection.isEmpty()){
            return None
        }
        match(store.get(collection, recordId.toString())){
            case Some(record) =>
                let title = match(record.vectors.get('title')){
                    case Some(vector) => Array<Array<Float64>>()
                    case None => Array<Array<Float64>>()
                }
                Some(ColbertVectors(title, record.colbert))
            case None => None
        }
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        let collection = collectionOfId(id)
        if(collection.isEmpty()){
            return None
        }
        match(store.get(collection, id.toString())){
            case Some(record) => Some(decode(userId, record))
            case None => None
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64,
                     limit: Int64): ArrayList<MemoryRecord> {
        let records = ArrayList<MemoryRecord>()
        let collection = collectionOf(userId, namespace)
        for(id in store.ids(collection, offset, limit)){
            match(store.get(collection, id)){
                case Some(record) => records.add(decode(userId, record))
                case None => ()
            }
        }
        records
    }

    public func remove(userId: Int64, id: Int64): Bool {
        let collection = collectionOfId(id)
        if(collection.isEmpty()){
            return false
        }
        let removed = store.remove(collection, id.toString())
        if(removed){
            store.remove(MAP, 'map:${id}')
        }
        removed
    }

    // ---- internal ----

    private func collect(hits: ArrayList<MemoryHit>, query: MemoryQuery,
                         collection: String, hit: VectorHit): Unit {
        if(!kindWanted(query, collection, hit.id)){
            return
        }
        match(store.get(collection, hit.id)){
            case Some(record) => hits.add(MemoryHit(decode(query.userId, record), hit.score))
            case None => ()
        }
    }

    /** kind 过滤放在 f_llm 侧：f_hydra 的 filters 只支持单值精确匹配 */
    private func kindWanted(query: MemoryQuery, collection: String, id: String): Bool {
        if(query.kinds.isEmpty()){
            return true
        }
        match(store.get(collection, id)){
            case Some(record) =>
                let kind = decode(0, record).kind
                for(item in query.kinds){
                    if(item == kind){
                        return true
                    }
                }
                false
            case None => false
        }
    }

    private func rewrite(memoryId: Int64, tokens: HashMap<Int64, Float64>,
                         colbert: ?Array<Array<Float64>>): Unit {
        let collection = collectionOfId(memoryId)
        if(collection.isEmpty()){
            return
        }
        match(store.get(collection, memoryId.toString())){
            case Some(record) =>
                let sparse = if(tokens.isEmpty()){ record.sparse }else{ tokens }
                let vectors = match(colbert){
                    case Some(values) => values
                    case None => record.colbert
                }
                store.upsert(collection, VectorRecord(record.id, record.payload, record.dense,
                                                      sparse: sparse, colbert: vectors,
                                                      filters: record.filters,
                                                      vectors: record.vectors,
                                                      saveTime: record.saveTime))
            case None => ()
        }
    }

    private func nextId(): Int64 {
        var current: Int64 = 0
        match(store.get(MAP, SEQ_KEY)){
            case Some(record) => current = Int64.tryParse(record.payload) ?? 0
            case None => ()
        }
        let next = current + 1
        store.upsert(MAP, VectorRecord(SEQ_KEY, next.toString(), Array<Float64>()))
        next
    }

    private func collectionOfId(id: Int64): String {
        match(store.get(MAP, 'map:${id}')){
            case Some(record) => record.payload
            case None => ''
        }
    }

    private static func collectionOf(userId: Int64, namespace: String): String {
        'f_llm:mem:${userId}:${namespace}'
    }

    private static func encode(title: String, content: String, kind: String,
                               saveTime: Int64, namespace: String): String {
        '${title}${SEP}${content}${SEP}${kind}${SEP}${saveTime}${SEP}${namespace}'
    }

    private static func decode(userId: Int64, record: VectorRecord): MemoryRecord {
        let id = Int64.tryParse(record.id) ?? 0
        let parts = record.payload.split(SEP)
        if(parts.size < 5){
            return MemoryRecord(id, userId, '', '', '', '', DateTime.now())
        }
        MemoryRecord(id, userId, parts[4], parts[0], parts[1], parts[2], DateTime.now())
    }

    private static func rank(hits: ArrayList<MemoryHit>, limit: Int64): ArrayList<MemoryHit> {
        for(index in 1..hits.size){
            let current = hits[index]
            var position = index - 1
            while(position >= 0 && hits[position].score < current.score){
                hits[position + 1] = hits[position]
                position--
            }
            hits[position + 1] = current
        }
        let top = ArrayList<MemoryHit>()
        for(index in 0..hits.size){
            if(Int64(index) >= limit){
                break
            }
            top.add(hits[index])
        }
        top
    }
}
