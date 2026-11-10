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

/** PostgreSQL 记忆 DAO：SQL 与参数绑定集中在此。 */
@DAO
public interface PostgresMemoryDAO <: RootDAO {
    func upsertMemory(userId: Int64, namespace: String, title: String,
                      content: String, kind: String): Int64 {
        let sql = '''
            INSERT INTO llm_memory (user_id, namespace, title, content, kind, save_time, update_time)
            VALUES (${arg(userId)}, ${arg(namespace)}, ${arg(title)},
                    ${arg(content)}, ${arg(kind)}, now(), now())
            ON CONFLICT (user_id, namespace, title)
            DO UPDATE SET content = EXCLUDED.content, kind = EXCLUDED.kind, update_time = now()
            RETURNING id
        '''
        let row = executor.setSql(sql).firstToMap()
        daoIntOf(row.get('id') ?? 0)
    }

    func upsertVectors(memoryId: Int64, model: String, titleVector: String, contentVector: String): Unit {
        let sql = '''
            INSERT INTO llm_memory_vector (memory_id, model, title_dense, content_dense, update_time)
            VALUES (${arg(memoryId)}, ${arg(model)}, ${arg(titleVector)}::vector,
                    ${arg(contentVector)}::vector, now())
            ON CONFLICT (memory_id)
            DO UPDATE SET title_dense = EXCLUDED.title_dense,
                          content_dense = EXCLUDED.content_dense,
                          update_time = now()
        '''
        executor.setSql(sql).update
    }

    func searchDense(userId: Int64, namespaces: Array<String>, vector: String,
                     limit: Int64): ArrayList<HashMap<String, Any>> {
        // arg() 在调用时就绑定，顺序必须与 SQL 里占位符出现顺序一致：
        // score 向量 → user_id → namespace IN → ORDER BY 向量 → limit
        let scoreVector = arg(vector)
        let userArg = arg(userId)
        let namespaceClause = if(namespaces.size > 0){
            ' AND ${meet(true, 'm.namespace').IN(namespaces)}'
        }else{
            ''
        }
        let orderVector = arg(vector)
        let limitArg = arg(limit)
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   1 - (v.title_dense <=> ${scoreVector}::vector) AS score
            FROM llm_memory m
            JOIN llm_memory_vector v ON v.memory_id = m.id
            WHERE m.user_id = ${userArg}${namespaceClause}
            ORDER BY v.title_dense <=> ${orderVector}::vector
            LIMIT ${limitArg}
        '''
        executor.setSql(sql).mapList()
    }

    func clearTokens(memoryId: Int64): Unit {
        let sql = 'DELETE FROM llm_memory_token WHERE memory_id = ${arg(memoryId)}'
        executor.setSql(sql).update
    }

    func insertToken(memoryId: Int64, userId: Int64, namespace: String,
                     token: Int64, weight: Float64): Unit {
        let sql = '''
            INSERT INTO llm_memory_token (memory_id, user_id, namespace, field, token, weight)
            VALUES (${arg(memoryId)}, ${arg(userId)}, ${arg(namespace)}, 'm',
                    ${arg(token)}, ${arg(weight)})
        '''
        executor.setSql(sql).update
    }

    func updateColbert(memoryId: Int64, titleBytes: Array<Byte>, contentBytes: Array<Byte>): Unit {
        let sql = '''
            UPDATE llm_memory_vector
            SET title_colbert = ${arg(titleBytes)}, content_colbert = ${arg(contentBytes)},
                has_colbert = true, update_time = now()
            WHERE memory_id = ${arg(memoryId)}
        '''
        executor.setSql(sql).update
    }

    func searchSparse(userId: Int64, namespaces: Array<String>, tokens: Array<Int64>,
                      limit: Int64): ArrayList<HashMap<String, Any>> {
        // 绑定顺序：user_id → namespace IN → token IN → limit
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
            WHERE t.user_id = ${userArg}${namespaceClause}
              AND ${tokenClause}
            GROUP BY m.id, m.user_id, m.namespace, m.title, m.content, m.kind
            ORDER BY score DESC
            LIMIT ${limitArg}
        '''
        executor.setSql(sql).mapList()
    }

    func selectColbert(memoryId: Int64): ?Map<String, Any> {
        let sql = '''
            SELECT title_colbert, content_colbert FROM llm_memory_vector
            WHERE memory_id = ${arg(memoryId)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func get(userId: Int64, id: Int64): ?Map<String, Any> {
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

    func list(userId: Int64, namespace: String, offset: Int64,
              limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT id, user_id, namespace, title, content, kind FROM llm_memory
            WHERE user_id = ${arg(userId)} AND namespace = ${arg(namespace)}
            ORDER BY save_time DESC
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }

    /** 按 kind 分页：过滤在 SQL 里做，不会出现「本页没有就判空」 */
    func listByKind(userId: Int64, namespace: String, kind: String, offset: Int64,
                    limit: Int64): ArrayList<HashMap<String, Any>> {
        let sql = '''
            SELECT id, user_id, namespace, title, content, kind FROM llm_memory
            WHERE user_id = ${arg(userId)} AND namespace = ${arg(namespace)} AND kind = ${arg(kind)}
            ORDER BY save_time DESC
            LIMIT ${arg(limit)} OFFSET ${arg(offset)}
        '''
        executor.setSql(sql).mapList()
    }

    func deleteVectors(id: Int64): Unit {
        executor.setSql('DELETE FROM llm_memory_vector WHERE memory_id = ${arg(id)}').update
    }

    func removeMemory(userId: Int64, id: Int64): Int64 {
        let sql = 'DELETE FROM llm_memory WHERE user_id = ${arg(userId)} AND id = ${arg(id)}'
        let deleted = executor.setSql(sql).update
        return deleted
    }


}

/**
 * MySQL 记忆 DAO。
 *
 * 普通条件一律 `${arg(...)}` / `${meet(...).IN(...)}`；唯一例外是 MyVector 的
 * `MYVECTOR_IS_ANN` / `myvector_construct`：组件改写不认占位符（实测 1064），
 * 只能内联数值字面量（向量只含数字，namespace 做引号转义，user_id 为 Int64）。
 */
private func daoIntOf(value: Any): Int64 {
    match(value){
        case number: Int64 => number
        case number: Int32 => Int64(number)
        case _ => 0
    }
}
