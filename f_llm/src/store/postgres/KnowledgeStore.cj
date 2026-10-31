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
package fountain::f_llm.store.postgres

import std.collection.*

import fountain::f_orm.*

import fountain::f_llm.dao.postgres.*
import fountain::f_llm.store.*

/**
 * PostgreSQL 知识文档存储：同 docId 覆盖写，按块建索引。
 *
 * 检索是**混合**的（P0.2）：
 * - dense：块向量走 `<=>`（余弦距离）取近邻；
 * - lexical：`LIKE` 召回候选，按词频加分。
 * 最终 `score = cosine + 0.1 * min(命中次数, 5)`——语义为主，精确词命中做加成。
 */
public class PostgresKnowledgeStore <: KnowledgeStore & RootService {
    private static let CANDIDATES: Int64 = 200
    private static let LEXICAL_WEIGHT = 0.1f64
    private static let LEXICAL_CAP = 5.0f64

    private let embedder: ?Embedder

    /** 无语义实现（lexical-only）：测试或未配置 Embedder 时使用 */
    public init() {
        this.embedder = None
    }

    public init(embedder: Embedder) {
        this.embedder = Some(embedder)
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        let store = dao<PostgresKnowledgeDAO>('postgres')
        store.docUpsert(doc.docId, doc.title, doc.content)
        store.chunkDelete(doc.docId)
        var seq: Int64 = 0
        for(chunk in KnowledgeChunker.split(doc.content)){
            store.chunkInsert(doc.docId, seq, chunk, vectorOf(chunk))
            seq++
        }
    }

    public func get(docId: String): ?KnowledgeDoc {
        match(dao<PostgresKnowledgeDAO>('postgres').docGet(docId)){
            case Some(row) =>
                Some(KnowledgeDoc(docId, textOf(row.get('title')), textOf(row.get('content'))))
            case None => None
        }
    }

    public func remove(docId: String): Bool {
        let store = dao<PostgresKnowledgeDAO>('postgres')
        store.chunkDelete(docId)
        store.docDelete(docId) > 0
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let terms = KnowledgeSearch.terms(query.text)
        let merged = HashMap<String, ChunkScore>()

        // 1. dense 召回（语义）
        match(embedder){
            case Some(model) =>
                if(!query.text.isEmpty()){
                    let literal = VectorMath.literal(model.embed(query.text))
                    for(row in dao<PostgresKnowledgeDAO>('postgres').chunkSearchDense(literal, PostgresKnowledgeStore.CANDIDATES)){
                        let docId = textOf(row.get('doc_id'))
                        if(!PostgresKnowledgeStore.wanted(query, docId)){
                            continue
                        }
                        let key = PostgresKnowledgeStore.scoreKey(docId, chunkIntOf(row.get('seq')))
                        let score = merged.get(key) ?? ChunkScore(docId, chunkIntOf(row.get('seq')),
                                                                  textOf(row.get('content')))
                        score.dense = PostgresKnowledgeStore.maxOf(score.dense, chunkFloatOf(row.get('score')))
                        merged[key] = score
                    }
                }
            case None => ()
        }

        // 2. lexical 召回（精确词）
        if(!terms.isEmpty()){
            let pattern = '%' + terms[0] + '%'
            for(row in dao<PostgresKnowledgeDAO>('postgres').chunkSearch(pattern, PostgresKnowledgeStore.CANDIDATES)){
                let docId = textOf(row.get('doc_id'))
                if(!PostgresKnowledgeStore.wanted(query, docId)){
                    continue
                }
                let content = textOf(row.get('content'))
                let occurrences = KnowledgeSearch.score(content, terms)
                if(occurrences <= 0.0f64){
                    continue
                }
                let key = PostgresKnowledgeStore.scoreKey(docId, chunkIntOf(row.get('seq')))
                let score = merged.get(key) ?? ChunkScore(docId, chunkIntOf(row.get('seq')), content)
                score.lexical = occurrences
                merged[key] = score
            }
        }

        let hits = ArrayList<KnowledgeHit>()
        for((_, score) in merged){
            hits.add(KnowledgeHit(score.docId, score.seq, score.content,
                                  score.dense + PostgresKnowledgeStore.LEXICAL_WEIGHT * PostgresKnowledgeStore.minOf(score.lexical, PostgresKnowledgeStore.LEXICAL_CAP)))
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    private func vectorOf(chunk: String): String {
        match(embedder){
            case Some(model) => VectorMath.literal(model.embed(chunk))
            case None => ''
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

    private static func scoreKey(docId: String, seq: Int64): String {
        '${docId}#${seq}'
    }

    private static func maxOf(a: Float64, b: Float64): Float64 {
        if(a > b){ a }else{ b }
    }

    private static func minOf(a: Float64, b: Float64): Float64 {
        if(a < b){ a }else{ b }
    }
}

/** 同一块的两路得分（dense 相似度 + lexical 命中数） */
class ChunkScore {
    public let docId: String
    public let seq: Int64
    public let content: String
    public var dense: Float64 = 0.0f64
    public var lexical: Float64 = 0.0f64

    public init(docId: String, seq: Int64, content: String) {
        this.docId = docId
        this.seq = seq
        this.content = content
    }
}

private func textOf(value: ?Any): String {
    match(value){
        case Some(raw) =>
            match(raw){
                case text: String => text
                case _ => ''
            }
        case None => ''
    }
}

private func chunkIntOf(value: ?Any): Int64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Int64 => number
                case number: Int32 => Int64(number)
                case _ => 0
            }
        case None => 0
    }
}

private func chunkFloatOf(value: ?Any): Float64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Float64 => number
                case number: Float32 => Float64(number)
                case number: Int64 => Float64(number)
                case _ => 0.0f64
            }
        case None => 0.0f64
    }
}
