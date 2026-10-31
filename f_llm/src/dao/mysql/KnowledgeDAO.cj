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
package fountain::f_llm.dao.mysql

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** MySQL 知识文档 DAO（3.3）：同 docId 覆盖写。 */
@DAO
public interface MySqlKnowledgeDAO <: RootDAO {
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
            VALUES (${arg(docId)}, ${arg(title)}, ${arg(content)}, UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                title = VALUES(title),
                content = VALUES(content),
                update_time = UTC_TIMESTAMP()
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

    func chunkInsert(docId: String, seq: Int64, content: String): Unit {
        let sql = '''
            INSERT INTO llm_document_chunk (doc_id, seq, content, update_time)
            VALUES (${arg(docId)}, ${arg(seq)}, ${arg(content)}, UTC_TIMESTAMP())
        '''
        executor.setSql(sql).update
    }

    /** 带块向量的写入：MyVector 的构造不认占位符，内联数值字面量 */
    func chunkInsertVector(docId: String, seq: Int64, content: String, vector: String): Unit {
        let sql = '''
            INSERT INTO llm_document_chunk (doc_id, seq, content, content_vec, update_time)
            VALUES (${arg(docId)}, ${arg(seq)}, ${arg(content)},
                    myvector_construct('${vector}'), UTC_TIMESTAMP())
        '''
        executor.setSql(sql).update
    }

    /** MyVector 的 `MYVECTOR_IS_ANN` 需要 `db.table.column`，当前库名运行时取 */
    func chunkCurrentDatabase(): ?Map<String, Any> {
        let row = executor.setSql('SELECT DATABASE() AS db').firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    /** dense 召回：`myvector_distance` 是余弦距离，调用方换算成相似度 */
    func chunkSearchDense(annPath: String, vector: String, docIds: Array<String>,
                          limit: Int64): ArrayList<HashMap<String, Any>> {
        var filter = 'SELECT JSON_ARRAYAGG(id) FROM llm_document_chunk'
        if(docIds.size > 0){
            var quoted = ''
            for(index in 0..docIds.size){
                if(index > 0){
                    quoted += ','
                }
                quoted += "'" + docIds[index].replace("'", "''") + "'"
            }
            filter += " WHERE doc_id IN (${quoted})"
        }
        let sql = '''
            SELECT m.doc_id, m.seq, m.content,
                   myvector_distance(m.content_vec, myvector_construct('${vector}')) AS dist
            FROM llm_document_chunk m
            WHERE MYVECTOR_IS_ANN('${annPath}', 'id', myvector_construct('${vector}'),
                                  ${limit}, (${filter}))
        '''
        executor.setSql(sql).mapList()
    }

    func docIds(offset: Int64, limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT doc_id FROM llm_document
            ORDER BY doc_id
            LIMIT ${arg(offset)}, ${arg(limit)}
        '''
        executor.setSql(sql).mapList()
    }

    func chunkSearch(pattern: String, limit: Int64, offset: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT doc_id, seq, content FROM llm_document_chunk
            WHERE content LIKE ${arg(pattern)}
            ORDER BY doc_id, seq
            LIMIT ${arg(offset)}, ${arg(limit)}
        '''
        executor.setSql(sql).mapList()
    }
}
