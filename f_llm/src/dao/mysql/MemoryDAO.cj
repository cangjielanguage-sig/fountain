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

/** MySQL 记忆 DAO：普通条件走占位符，MyVector 的 ANN 只能内联字面量。 */
@DAO
public interface MySqlMemoryDAO <: RootDAO {
    func myUpsertMemory(userId: Int64, namespace: String, title: String, content: String,
                      kind: String, titleVector: String, contentVector: String): Int64 {
        let sql = '''
            INSERT INTO llm_memory
                (user_id, namespace, title, content, kind, title_vec, content_vec, save_time, update_time)
            VALUES (${arg(userId)}, ${arg(namespace)}, ${arg(title)}, ${arg(content)}, ${arg(kind)},
                    myvector_construct('${titleVector}'), myvector_construct('${contentVector}'),
                    UTC_TIMESTAMP(), UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                id = LAST_INSERT_ID(id),
                content = VALUES(content),
                kind = VALUES(kind),
                title_vec = VALUES(title_vec),
                content_vec = VALUES(content_vec),
                update_time = UTC_TIMESTAMP()
        '''
        executor.setSql(sql).update
        let row = executor.setSql('SELECT CAST(LAST_INSERT_ID() AS SIGNED) AS id').firstToMap()
        daoIntOf(row.get('id') ?? 0)
    }

    func mySearchDense(userId: Int64, namespaces: Array<String>, vector: String,
                     annPath: String, limit: Int64): ArrayList<HashMap<String, Any>> {
        var filter = 'SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = ${userId}'
        if(namespaces.size > 0){
            var quoted = ''
            for(index in 0..namespaces.size){
                if(index > 0){
                    quoted += ','
                }
                quoted += "'" + daoEscape(namespaces[index]) + "'"
            }
            filter += " AND namespace IN (${quoted})"
        }
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   myvector_distance(m.title_vec, myvector_construct('${vector}')) AS dist
            FROM llm_memory m
            WHERE MYVECTOR_IS_ANN('${annPath}', 'id',
                  myvector_construct('${vector}'), ${limit}, (${filter}))
        '''
        executor.setSql(sql).mapList()
    }

    func myInsertToken(memoryId: Int64, userId: Int64, namespace: String,
                     token: Int64, weight: Float64): Unit {
        let sql = '''
            INSERT INTO llm_memory_token (memory_id, user_id, namespace, field, token, weight)
            VALUES (${arg(memoryId)}, ${arg(userId)}, ${arg(namespace)}, 'm', ${arg(token)}, ${arg(weight)})
        '''
        executor.setSql(sql).update
    }

    func myUpdateColbert(memoryId: Int64, titleBytes: Array<Byte>, contentBytes: Array<Byte>): Unit {
        let sql = '''
            UPDATE llm_memory
            SET title_colbert = ${arg(titleBytes)}, content_colbert = ${arg(contentBytes)}
            WHERE id = ${arg(memoryId)}
        '''
        executor.setSql(sql).update
    }

    func mySearchSparse(userId: Int64, namespaces: Array<String>, tokens: Array<Int64>,
                      limit: Int64): ArrayList<HashMap<String, Any>> {
        let userArg = arg(userId)
        let namespaceClause = if(namespaces.size > 0){
            ' AND ${meet(true, 't.namespace').IN(namespaces)}'
        }else{
            ''
        }
        let tokenClause = meet(true, 't.token').IN(tokens)
        let limitArg = arg(limit)
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   SUM(t.weight) AS score
            FROM llm_memory_token t
            JOIN llm_memory m ON m.id = t.memory_id
            WHERE t.user_id = ${userArg}${namespaceClause} AND ${tokenClause}
            GROUP BY m.id, m.user_id, m.namespace, m.title, m.content, m.kind
            ORDER BY score DESC
            LIMIT ${limitArg}
        '''
        executor.setSql(sql).mapList()
    }

    func mySelectColbert(memoryId: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT title_colbert, content_colbert FROM llm_memory WHERE id = ${arg(memoryId)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func myGet(userId: Int64, id: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT id, user_id, namespace, title, content, kind FROM llm_memory
            WHERE user_id = ${arg(userId)} AND id = ${arg(id)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func myList(userId: Int64, namespace: String, offset: Int64,
              limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT id, user_id, namespace, title, content, kind FROM llm_memory
            WHERE user_id = ${arg(userId)} AND namespace = ${arg(namespace)}
            ORDER BY save_time DESC
            LIMIT ${arg(offset)}, ${arg(limit)}
        '''
        executor.setSql(sql).mapList()
    }

    func myRemoveMemory(userId: Int64, id: Int64): Int64 {
        let sql = 'DELETE FROM llm_memory WHERE user_id = ${arg(userId)} AND id = ${arg(id)}'
        let deleted = executor.setSql(sql).update
        return deleted
    }




}

private func daoIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case _ => 0
    }
}

private func daoEscape(text: String): String {
    text.replace("'", "''")
}
