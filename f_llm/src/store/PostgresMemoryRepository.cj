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

import fountain::f_orm.*

/**
 * PostgreSQL 记忆仓库（2.8b）。
 *
 * 只负责 SQL 与行映射；权重、融合、截断在 store 层。
 */
public class PostgresMemoryRepository <: MemoryRepository {
    private static let MEMORY_COLUMNS = 'id, user_id, namespace, title, content, kind'

    private let executor: SqlExecutor

    public init(executor: SqlExecutor) {
        this.executor = executor
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        let row = executor.setSql('''
            INSERT INTO llm_memory (user_id, namespace, title, content, kind, save_time, update_time)
            VALUES (?, ?, ?, ?, ?, now(), now())
            ON CONFLICT (user_id, namespace, title)
            DO UPDATE SET content = EXCLUDED.content, kind = EXCLUDED.kind, update_time = now()
            RETURNING id
        ''')
            .add(write.userId)
            .add(write.namespace)
            .add(write.title)
            .add(write.content)
            .add(write.kind)
            .firstToMap()
        let id = intOf(row.get('id') ?? 0)
        executor.setSql('''
            INSERT INTO llm_memory_vector (memory_id, model, title_dense, content_dense, update_time)
            VALUES (?, ?, ?::vector, ?::vector, now())
            ON CONFLICT (memory_id)
            DO UPDATE SET title_dense = EXCLUDED.title_dense,
                          content_dense = EXCLUDED.content_dense,
                          update_time = now()
        ''')
            .add(id)
            .add('bge-m3')
            .add(vectorLiteral(titleVector))
            .add(vectorLiteral(contentVector))
            .update
        id
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        var namespaceClause = ''
        if(query.namespaces.size > 0){
            var placeholders = ArrayList<String>()
            for(_ in query.namespaces){
                placeholders.add('?')
            }
            let text = join(placeholders)
            namespaceClause = ' AND m.namespace IN (${text})'
        }
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   1 - (v.title_dense <=> ?::vector) AS score
            FROM llm_memory m
            JOIN llm_memory_vector v ON v.memory_id = m.id
            WHERE m.user_id = ?${namespaceClause}
            ORDER BY v.title_dense <=> ?::vector
            LIMIT ?
        '''
        var statement = executor.setSql(sql).add(vectorLiteral(vector)).add(query.userId)
        for(namespace in query.namespaces){
            statement = statement.add(namespace)
        }
        statement = statement.add(vectorLiteral(vector)).add(limit)

        let hits = ArrayList<MemoryHit>()
        for(row in statement.mapList()){
            hits.add(MemoryHit(recordOf(row), floatOf(row.get('score') ?? 0.0f64)))
        }
        hits
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        // 覆盖写：先清旧 token，再批量插入；field='m' 表示标题+正文合并后的稀疏向量
        executor.setSql('DELETE FROM llm_memory_token WHERE memory_id = ?').add(memoryId).delete
        for((token, weight) in tokens){
            executor.setSql('''
                INSERT INTO llm_memory_token (memory_id, user_id, namespace, field, token, weight)
                VALUES (?, ?, ?, 'm', ?, ?)
            ''')
                .add(memoryId)
                .add(userId)
                .add(namespace)
                .add(token)
                .add(weight)
                .update
        }
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        // TODO(2.8c)：二进制 f32[] 编码（count + count*dim*4）待补；当前不写 colbert 列，
        // 重排会因 colbert(id) 返回 None 自动跳过，不影响召回。
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        if(tokens.isEmpty()){
            return ArrayList<MemoryHit>()
        }
        var namespaceClause = ''
        if(query.namespaces.size > 0){
            let placeholders = ArrayList<String>()
            for(_ in query.namespaces){
                placeholders.add('?')
            }
            namespaceClause = ' AND t.namespace IN (${join(placeholders)})'
        }
        let tokenPlaceholders = ArrayList<String>()
        for(_ in tokens.keys()){
            tokenPlaceholders.add('?')
        }
        let sql = '''
            SELECT m.id, m.user_id, m.namespace, m.title, m.content, m.kind,
                   SUM(t.weight) AS score
            FROM llm_memory_token t
            JOIN llm_memory m ON m.id = t.memory_id
            WHERE t.user_id = ?${namespaceClause} AND t.token IN (${join(tokenPlaceholders)})
            GROUP BY m.id, m.user_id, m.namespace, m.title, m.content, m.kind
            ORDER BY score DESC
            LIMIT ?
        '''
        var statement = executor.setSql(sql).add(query.userId)
        for(namespace in query.namespaces){
            statement = statement.add(namespace)
        }
        for((token, _) in tokens){
            statement = statement.add(token)
        }
        statement = statement.add(limit)

        let hits = ArrayList<MemoryHit>()
        for(row in statement.mapList()){
            hits.add(MemoryHit(recordOf(row), floatOf(row.get('score') ?? 0.0f64)))
        }
        hits
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        // TODO(2.8c)：读取并解码 title_colbert / content_colbert
        None
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        let row = executor.setSql(
            'SELECT ${MEMORY_COLUMNS} FROM llm_memory WHERE user_id = ? AND id = ?'
        )
            .add(userId)
            .add(id)
            .firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some(recordOf(row))
        }
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let records = ArrayList<MemoryRecord>()
        let rows = executor.setSql('''
            SELECT ${MEMORY_COLUMNS} FROM llm_memory
            WHERE user_id = ? AND namespace = ?
            ORDER BY save_time DESC
            LIMIT ? OFFSET ?
        ''')
            .add(userId)
            .add(namespace)
            .add(limit)
            .add(offset)
            .mapList()
        for(row in rows){
            records.add(recordOf(row))
        }
        records
    }

    public func remove(userId: Int64, id: Int64): Bool {
        executor.setSql('DELETE FROM llm_memory_vector WHERE memory_id = ?').add(id).delete
        executor.setSql('DELETE FROM llm_memory WHERE user_id = ? AND id = ?')
            .add(userId)
            .add(id)
            .delete > 0
    }

    private func recordOf(row: Map<String, Any>): MemoryRecord {
        MemoryRecord(
            intOf(row.get('id') ?? 0),
            intOf(row.get('user_id') ?? 0),
            textOf(row.get('namespace') ?? ''),
            textOf(row.get('title') ?? ''),
            textOf(row.get('content') ?? ''),
            textOf(row.get('kind') ?? ''),
            DateTime.now()
        )
    }

    private static func intOf(value: Any): Int64 {
        match(value){
            case number: Int64 => number
            case number: Int32 => Int64(number)
            case number: Int16 => Int64(number)
            case number: Int8 => Int64(number)
            case _ => 0
        }
    }

    private static func floatOf(value: Any): Float64 {
        match(value){
            case number: Float64 => number
            case number: Float32 => Float64(number)
            case number: Int64 => Float64(number)
            case _ => 0.0f64
        }
    }

    private static func textOf(value: Any): String {
        match(value){
            case text: String => text
            case _ => ''
        }
    }

    private static func vectorLiteral(vector: Array<Float64>): String {
        var text = '['
        for(index in 0..vector.size){
            if(index > 0){
                text += ','
            }
            text += '${vector[index]}'
        }
        text += ']'
        text
    }

    private static func join(values: ArrayList<String>): String {
        var text = ''
        for(index in 0..values.size){
            if(index > 0){
                text += ','
            }
            text += values[index]
        }
        text
    }
}
