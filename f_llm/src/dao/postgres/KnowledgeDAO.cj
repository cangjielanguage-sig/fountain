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
package fountain::f_llm.dao.postgres

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** 知识文档 DAO（3.x）：llm_document 的读写。 */
@DAO
public interface PostgresKnowledgeDAO <: RootDAO {
    func docGet(docId: String): ?Map<String, Any> {
        let sql = '''
            SELECT title, content FROM llm_document WHERE doc_id = ${arg(docId)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func docUpsert(docId: String, title: String, content: String): Unit {
        let sql = '''
            INSERT INTO llm_document (doc_id, title, content, update_time)
            VALUES (${arg(docId)}, ${arg(title)}, ${arg(content)}, now())
            ON CONFLICT (doc_id)
            DO UPDATE SET title = EXCLUDED.title, content = EXCLUDED.content, update_time = now()
        '''
        executor.setSql(sql).update
    }

    func docDelete(docId: String): Int64 {
        let sql = 'DELETE FROM llm_document WHERE doc_id = ${arg(docId)}'
        let deleted = executor.setSql(sql).update
        return deleted
    }

    func chunkDelete(docId: String): Int64 {
        let sql = 'DELETE FROM llm_document_chunk WHERE doc_id = ${arg(docId)}'
        let deleted = executor.setSql(sql).update
        return deleted
    }

    /** `vector` 为空串时写入 NULL（无 Embedder 的降级路径） */
    func chunkInsert(docId: String, seq: Int64, content: String, vector: String): Unit {
        let sql = '''
            INSERT INTO llm_document_chunk (doc_id, seq, content, content_vec, update_time)
            VALUES (${arg(docId)}, ${arg(seq)}, ${arg(content)},
                    NULLIF(${arg(vector)}, '')::vector, now())
        '''
        executor.setSql(sql).update
    }

    /** dense 召回：`1 - 余弦距离` 作为相似度 */
    func chunkSearchDense(vector: String, limit: Int64): ArrayList<HashMap<String, Any>> {
        // 绑定顺序必须与占位符文本顺序一致：SELECT 向量 → ORDER BY 向量 → limit
        let scoreVector = arg(vector)
        let orderVector = arg(vector)
        let limitArg = arg(limit)
        let sql = '''
            SELECT doc_id, seq, content,
                   1 - (content_vec <=> ${scoreVector}::vector) AS score
            FROM llm_document_chunk
            WHERE content_vec IS NOT NULL
            ORDER BY content_vec <=> ${orderVector}::vector
            LIMIT ${limitArg}
        '''
        executor.setSql(sql).mapList()
    }

    func docIds(offset: Int64, limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT doc_id FROM llm_document
            ORDER BY doc_id
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }

    /** 按首个词做词面召回，分页返回（调用方负责翻页与打分） */
    func chunkSearch(pattern: String, limit: Int64, offset: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT doc_id, seq, content FROM llm_document_chunk
            WHERE content LIKE ${arg(pattern)}
            ORDER BY doc_id, seq
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }
}
