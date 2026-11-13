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
package fountain::f_llm.store.mysql

import std.collection.*
import fountain::f_orm.*
import fountain::f_llm.dao.mysql.*
import fountain::f_llm.store.*

/**
 * MySQL 知识文档存储：同 docId 覆盖写，按块建索引。
 *
 * 检索与 PG 同口径（P0.2）：
 * - dense：`MYVECTOR_IS_ANN` + `myvector_distance`（余弦距离 → 相似度 = 1 - dist）；
 * - lexical：`LIKE` 召回 + 命中数加成；
 * - 合并 `score = cosine + 0.1 × min(命中次数, 5)`。
 */
public class MySqlKnowledgeStore <: KnowledgeStore & RootService {
    private let embedder: ?Embedder
    private let pageSize: Int64
    private let maxCandidates: Int64
    private var cachedDatabase: ?String = None

    /** 无语义实现（lexical-only） */
    public init() {
        this.embedder = None
        this.pageSize = 200
        this.maxCandidates = 1000
    }

    /** 无语义、可调分页参数（用于验证翻页行为） */
    public init(pageSize!: Int64, maxCandidates!: Int64 = 1000) {
        if (pageSize <= 0 || maxCandidates < pageSize) {
            throw IllegalArgumentException(
                'invalid candidate paging: pageSize=${pageSize}, maxCandidates=${maxCandidates}')
        }
        this.embedder = None
        this.pageSize = pageSize
        this.maxCandidates = maxCandidates
    }

    public init(embedder: Embedder, pageSize!: Int64 = 200, maxCandidates!: Int64 = 400) {
        if (pageSize <= 0 || maxCandidates < pageSize) {
            throw IllegalArgumentException(
                'invalid candidate paging: pageSize=${pageSize}, maxCandidates=${maxCandidates}')
        }
        this.embedder = Some(embedder)
        this.pageSize = pageSize
        this.maxCandidates = maxCandidates
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        let store = dao<MySqlKnowledgeDAO>('mysql')
        store.docUpsert(doc.docId, doc.title, doc.content)
        store.chunkDelete(doc.docId)
        var seq: Int64 = 0
        for (chunk in KnowledgeChunker.split(doc.content)) {
            match (embedder) {
                case Some(model) => store.chunkInsertVector(doc.docId, seq, chunk,
                    VectorMath.literal(model.embed(chunk)))
                case None => store.chunkInsert(doc.docId, seq, chunk)
            }
            seq++
        }
    }

    public func get(docId: String): ?KnowledgeDoc {
        match (dao<MySqlKnowledgeDAO>('mysql').docGet(docId)) {
            case Some(row) => Some(KnowledgeDoc(docId, textOf(row.get('title')), textOf(row.get('content'))))
            case None => None
        }
    }

    public func remove(docId: String): Bool {
        let store = dao<MySqlKnowledgeDAO>('mysql')
        store.chunkDelete(docId)
        store.docDelete(docId) > 0
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let terms = KnowledgeSearch.terms(query.text)
        let merged = HashMap<String, ChunkScoreMySql>()

        match (embedder) {
            case Some(model) =>
                if (!query.text.isEmpty()) {
                    let literal = VectorMath.literal(model.embed(query.text))
                    let path = annPath()
                    if (!path.isEmpty()) {
                        for (row in dao<MySqlKnowledgeDAO>('mysql').chunkSearchDense(path, literal,
                            query.docIds.toArray(), denseK(query))) {
                            let docId = textOf(row.get('doc_id'))
                            let seq = chunkIntOf(row.get('seq'))
                            let key = scoreKey(docId, seq)
                            let score = merged.get(key) ?? ChunkScoreMySql(docId, seq, textOf(row.get('content')))
                            // MyVector COSINE：距离 = 1 - 相似度
                            score.dense = maxOf(score.dense, 1.0f64 - chunkFloatOf(row.get('dist')))
                            merged[key] = score
                        }
                    }
                }
            case None => ()
        }

        if (!terms.isEmpty()) {
            let pattern = '%' + terms[0] + '%'
            var offset: Int64 = 0
            var collected: Int64 = 0
            while (collected < maxCandidates) {
                let page = dao<MySqlKnowledgeDAO>('mysql').chunkSearch(pattern, pageSize, offset)
                if (page.isEmpty()) {
                    break
                }
                for (row in page) {
                    let docId = textOf(row.get('doc_id'))
                    if (!wanted(query, docId)) {
                        continue
                    }
                    let occurrences = KnowledgeSearch.score(textOf(row.get('content')), terms)
                    if (occurrences <= 0.0f64) {
                        continue
                    }
                    let seq = chunkIntOf(row.get('seq'))
                    let key = scoreKey(docId, seq)
                    let score = merged.get(key) ?? ChunkScoreMySql(docId, seq, textOf(row.get('content')))
                    score.lexical = occurrences
                    merged[key] = score
                }
                collected += page.size
                if (page.size < pageSize) {
                    break
                }
                offset += pageSize
            }
        }

        let hits = ArrayList<KnowledgeHit>()
        for ((_, score) in merged) {
            hits.add(
                KnowledgeHit(score.docId, score.seq, score.content,
                    RetrievalScoring.fuseKnowledge(score.dense, score.lexical)))
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    public func docIds(offset: Int64, limit: Int64): ArrayList<String> {
        let result = ArrayList<String>()
        for (row in dao<MySqlKnowledgeDAO>('mysql').docIds(offset, limit)) {
            let docId = textOf(row.get('doc_id'))
            if (!docId.isEmpty()) {
                result.add(docId)
            }
        }
        result
    }

    private func denseK(query: KnowledgeQuery): Int64 {
        let wanted = if (query.limit > 0) {
            query.limit * 20
        } else {
            pageSize
        }
        let bounded = if (wanted > maxCandidates) {
            maxCandidates
        } else {
            wanted
        }
        if (bounded < pageSize) {
            pageSize
        } else {
            bounded
        }
    }

    /** `db.table.column`：MyVector 的 ANN 路径，库名从 `SELECT DATABASE()` 取一次 */
    private func annPath(): String {
        let database = match (cachedDatabase) {
            case Some(value) => value
            case None =>
                let value = match (dao<MySqlKnowledgeDAO>('mysql').chunkCurrentDatabase()) {
                    case Some(row) => textOf(row.get('db'))
                    case None => ''
                }
                cachedDatabase = Some(value)
                value
        }
        if (database.isEmpty()) {
            return ''
        }
        '${database}.llm_document_chunk.content_vec'
    }

    private static func wanted(query: KnowledgeQuery, docId: String): Bool {
        if (query.docIds.isEmpty()) {
            return true
        }
        for (item in query.docIds) {
            if (item == docId) {
                return true
            }
        }
        false
    }

    private static func scoreKey(docId: String, seq: Int64): String {
        '${docId}#${seq}'
    }

    private static func maxOf(a: Float64, b: Float64): Float64 {
        if (a > b) {
            a
        } else {
            b
        }
    }

    private static func minOf(a: Float64, b: Float64): Float64 {
        if (a < b) {
            a
        } else {
            b
        }
    }
}

/** 同一块的两路得分 */
class ChunkScoreMySql {
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

private func chunkIntOf(value: ?Any): Int64 {
    match (value) {
        case Some(raw) => match (raw) {
            case number: Int64 => number
            case number: Int32 => Int64(number)
            case _ => 0
        }
        case None => 0
    }
}

private func chunkFloatOf(value: ?Any): Float64 {
    match (value) {
        case Some(raw) => match (raw) {
            case number: Float64 => number
            case number: Float32 => Float64(number)
            case number: Int64 => Float64(number)
            case _ => 0.0f64
        }
        case None => 0.0f64
    }
}

private func textOf(value: ?Any): String {
    match (value) {
        case Some(raw) => match (raw) {
            case text: String => text
            case _ => ''
        }
        case None => ''
    }
}
